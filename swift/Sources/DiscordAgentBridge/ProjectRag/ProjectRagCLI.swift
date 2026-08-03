import Foundation

// `dab rag status/query` (WO-13, docs/project-rag-generic-indexing.md §6 WO-13) — read-only CLI
// over `ProjectRagStore`. Mirrors `Service/ServiceCommand.swift`'s "branch → free function → Deps
// DI struct" shape (P5/D5): `DabMain.swift`'s `args.first == "rag"` branch (WO-14) dispatches
// here. Argument parsing is direct `argv` branching, same as `ServiceCommand.swift` — no
// arg-parser library (D5). Never triggers a build: indexing is `ProjectRagCoordinator`'s
// (WO-12) job only, so this file calls `ProjectRagStore.currentManifest`/`query` alone.

public struct ProjectRagCommandDeps: Sendable {
    public var log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.log = log
    }
}

/// `status`/`manifest` JSON shape. `status` only calls `ProjectRagStore.currentManifest` (never
/// `freshness`, which needs a freshly recomputed `snapshotDigest` that only the
/// Builder/Coordinator can produce) — so, like `ProjectRagStore.query`'s own documented
/// convention (`ProjectRagStore.swift` query() doc comment), a present manifest is reported
/// `.fresh` here and absence is `.missing`; real `.stale` detection stays with `/orchestration`
/// and the hourly scheduler.
private struct ProjectRagStatusResult: Sendable, Encodable {
    var freshness: IndexFreshness
    var manifest: ProjectRagManifest?
}

/// Dispatch `rag <sub>`. Returns false on failure (caller maps to a non-zero exit).
public func runProjectRagCommand(_ argv: [String], deps: ProjectRagCommandDeps = ProjectRagCommandDeps()) async -> Bool {
    switch argv.first {
    case "status":
        return runProjectRagStatus(Array(argv.dropFirst()), deps: deps)
    case "query":
        return runProjectRagQuery(Array(argv.dropFirst()), deps: deps)
    default:
        printProjectRagUsage(deps)
        return false
    }
}

private func printProjectRagUsage(_ deps: ProjectRagCommandDeps) {
    deps.log("사용법: dab rag <status|query> --project <path> [--json]")
    deps.log("  status  현재 인덱스 상태(manifest)를 출력합니다.")
    deps.log("  query   --path/--symbol/--term 후보를 조회합니다.")
}

private func runProjectRagStatus(_ argv: [String], deps: ProjectRagCommandDeps) -> Bool {
    guard let root = parseProjectRoot(argv, deps: deps) else { return false }
    let manifest = ProjectRagStore.currentManifest(root: root)
    let result = ProjectRagStatusResult(freshness: manifest == nil ? .missing : .fresh, manifest: manifest)
    if argv.contains("--json") {
        emitJSON(result, deps: deps)
    } else {
        printStatusText(result, deps: deps)
    }
    return true
}

private func printStatusText(_ result: ProjectRagStatusResult, deps: ProjectRagCommandDeps) {
    guard let manifest = result.manifest else {
        deps.log("RAG 인덱스: 없음")
        return
    }
    deps.log("RAG 인덱스: 있음")
    deps.log("  프로파일: \(manifest.profileId) v\(manifest.profileVersion) (\(manifest.semanticCoverage))")
    deps.log("  마지막 갱신: \(manifest.lastSuccessfulRefreshAt)")
    deps.log("  통계: 파일 \(manifest.statsFiles) · 모듈 \(manifest.statsModules) · 심볼 \(manifest.statsSymbols) · 엣지 \(manifest.statsEdges)")
}

private func runProjectRagQuery(_ argv: [String], deps: ProjectRagCommandDeps) -> Bool {
    guard let root = parseProjectRoot(argv, deps: deps) else { return false }
    var request = ProjectRagQueryRequest()
    request.paths = values(for: "--path", in: argv)
    request.symbols = values(for: "--symbol", in: argv)
    request.terms = values(for: "--term", in: argv)
    if let n = intValue(for: "--limit-modules", in: argv) { request.limitModules = n }
    if let n = intValue(for: "--limit-symbols", in: argv) { request.limitSymbols = n }

    let result = ProjectRagStore.query(root: root, request: request)
    if argv.contains("--json") {
        emitJSON(result, deps: deps)
    } else {
        printQueryText(result, deps: deps)
    }
    return true
}

private func printQueryText(_ result: ProjectRagQueryResult, deps: ProjectRagCommandDeps) {
    var header = "freshness: \(result.freshness.rawValue)"
    if let indexVersion = result.indexVersion { header += " (index: \(indexVersion))" }
    deps.log(header)
    if !result.warnings.isEmpty { deps.log("경고: \(result.warnings.joined(separator: ", "))") }

    deps.log("모듈 (\(result.modules.count)):")
    for module in result.modules {
        deps.log("  - \(module.id) \(module.displayName) (\(module.paths.count)개 파일)")
    }
    deps.log("심볼 (\(result.symbols.count)):")
    for symbol in result.symbols {
        deps.log("  - \(symbol.name) [\(symbol.kind)] \(symbol.path):\(symbol.line)")
    }
    deps.log("엣지 (\(result.edges.count)):")
    for edge in result.edges {
        deps.log("  - \(edge.fromModuleId) -> \(edge.toModuleId) (\(edge.kind)) \(edge.path):\(edge.line)")
    }
}

// MARK: - Shared argv parsing (D5 — direct branching, no arg-parser library)

private func parseProjectRoot(_ argv: [String], deps: ProjectRagCommandDeps) -> URL? {
    guard let path = singleValue(for: "--project", in: argv) else {
        deps.log("--project <path> 가 필요합니다.")
        printProjectRagUsage(deps)
        return nil
    }
    return URL(fileURLWithPath: path)
}

private func singleValue(for flag: String, in argv: [String]) -> String? {
    guard let idx = argv.firstIndex(of: flag), idx + 1 < argv.count else { return nil }
    return argv[idx + 1]
}

private func intValue(for flag: String, in argv: [String]) -> Int? {
    singleValue(for: flag, in: argv).flatMap(Int.init)
}

/// Collects every occurrence of a repeatable flag (e.g. `--term a --term b` → `["a", "b"]`).
private func values(for flag: String, in argv: [String]) -> [String] {
    var result: [String] = []
    var i = 0
    while i < argv.count {
        if argv[i] == flag, i + 1 < argv.count {
            result.append(argv[i + 1])
            i += 2
        } else {
            i += 1
        }
    }
    return result
}

private func emitJSON<T: Encodable>(_ value: T, deps: ProjectRagCommandDeps) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        deps.log("{}")
        return
    }
    deps.log(text)
}
