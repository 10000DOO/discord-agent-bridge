import Foundation

/// `generic-file-graph` profile (WO-4, docs/project-rag-generic-indexing.md §6 WO-4).
/// The baseline every project falls back to when no specialized profile (objc-xcode/swift-spm-xcode/
/// typescript-node) matches. Pure file path/extension/substring scanning only — no LSP, no
/// compiler, no language-specific parser (R6 token-0).
///
/// Because it processes every file regardless of extension, it re-applies the same exclusion
/// rules `ProjectRagBuilder.computeSnapshot` already enforces (원 설계 §6.1: ignored dirs, 5 MiB
/// cap) plus a root-confinement check — defense in depth in case a caller ever hands this
/// profile an unfiltered file list. The confinement check reuses `Session/Confinement.swift`'s
/// `realpathOrResolve`/`isWithin` (the existing realpath-based symlink-escape guard used for
/// confined attachment reads), not a fresh implementation.
public struct GenericFileGraphProfile: ProjectRagProfile {
    public let id = "generic-file-graph"
    public let version = 1

    public init() {}

    // 항상 최소 양수 점수(1)만 반환한다 — 전문 프로파일(objc-xcode/swift-spm-xcode/typescript-node,
    // 최저 매칭 점수 80)이 매칭되면 항상 이 프로파일을 이기지만, 아무 전문 프로파일도 안 맞으면 이
    // 프로파일(1점)만 유일한 양수 점수라 기본 fallback으로 남는다.
    public func matches(root: URL, files: [ProjectFileRecord]) -> Int { 1 }

    public func discover(root: URL, files: [ProjectFileRecord]) async throws -> ProfileDiscovery {
        let rootRealPath = realpathOrResolve(root.path)

        var included: [ProjectFileRecord] = []
        var diagnostics: [RagDiagnostic] = []
        for file in files {
            if Self.isExcludedPath(file.path) {
                diagnostics.append(RagDiagnostic(code: "excludedDir", message: "제외 디렉터리 안의 파일입니다", path: file.path))
                continue
            }
            if file.size > Self.maxFileBytes {
                diagnostics.append(RagDiagnostic(code: "excludedLargeFile", message: "파일 크기가 상한(5MiB)을 초과합니다", path: file.path))
                continue
            }
            let resolved = realpathOrResolve(root.appendingPathComponent(file.path).path)
            guard isWithin(root: rootRealPath, child: resolved) else {
                diagnostics.append(RagDiagnostic(code: "excludedSymlinkEscape", message: "프로젝트 루트 밖으로 벗어나는 심볼릭 링크입니다", path: file.path))
                continue
            }
            included.append(file)
        }

        var pathsByModule: [String: [String]] = [:]
        for file in included {
            pathsByModule[Self.moduleId(forPath: file.path), default: []].append(file.path)
        }
        let modules = pathsByModule.map { moduleId, paths in
            RagModule(id: moduleId, displayName: moduleId == "." ? root.lastPathComponent : moduleId, paths: paths.sorted())
        }.sorted { $0.id < $1.id }

        let knownPaths = Set(included.map(\.path))

        var symbols: [RagSymbol] = []
        var edges: [RagEdge] = []
        for file in included {
            guard let content = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8) else {
                diagnostics.append(RagDiagnostic(code: "unreadableSource", message: "파일을 읽을 수 없습니다", path: file.path))
                continue
            }
            let fromModuleId = Self.moduleId(forPath: file.path)
            for (index, line) in content.components(separatedBy: "\n").enumerated() {
                let lineNumber = index + 1
                if let decl = Self.declaredSymbol(in: line) {
                    symbols.append(RagSymbol(name: decl.name, kind: decl.kind, path: file.path, line: lineNumber, moduleId: fromModuleId))
                }
                if let raw = Self.importTargetString(in: line),
                   let target = Self.resolveImportTarget(raw, from: file.path, knownPaths: knownPaths) {
                    edges.append(RagEdge(kind: "import", fromModuleId: fromModuleId, toModuleId: Self.moduleId(forPath: target), path: file.path, line: lineNumber))
                }
            }
        }

        return ProfileDiscovery(modules: modules, symbols: symbols, edges: edges, diagnostics: diagnostics)
    }

    // MARK: - exclusion (mirrors 원 설계 §6.1 / WO-2's computeSnapshot defaults — defense in depth)

    private static let excludedDirNames: Set<String> = [
        ".git", ".svn", ".hg", ".dab-index", ".claude", "node_modules", "Pods", "DerivedData", "build", ".build", "dist", "vendor",
    ]

    private static func isExcludedPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { excludedDirNames.contains(String($0)) }
    }

    private static let maxFileBytes = 5 * 1024 * 1024

    // MARK: - directory-as-module convention

    private static func moduleId(forPath path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "." : dir
    }

    // MARK: - per-line symbol scanning (candidate-quality only, 원 설계 §5.2)

    // ponytail: line-level regex — may pick up commented-out or string-literal declarations.
    // Candidate quality is the explicit contract; language-specific profiles (objc-xcode/
    // swift-spm-xcode/typescript-node) do better within their own file types.
    private static let declRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:public|private|internal|fileprivate|open|final|static|export|default|abstract|async)\s+)*(class|struct|protocol|interface|enum|function|func|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static func declaredSymbol(in line: String) -> (kind: String, name: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = declRegex.firstMatch(in: line, range: range),
              let kindRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[kindRange]), String(line[nameRange]))
    }

    // MARK: - per-line import/include scanning

    // ObjC/C-style `#import "X.h"` / `#import <X/X.h>` / `#include "x.h"`.
    private static let hashIncludeRegex = try! NSRegularExpression(
        pattern: #"^\s*#\s*(?:import|include)\s*[<"]([^">]+)[">]"#
    )
    // `import ... from '...'` (ES module).
    private static let fromImportRegex = try! NSRegularExpression(
        pattern: #"\bimport\b[^'"\n]*?from\s+['"]([^'"]+)['"]"#
    )
    // bare side-effect `import '...'`.
    private static let bareQuotedImportRegex = try! NSRegularExpression(
        pattern: #"^\s*import\s*['"]([^'"]+)['"]"#
    )
    // CommonJS `require('...')`.
    private static let requireCallRegex = try! NSRegularExpression(
        pattern: #"\brequire\(\s*['"]([^'"]+)['"]\s*\)"#
    )

    private static func importTargetString(in line: String) -> String? {
        for regex in [hashIncludeRegex, fromImportRegex, requireCallRegex, bareQuotedImportRegex] {
            if let raw = firstGroup(regex, in: line) { return raw }
        }
        return nil
    }

    private static func firstGroup(_ regex: NSRegularExpression, in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let r = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }

    // 발견된 문자열이 프로젝트 내 다른 파일 경로와 매치될 때만 edge 후보로 채택(원 설계 §5.2) — 외부
    // 프레임워크/패키지 이름(예: import Foundation)은 매치되지 않아 자연히 버려진다.
    private static let candidateExtensions = [".swift", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".h", ".m", ".mm", ".py"]

    private static func resolveImportTarget(_ raw: String, from sourcePath: String, knownPaths: Set<String>) -> String? {
        let candidate = raw.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return nil }
        let baseDir = (sourcePath as NSString).deletingLastPathComponent
        let joined = (baseDir as NSString).appendingPathComponent(candidate)
        var normalized = (joined as NSString).standardizingPath
        if normalized.hasPrefix("/") { normalized.removeFirst() }
        if knownPaths.contains(normalized) { return normalized }
        for ext in candidateExtensions where knownPaths.contains(normalized + ext) {
            return normalized + ext
        }
        return nil
    }
}
