import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("ProjectRagCLI (dab rag status/query, WO-13)")
struct ProjectRagCLITests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-rag-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func iso(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func writeNDJSON<T: Encodable>(_ records: [T], to url: URL) throws {
        let lines = try records.map { String(data: try JSONEncoder().encode($0), encoding: .utf8) ?? "" }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Builds+publishes a real `.dab-index/versions/<id>/` so `currentManifest`/`query` see an
    /// actual index. Duplicated (not imported) from `ProjectRagStoreTests.makeTmpVersion` since
    /// that helper is private to its own test file (WO-3, WO-13 are independent files).
    @discardableResult
    private func publishVersion(
        root: URL,
        snapshotDigest: String = "digest-1",
        modules: [RagModule] = [],
        symbols: [RagSymbol] = [],
        edges: [RagEdge] = []
    ) throws -> ProjectRagManifest {
        let dir = root.appendingPathComponent(".dab-index/tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = ProjectRagManifest(
            schemaVersion: 1,
            generatorVersion: "test",
            createdAt: iso(),
            projectKey: "test-key",
            projectRootDisplay: root.lastPathComponent,
            profileId: "generic-file-graph",
            profileVersion: 1,
            configDigest: "cfg-digest",
            snapshotDigest: snapshotDigest,
            semanticCoverage: "full",
            statsFiles: 3,
            statsModules: modules.count,
            statsSymbols: symbols.count,
            statsEdges: edges.count,
            lastSuccessfulRefreshAt: iso()
        )
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try writeNDJSON(modules, to: dir.appendingPathComponent("modules.ndjson"))
        try writeNDJSON(symbols, to: dir.appendingPathComponent("symbols.ndjson"))
        try writeNDJSON(edges, to: dir.appendingPathComponent("edges.ndjson"))
        try Data().write(to: dir.appendingPathComponent("files.ndjson"))
        try Data().write(to: dir.appendingPathComponent("diagnostics.ndjson"))
        try ProjectRagStore.publish(root: root, tmpVersionDir: dir)
        return manifest
    }

    private func makeDeps(logs: LockedBox<[String]>) -> ProjectRagCommandDeps {
        ProjectRagCommandDeps(log: { message in logs.withLock { $0.append(message) } })
    }

    // MARK: - status

    @Test func statusReportsMissingWhenNoIndexBuilt() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(["status", "--project", root.path], deps: makeDeps(logs: logs))
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("없음"))
    }

    @Test func statusJSONReportsMissingSchemaWhenNoIndexBuilt() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(["status", "--project", root.path, "--json"], deps: makeDeps(logs: logs))
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        let data = try #require(text.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["freshness"] as? String == "missing")
        // Synthesized Encodable uses `encodeIfPresent` for Optional properties, so a nil
        // `manifest` omits the key entirely rather than encoding JSON `null`.
        #expect(obj["manifest"] == nil)
    }

    @Test func statusReportsFreshWithManifestStatsWhenIndexExists() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishVersion(root: root, modules: [RagModule(id: "m1", displayName: "M1", paths: ["a.swift"])])
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(["status", "--project", root.path, "--json"], deps: makeDeps(logs: logs))
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        let data = try #require(text.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["freshness"] as? String == "fresh")
        let manifest = try #require(obj["manifest"] as? [String: Any])
        #expect(manifest["statsModules"] as? Int == 1)
    }

    @Test func statusMissingProjectFlagFailsWithUsage() async throws {
        let logs = LockedBox<[String]>([])
        let ok = await runProjectRagCommand(["status"], deps: makeDeps(logs: logs))
        #expect(!ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("--project"))
    }

    // MARK: - query

    @Test func queryReturnsMissingWhenNoIndexBuilt() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(["query", "--project", root.path, "--json"], deps: makeDeps(logs: logs))
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        let data = try #require(text.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["freshness"] as? String == "missing")
        #expect(obj["warnings"] as? [String] == ["missing"])
    }

    @Test func queryJSONSchemaAndTermMatchWhenIndexExists() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishVersion(
            root: root,
            modules: [
                RagModule(id: "m1", displayName: "Alpha", paths: ["a.swift"]),
                RagModule(id: "m2", displayName: "Beta", paths: ["b.swift"]),
            ],
            symbols: [RagSymbol(name: "AlphaKit", kind: "class", path: "a.swift", line: 10, moduleId: "m1")]
        )
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(
            ["query", "--project", root.path, "--symbol", "AlphaKit", "--json"],
            deps: makeDeps(logs: logs)
        )
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        let data = try #require(text.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["freshness"] as? String == "fresh")
        let modules = try #require(obj["modules"] as? [[String: Any]])
        #expect(modules.first?["id"] as? String == "m1") // exact symbol match ranks its module first
        let symbols = try #require(obj["symbols"] as? [[String: Any]])
        #expect(symbols.contains { $0["name"] as? String == "AlphaKit" })
    }

    @Test func queryAppliesLimitModulesAndLimitSymbols() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishVersion(
            root: root,
            modules: (0..<5).map { RagModule(id: "m\($0)", displayName: "M\($0)", paths: ["f\($0).swift"]) },
            symbols: (0..<5).map { RagSymbol(name: "sym\($0)", kind: "func", path: "f\($0).swift", line: $0, moduleId: "m\($0)") }
        )
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(
            ["query", "--project", root.path, "--limit-modules", "2", "--limit-symbols", "1", "--json"],
            deps: makeDeps(logs: logs)
        )
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        let data = try #require(text.data(using: .utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modules = try #require(obj["modules"] as? [[String: Any]])
        let symbols = try #require(obj["symbols"] as? [[String: Any]])
        #expect(modules.count == 2)
        #expect(symbols.count == 1)
    }

    @Test func queryRepeatedPathFlagsCollectIntoRequest() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try publishVersion(
            root: root,
            modules: [
                RagModule(id: "m1", displayName: "Alpha", paths: ["a.swift"]),
                RagModule(id: "m2", displayName: "Beta", paths: ["b.swift"]),
            ]
        )
        let logs = LockedBox<[String]>([])

        let ok = await runProjectRagCommand(
            ["query", "--project", root.path, "--path", "a.swift", "--path", "b.swift", "--json"],
            deps: makeDeps(logs: logs)
        )
        #expect(ok)
        // Both paths matched a module (changed-path scoring) — just confirming no crash/parse
        // failure and a well-formed response; ranking itself is ProjectRagStore's own concern.
        let text = logs.withLock { $0.joined(separator: "\n") }
        let data = try #require(text.data(using: .utf8))
        _ = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func queryMissingProjectFlagFailsWithUsage() async throws {
        let logs = LockedBox<[String]>([])
        let ok = await runProjectRagCommand(["query"], deps: makeDeps(logs: logs))
        #expect(!ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("--project"))
    }

    @Test func unknownSubcommandPrintsUsageAndFails() async throws {
        let logs = LockedBox<[String]>([])
        let ok = await runProjectRagCommand(["bogus"], deps: makeDeps(logs: logs))
        #expect(!ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("사용법: dab rag"))
    }
}
