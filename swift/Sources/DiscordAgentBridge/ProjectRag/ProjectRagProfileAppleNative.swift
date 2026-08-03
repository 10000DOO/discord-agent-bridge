import Foundation

/// `apple-native` profile — merges the former `objc-xcode` + `swift-spm-xcode` profiles
/// (docs/project-rag-generic-indexing.md §6 WO-5/WO-6) into one.
/// A real Xcode-ecosystem project frequently mixes ObjC/Swift/C/C++ in a single `.xcodeproj`
/// (e.g. NEWSDK). Splitting them into two competing profiles meant `ProjectRagBuilder.build()`'s
/// highest-score-wins primary-profile selection always discarded one language's symbols entirely.
/// This profile discovers the `.pbxproj` target graph and SPM `Package.swift` targets (merged
/// into one module list), then scans ObjC (`.h`/`.m`/`.mm`), Swift (`.swift`), and C/C++
/// (`.c`/`.cpp`/`.cc`/`.cxx`/`.hpp`/`.hxx`) sources together so no language's candidates get lost
/// to profile competition. Regex line-scan only — no plist/SwiftSyntax/libclang parser dependency
/// (R6 token-0, "결정적 정규화 파서" 허용범위, 원 설계 §5.2). Candidate-quality output only.
public struct AppleNativeProfile: ProjectRagProfile {
    public let id = "apple-native"
    public let version = 1

    public init() {}

    public func matches(root: URL, files: [ProjectFileRecord]) -> Int {
        let hasPbxproj = files.contains { $0.path.hasSuffix(".xcodeproj/project.pbxproj") }
        let hasPackageSwift = files.contains { $0.path == "Package.swift" || $0.path.hasSuffix("/Package.swift") }
        let hasXcodeproj = files.contains { $0.path.contains(".xcodeproj/") }
        let hasSwift = files.contains { $0.path.hasSuffix(".swift") }
        return (hasPbxproj || hasPackageSwift || (hasXcodeproj && hasSwift)) ? 90 : 0
    }

    public func discover(root: URL, files: [ProjectFileRecord]) async throws -> ProfileDiscovery {
        var modules: [RagModule] = []
        var symbols: [RagSymbol] = []
        var edges: [RagEdge] = []
        var diagnostics: [RagDiagnostic] = []

        for file in files where file.path.hasSuffix(".xcodeproj/project.pbxproj") {
            guard let content = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8) else {
                diagnostics.append(RagDiagnostic(code: "unreadablePbxproj", message: "파일을 읽을 수 없습니다", path: file.path))
                continue
            }
            let graph = Self.parseTargetGraph(content, path: file.path)
            modules.append(contentsOf: graph.modules)
            edges.append(contentsOf: graph.edges)
        }

        if let packageFile = files.first(where: { $0.path == "Package.swift" || $0.path.hasSuffix("/Package.swift") }) {
            if let content = try? String(contentsOf: root.appendingPathComponent(packageFile.path), encoding: .utf8) {
                modules.append(contentsOf: Self.extractTargets(from: content))
            } else {
                diagnostics.append(RagDiagnostic(code: "unreadablePackageManifest", message: "Package.swift를 읽을 수 없습니다", path: packageFile.path))
            }
        }

        for file in files {
            let ext = (file.path as NSString).pathExtension.lowercased()

            switch ext {
            case "h", "m", "mm":
                guard let content = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8) else {
                    diagnostics.append(RagDiagnostic(code: "unreadableSource", message: "파일을 읽을 수 없습니다", path: file.path))
                    continue
                }
                let lines = content.components(separatedBy: "\n")

                if ext == "h" {
                    if Self.isPublicHeaderPath(file.path) {
                        symbols.append(RagSymbol(name: (file.path as NSString).lastPathComponent, kind: "public-header", path: file.path, line: 1))
                    }
                    for (index, line) in lines.enumerated() {
                        let lineNumber = index + 1
                        if let decl = Self.interfaceOrProtocol(in: line) {
                            symbols.append(RagSymbol(name: decl.name, kind: decl.kind, path: file.path, line: lineNumber))
                        }
                        if let selector = Self.selector(in: line) {
                            symbols.append(RagSymbol(name: selector, kind: "selector", path: file.path, line: lineNumber))
                        }
                    }
                } else {
                    for (index, line) in lines.enumerated() {
                        let lineNumber = index + 1
                        guard let spec = Self.importOrInclude(in: line) else { continue }
                        let toModuleId = Self.resolveImport(spec.path, files: files) ?? spec.path
                        edges.append(RagEdge(kind: spec.kind, fromModuleId: file.path, toModuleId: toModuleId, path: file.path, line: lineNumber))
                    }
                }

            case "swift":
                guard let content = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8) else {
                    diagnostics.append(RagDiagnostic(code: "unreadableSwiftFile", message: "파일을 읽을 수 없습니다", path: file.path))
                    continue
                }
                let moduleId = Self.moduleId(forPath: file.path, modules: modules)
                for (index, line) in content.components(separatedBy: "\n").enumerated() {
                    let lineNumber = index + 1
                    if let importedName = Self.importedModuleName(in: line) {
                        edges.append(RagEdge(kind: "import", fromModuleId: moduleId, toModuleId: importedName, path: file.path, line: lineNumber))
                    }
                    if let decl = Self.declaredSymbol(in: line) {
                        symbols.append(RagSymbol(name: decl.name, kind: decl.kind, path: file.path, line: lineNumber, moduleId: moduleId))
                    }
                }

