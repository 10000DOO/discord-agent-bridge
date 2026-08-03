import Foundation

/// `typescript-node` profile (WO-7, docs/project-rag-generic-indexing.md §6 WO-7).
/// Pure text/regex scan inside the Swift process only — no Node subprocess spawn, no
/// npm-based parser (R6: no external tool/network calls). Every extraction below is a
/// deterministic string candidate, not a real TS compiler symbol/import graph.
public struct TypescriptNodeProfile: ProjectRagProfile {
    public let id = "typescript-node"
    public let version = 1

    public init() {}

    public func matches(root: URL, files: [ProjectFileRecord]) -> Int {
        let hasPackageJson = files.contains { $0.path == "package.json" }
        let hasTsconfig = files.contains { isTsconfigName($0.path) }
        let hasTsSource = files.contains { $0.path.hasSuffix(".ts") || $0.path.hasSuffix(".tsx") }
        return (hasPackageJson || hasTsconfig || hasTsSource) ? 90 : 0
    }

    public func discover(root: URL, files: [ProjectFileRecord]) async throws -> ProfileDiscovery {
        var modules: [RagModule] = []
        var symbols: [RagSymbol] = []
        var edges: [RagEdge] = []
        var diagnostics: [RagDiagnostic] = []

        if let packageJson = files.first(where: { $0.path == "package.json" }) {
            modules.append(contentsOf: workspaceModules(root: root, path: packageJson.path, diagnostics: &diagnostics))
        }

        // ponytail: regex literals are recompiled per `discover()` call (not stored as module-level
        // `let`s) — Swift 6 strict concurrency requires global state to be Sendable, and `Regex` isn't.
        // This matches the existing local-`let` regex convention in this codebase (GrokCatalog.swift,
        // CliHelp.swift) rather than reaching for `@unchecked Sendable` boxing. Recompiled once per
        // profile run, not per line, so the cost is negligible.
        let exportDeclRegex =
            #/^\s*export\s+(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?(?:async\s+)?(class|function|interface|type|enum|const|let|var)\s+([A-Za-z_$][A-Za-z0-9_$]*)/#
        let importFromRegex =
            #/^\s*(?:import\b[^'"\n]*|export\s+(?:\*(?:\s+as\s+\w+)?|\{[^}]*\}))\s*from\s*['"]([^'"]+)['"]/#
        let bareImportRegex = #/^\s*import\s*['"]([^'"]+)['"]/#
        let dynamicImportRegex = #/\bimport\(\s*['"]([^'"]+)['"]\s*\)/#

        for file in files where file.path.hasSuffix(".ts") || file.path.hasSuffix(".tsx") {
            guard let content = try? String(contentsOf: root.appendingPathComponent(file.path), encoding: .utf8) else {
                diagnostics.append(RagDiagnostic(code: "unreadableSource", message: "failed to read as UTF-8", path: file.path))
                continue
            }
            let moduleId = directoryModuleId(for: file.path)
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineNumber = index + 1

                if let m = line.firstMatch(of: exportDeclRegex) {
                    symbols.append(RagSymbol(name: String(m.output.2), kind: String(m.output.1), path: file.path, line: lineNumber, moduleId: moduleId))
                }

                var specifiers: [String] = []
                if let m = line.firstMatch(of: importFromRegex) {
                    specifiers.append(String(m.output.1))
                } else if let m = line.firstMatch(of: bareImportRegex) {
                    specifiers.append(String(m.output.1))
                }
                for m in line.matches(of: dynamicImportRegex) {
                    specifiers.append(String(m.output.1))
                }
                for specifier in specifiers {
                    edges.append(RagEdge(
                        kind: "import",
                        fromModuleId: moduleId,
                        toModuleId: resolvedModuleId(specifier: specifier, fromPath: file.path),
                        path: file.path,
                        line: lineNumber
                    ))
                }
            }
        }

        return ProfileDiscovery(modules: modules, symbols: symbols, edges: edges, diagnostics: diagnostics)
    }
}

// MARK: - matches() helpers

private func isTsconfigName(_ path: String) -> Bool {
    let base = (path as NSString).lastPathComponent
    return base.hasPrefix("tsconfig") && base.hasSuffix(".json")
}

// MARK: - package.json workspaces -> RagModule

private func workspaceModules(root: URL, path: String, diagnostics: inout [RagDiagnostic]) -> [RagModule] {
    guard
        let data = try? Data(contentsOf: root.appendingPathComponent(path)),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        diagnostics.append(RagDiagnostic(code: "unreadablePackageJson", message: "failed to parse as JSON", path: path))
        return []
    }
    let entries: [String]
    if let arr = obj["workspaces"] as? [String] {
        entries = arr
    } else if let wsObj = obj["workspaces"] as? [String: Any], let packages = wsObj["packages"] as? [String] {
        entries = packages
    } else {
        entries = []
    }
    return entries.map { RagModule(id: "workspace:\($0)", displayName: $0, paths: [$0]) }
}

// MARK: - directory-as-module convention (candidate key, not a resolved RagModule)

private func directoryModuleId(for path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    return dir.isEmpty ? "." : dir
}

// ponytail: relative specifiers resolve to a normalized path string only — existence
// against `files` is never checked, so this can point at a file that isn't there (e.g. a
// missing extension or an `index` resolution). Bare/package specifiers pass through as an
// external-dependency candidate. Upgrade path: cross-check against `files` if false edges
// in `dab rag query` output become a real problem.
private func resolvedModuleId(specifier: String, fromPath: String) -> String {
    guard specifier.hasPrefix(".") else { return specifier }
    let dir = directoryModuleId(for: fromPath)
    let joined = (dir as NSString).appendingPathComponent(specifier)
    return (joined as NSString).standardizingPath
}