            case "c", "cpp", "cc", "cxx", "hpp", "hxx":
                guard let content = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8) else {
                    diagnostics.append(RagDiagnostic(code: "unreadableSource", message: "파일을 읽을 수 없습니다", path: file.path))
                    continue
                }
                // ponytail: class/struct 심볼과 #include edge만 추출, 함수 단위 후보는 범위 밖 — C/C++
                // 함수 선언은 정규식으로 신뢰성 있게 못 잡는다. 필요해지면 실제 C/C++ 파서(예: libclang) 도입.
                for (index, line) in content.components(separatedBy: "\n").enumerated() {
                    let lineNumber = index + 1
                    if let decl = Self.cxxClassOrStruct(in: line) {
                        symbols.append(RagSymbol(name: decl.name, kind: decl.kind, path: file.path, line: lineNumber))
                    }
                    if let spec = Self.importOrInclude(in: line) {
                        let toModuleId = Self.resolveImport(spec.path, files: files) ?? spec.path
                        edges.append(RagEdge(kind: spec.kind, fromModuleId: file.path, toModuleId: toModuleId, path: file.path, line: lineNumber))
                    }
                }

            default:
                continue
            }
        }

        return ProfileDiscovery(modules: modules, symbols: symbols, edges: edges, diagnostics: diagnostics)
    }

    // MARK: - project.pbxproj target/dependency graph (ported from ObjcXcodeProfile)

    private struct NativeTargetEntry {
        var name: String?
        var dependencyEntryUUIDs: [String] = []
        var line: Int
    }

    private static let entryStartRegex = try! NSRegularExpression(
        pattern: #"^\s*([0-9A-Fa-f]{24})\s*/\*\s*(.*?)\s*\*/\s*=\s*\{\s*$"#
    )
    private static let nameFieldRegex = try! NSRegularExpression(pattern: #"^\s*name\s*=\s*(.+?);\s*$"#)
    private static let targetFieldRegex = try! NSRegularExpression(
        pattern: #"^\s*target\s*=\s*[0-9A-Fa-f]+\s*/\*\s*(.+?)\s*\*/\s*;\s*$"#
    )
    private static let listEntryUUIDRegex = try! NSRegularExpression(pattern: #"^\s*([0-9A-Fa-f]{24})\b"#)

    // Two-pass line scan (no plist parser): pass 1 (PBXTargetDependency section) maps each
    // dependency-entry UUID -> the target name its own `target = ID /* Name */;` field points at.
    // pass 2 (PBXNativeTarget section) reads each target's `name =` and the UUIDs listed inside
    // `dependencies = ( ... )`, then resolves those UUIDs through the pass-1 map to produce
    // `target-dependency` edges.
    private static func parseTargetGraph(_ content: String, path: String) -> (modules: [RagModule], edges: [RagEdge]) {
        enum Section { case none, nativeTarget, targetDependency }
        var section = Section.none

        var dependencyTargetNameByEntryUUID: [String: String] = [:]
        var currentDependencyEntryUUID: String?

        var nativeTargetOrder: [String] = []
        var nativeTargetsByUUID: [String: NativeTargetEntry] = [:]
        var currentNativeUUID: String?
        var inDependenciesList = false

        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            let lineNumber = index + 1

            if line.contains("/* Begin PBXTargetDependency section */") {
                section = .targetDependency
                continue
            }
            if line.contains("/* End PBXTargetDependency section */") {
                section = .none
                currentDependencyEntryUUID = nil
                continue
            }
            if line.contains("/* Begin PBXNativeTarget section */") {
                section = .nativeTarget
                continue
            }
            if line.contains("/* End PBXNativeTarget section */") {
                section = .none
                currentNativeUUID = nil
                inDependenciesList = false
                continue
            }

            switch section {
            case .targetDependency:
                if let match = Self.firstMatch(entryStartRegex, in: line) {
                    currentDependencyEntryUUID = Self.group(match, 1, in: line)
                } else if let entryUUID = currentDependencyEntryUUID,
                          let match = Self.firstMatch(targetFieldRegex, in: line),
                          let targetName = Self.group(match, 1, in: line) {
                    dependencyTargetNameByEntryUUID[entryUUID] = targetName
                }

            case .nativeTarget:
                if let match = Self.firstMatch(entryStartRegex, in: line), let uuid = Self.group(match, 1, in: line) {
                    let comment = Self.group(match, 2, in: line)
                    currentNativeUUID = uuid
                    inDependenciesList = false
                    nativeTargetOrder.append(uuid)
                    nativeTargetsByUUID[uuid] = NativeTargetEntry(name: (comment?.isEmpty == false) ? comment : nil, line: lineNumber)
                } else if let uuid = currentNativeUUID {
                    if let match = Self.firstMatch(nameFieldRegex, in: line), let name = Self.group(match, 1, in: line) {
                        nativeTargetsByUUID[uuid]?.name = Self.stripQuotes(name)
                    } else if line.contains("dependencies = (") {
                        // ponytail: assumes Xcode's one-UUID-per-line pretty-printing; a
                        // single-line `dependencies = (X, Y);` is not supported. Upgrade to a
                        // real plist parser if a project ever writes it inline.
                        if !line.contains(");") { inDependenciesList = true }
                    } else if inDependenciesList {
                        if line.contains(");") {
                            inDependenciesList = false
                        } else if let match = Self.firstMatch(listEntryUUIDRegex, in: line), let depUUID = Self.group(match, 1, in: line) {
                            nativeTargetsByUUID[uuid]?.dependencyEntryUUIDs.append(depUUID)
                        }
                    }
                }

            case .none:
                break
            }
        }

        var modules: [RagModule] = []
        var edges: [RagEdge] = []
        for uuid in nativeTargetOrder {
            guard let entry = nativeTargetsByUUID[uuid], let name = entry.name else { continue }
            modules.append(RagModule(id: name, displayName: name, paths: [path]))
            for depUUID in entry.dependencyEntryUUIDs {
                guard let depName = dependencyTargetNameByEntryUUID[depUUID] else { continue }
                edges.append(RagEdge(kind: "target-dependency", fromModuleId: name, toModuleId: depName, path: path, line: entry.line))
            }
        }
        return (modules, edges)
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }

    // MARK: - ObjC header symbols (ported from ObjcXcodeProfile)

    // ponytail: "public header" is inferred from a conventional `Public/` path segment, not from
    // the pbxproj Headers-build-phase `ATTRIBUTES = (Public, )` build setting (would need a real
    // plist parser). Upgrade if a project relies on build-setting-only visibility.
    private static func isPublicHeaderPath(_ path: String) -> Bool {
        path.split(separator: "/").contains("Public")
    }

    private static let interfaceOrProtocolRegex = try! NSRegularExpression(
        pattern: #"^\s*@(interface|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static func interfaceOrProtocol(in line: String) -> (kind: String, name: String)? {
        guard let match = Self.firstMatch(interfaceOrProtocolRegex, in: line),
              let kind = Self.group(match, 1, in: line),
              let name = Self.group(match, 2, in: line) else { return nil }
        return (kind, name)
    }

    private static let selectorRegex = try! NSRegularExpression(
        pattern: #"^\s*[+\-]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*:?)"#
    )

    // ponytail: candidate quality only — captures the first keyword of a (possibly multi-line,
    // multi-keyword) selector declaration, not the full reconstructed selector. Upgrade if
    // partial selectors prove noisy in `dab rag query` results.
    private static func selector(in line: String) -> String? {
        guard let match = Self.firstMatch(selectorRegex, in: line) else { return nil }
        return Self.group(match, 1, in: line)
    }

    // MARK: - #import/#include edges (shared by ObjC .m/.mm and C/C++ sources)

    private static let importOrIncludeRegex = try! NSRegularExpression(
        pattern: #"^\s*#\s*(import|include)\s*[<"]([^">]+)[">]"#
    )

    private static func importOrInclude(in line: String) -> (kind: String, path: String)? {
        guard let match = Self.firstMatch(importOrIncludeRegex, in: line),
              let kind = Self.group(match, 1, in: line),
              let importPath = Self.group(match, 2, in: line) else { return nil }
        return (kind, importPath)
    }

    // ponytail: resolves by exact-suffix then bare-basename match against `files` only — no
    // header search path / framework mapping. Falls back to the raw import spec string when no
    // project file matches (external/system header). Upgrade if cross-target framework imports
    // need real module names instead of a file-path fallback.
    private static func resolveImport(_ importPath: String, files: [ProjectFileRecord]) -> String? {
        if let exact = files.first(where: { $0.path == importPath || $0.path.hasSuffix("/" + importPath) }) {
            return exact.path
        }
        let base = (importPath as NSString).lastPathComponent
        return files.first(where: { ($0.path as NSString).lastPathComponent == base })?.path
    }

    // MARK: - Package.swift target extraction (ported from SwiftSpmXcodeProfile)

    // Matches `.target(name: "X"` / `.executableTarget(name: "X"` across line breaks (`\s` spans
    // newlines) — deliberately excludes `.testTarget(` (no shared "."+"target(" substring with it).
    private static let targetRegex = try! NSRegularExpression(
        pattern: #"\.(?:executableTarget|target)\(\s*name:\s*"([^"]+)""#
    )

    private static func extractTargets(from packageContent: String) -> [RagModule] {
        let range = NSRange(packageContent.startIndex..., in: packageContent)
        return targetRegex.matches(in: packageContent, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: packageContent) else { return nil }
            let name = String(packageContent[nameRange])
            // ponytail: conventional SPM layout (Sources/<target>, Tests/<target>) — no `path:`
            // argument parsing. Upgrade if a project relies on custom target paths.
            return RagModule(id: name, displayName: name, paths: ["Sources/\(name)", "Tests/\(name)"])
        }
    }

    // MARK: - Swift per-line scanning (ported from SwiftSpmXcodeProfile)

    private static let importRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    private static func importedModuleName(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = importRegex.firstMatch(in: line, options: [], range: range),
              let nameRange = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[nameRange])
    }

    private static let declRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:public|private|internal|fileprivate|open|final)\s+)*(class|struct|protocol|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )

    // ponytail: line-level regex — may pick up commented-out or string-literal declarations.
    // Candidate quality is the explicit contract (원 설계 §5.2); upgrade to SwiftSyntax if noise
    // becomes a real problem.
    private static func declaredSymbol(in line: String) -> (kind: String, name: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = declRegex.firstMatch(in: line, options: [], range: range),
              let kindRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[kindRange]), String(line[nameRange]))
    }

    // Attributes a file to the pbxproj/SPM target whose conventional path prefix it falls under;
    // falls back to the file's own parent directory for plain Xcode+Swift projects with no
    // matching target path (e.g. no Package.swift).
    private static func moduleId(forPath path: String, modules: [RagModule]) -> String {
        for module in modules {
            for prefix in module.paths where path.hasPrefix(prefix + "/") {
                return module.id
            }
        }
        return (path as NSString).deletingLastPathComponent
    }

    // MARK: - C/C++ class/struct symbols (new)

    private static let cxxClassRegex = try! NSRegularExpression(pattern: #"class\s+([A-Za-z_]\w*)"#)
    private static let cxxStructRegex = try! NSRegularExpression(pattern: #"struct\s+([A-Za-z_]\w*)"#)

    // ponytail: class/struct only, no function signature extraction — see the `discover` call
    // site comment for the C/C++-function-parsing scope cut and its upgrade path.
    private static func cxxClassOrStruct(in line: String) -> (kind: String, name: String)? {
        if let match = Self.firstMatch(cxxClassRegex, in: line), let name = Self.group(match, 1, in: line) {
            return ("class", name)
        }
        if let match = Self.firstMatch(cxxStructRegex, in: line), let name = Self.group(match, 1, in: line) {
            return ("struct", name)
        }
        return nil
    }

    // MARK: - shared regex helpers

    private static func firstMatch(_ regex: NSRegularExpression, in line: String) -> NSTextCheckingResult? {
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, options: [], range: range)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }
}
