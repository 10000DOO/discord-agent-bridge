import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("ProjectRagStore")
struct ProjectRagStoreTests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-rag-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// Builds a `.dab-index/tmp/<uuid>/` directory with a manifest + (optionally seeded) ndjson
    /// files, ready to be handed to `ProjectRagStore.publish`. Mirrors what `ProjectRagBuilder`
    /// (WO-2, not yet available to this WO) is expected to produce.
    @discardableResult
    private func makeTmpVersion(
        root: URL,
        snapshotDigest: String,
        semanticCoverage: String = "full",
        createdAt: Date = Date(),
        modules: [RagModule] = [],
        symbols: [RagSymbol] = [],
        edges: [RagEdge] = []
    ) throws -> URL {
        let dir = root.appendingPathComponent(".dab-index/tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = ProjectRagManifest(
            schemaVersion: 1,
            generatorVersion: "test",
            createdAt: iso(createdAt),
            projectKey: "test-key",
            projectRootDisplay: root.lastPathComponent,
            profileId: "generic-file-graph",
            profileVersion: 1,
            configDigest: "cfg-digest",
            snapshotDigest: snapshotDigest,
            semanticCoverage: semanticCoverage,
            statsFiles: 0,
            statsModules: modules.count,
            statsSymbols: symbols.count,
            statsEdges: edges.count,
            lastSuccessfulRefreshAt: iso(createdAt)
        )
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try writeNDJSON(modules, to: dir.appendingPathComponent("modules.ndjson"))
        try writeNDJSON(symbols, to: dir.appendingPathComponent("symbols.ndjson"))
        try writeNDJSON(edges, to: dir.appendingPathComponent("edges.ndjson"))
        try Data().write(to: dir.appendingPathComponent("files.ndjson"))
        try Data().write(to: dir.appendingPathComponent("diagnostics.ndjson"))
        return dir
    }

    private func writeNDJSON<T: Encodable>(_ records: [T], to url: URL) throws {
        let lines = try records.map { String(data: try JSONEncoder().encode($0), encoding: .utf8) ?? "" }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - currentManifest / freshness

    @Test func currentManifest_nilWhenMissingOrCorrupt() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ProjectRagStore.currentManifest(root: root) == nil)

        let dabIndex = root.appendingPathComponent(".dab-index", isDirectory: true)
        try FileManager.default.createDirectory(at: dabIndex, withIntermediateDirectories: true)
        try "points-nowhere".write(to: dabIndex.appendingPathComponent("CURRENT"), atomically: true, encoding: .utf8)
        #expect(ProjectRagStore.currentManifest(root: root) == nil)
    }

    /// `makeTmpVersion`'s fixed manifest identity (`profileId: "generic-file-graph"`, `profileVersion: 1`,
    /// `configDigest: "cfg-digest"`) — matched against in the `freshness` calls below.
    private func freshness(_ root: URL, snapshotDigest: String, profileId: String = "generic-file-graph", profileVersion: Int = 1, configDigest: String = "cfg-digest") -> IndexFreshness {
        ProjectRagStore.freshness(root: root, profileId: profileId, profileVersion: profileVersion, configDigest: configDigest, snapshotDigest: snapshotDigest)
    }

    @Test func freshness_missingFreshAndStale() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(freshness(root, snapshotDigest: "d1") == .missing)

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        #expect(freshness(root, snapshotDigest: "d1") == .fresh)
        #expect(freshness(root, snapshotDigest: "d2") == .stale)
    }

    @Test func freshness_comparesAllFiveIdentityFields() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        // Baseline: every field matches the published manifest.
        #expect(freshness(root, snapshotDigest: "d1") == .fresh)

        // Any single field disagreeing must fall back to stale, even with the rest unchanged.
        #expect(freshness(root, snapshotDigest: "d1", profileId: "objc-xcode") == .stale)
        #expect(freshness(root, snapshotDigest: "d1", profileVersion: 2) == .stale)
        #expect(freshness(root, snapshotDigest: "d1", configDigest: "different-cfg-digest") == .stale)
        #expect(freshness(root, snapshotDigest: "d2") == .stale)
    }

    // MARK: - publish atomicity

    @Test func publish_failure_leavesCurrentUnchanged() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstTmp = try makeTmpVersion(root: root, snapshotDigest: "digest-1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: firstTmp)
        let currentFile = root.appendingPathComponent(".dab-index/CURRENT")
        let before = try String(contentsOf: currentFile, encoding: .utf8)

        let bogusTmp = root.appendingPathComponent(".dab-index/tmp/does-not-exist", isDirectory: true)
        #expect(throws: (any Error).self) {
            try ProjectRagStore.publish(root: root, tmpVersionDir: bogusTmp)
        }

        let after = try String(contentsOf: currentFile, encoding: .utf8)
        #expect(after == before)
        #expect(ProjectRagStore.currentManifest(root: root)?.snapshotDigest == "digest-1")
    }

    // MARK: - pruneOldVersions

    @Test func pruneOldVersions_keepsCurrentPlusTwoNewestOthers() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let v1 = try makeTmpVersion(root: root, snapshotDigest: "d1", createdAt: now.addingTimeInterval(-300))
        try ProjectRagStore.publish(root: root, tmpVersionDir: v1)
        let v1Id = v1.lastPathComponent

        let v2 = try makeTmpVersion(root: root, snapshotDigest: "d2", createdAt: now.addingTimeInterval(-200))
        try ProjectRagStore.publish(root: root, tmpVersionDir: v2)
        let v2Id = v2.lastPathComponent

        let v3 = try makeTmpVersion(root: root, snapshotDigest: "d3", createdAt: now.addingTimeInterval(-100))
        try ProjectRagStore.publish(root: root, tmpVersionDir: v3)
        let v3Id = v3.lastPathComponent

        let v4 = try makeTmpVersion(root: root, snapshotDigest: "d4", createdAt: now) // becomes CURRENT
        try ProjectRagStore.publish(root: root, tmpVersionDir: v4)
        let v4Id = v4.lastPathComponent

        ProjectRagStore.pruneOldVersions(root: root)

        let versionsDir = root.appendingPathComponent(".dab-index/versions", isDirectory: true)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: versionsDir.path))
        #expect(remaining == Set([v4Id, v3Id, v2Id]))
        #expect(!remaining.contains(v1Id))
        #expect(ProjectRagStore.currentManifest(root: root)?.snapshotDigest == "d4")
    }

    // MARK: - removeLegacyCacheIfPresent

    @Test func removeLegacyCacheIfPresent_removesOnlyLegacyFilesNotNewFormat() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let dabIndex = root.appendingPathComponent(".dab-index", isDirectory: true)
        try FileManager.default.createDirectory(at: dabIndex, withIntermediateDirectories: true)
        try "legacy index".write(to: dabIndex.appendingPathComponent("PROJECT_INDEX.md"), atomically: true, encoding: .utf8)
        try "legacy fingerprint".write(to: dabIndex.appendingPathComponent("fingerprint"), atomically: true, encoding: .utf8)

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        #expect(ProjectRagStore.removeLegacyCacheIfPresent(root: root))
        #expect(!FileManager.default.fileExists(atPath: dabIndex.appendingPathComponent("PROJECT_INDEX.md").path))
        #expect(!FileManager.default.fileExists(atPath: dabIndex.appendingPathComponent("fingerprint").path))
        // New-format files untouched.
        #expect(FileManager.default.fileExists(atPath: dabIndex.appendingPathComponent("CURRENT").path))
        #expect(ProjectRagStore.currentManifest(root: root)?.snapshotDigest == "d1")

        #expect(!ProjectRagStore.removeLegacyCacheIfPresent(root: root))
    }

    // MARK: - query

    @Test func query_missingIndex_returnsMissingFreshnessAndEmptyResults() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = ProjectRagStore.query(root: root, request: ProjectRagQueryRequest())
        #expect(result.freshness == .missing)
        #expect(result.modules.isEmpty)
        #expect(result.symbols.isEmpty)
        #expect(result.edges.isEmpty)
        #expect(result.warnings.contains("missing"))
    }

    @Test func query_ranksDeterministicallyAndRespectsLimitsWithoutSourceBodies() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let modules = [
            RagModule(id: "mod-changed", displayName: "Changed", paths: ["src/Changed.swift"]),
            RagModule(id: "mod-other", displayName: "Other", paths: ["src/Other.swift"]),
        ]
        let symbols = [
            RagSymbol(name: "Zeta", kind: "class", path: "src/Other.swift", line: 10, moduleId: "mod-other"),
            RagSymbol(name: "Foo", kind: "func", path: "src/Changed.swift", line: 1, moduleId: "mod-changed"),
            RagSymbol(name: "FooBarHelper", kind: "func", path: "src/Changed.swift", line: 5, moduleId: "mod-changed"),
        ]
        let edges = [
            RagEdge(kind: "import", fromModuleId: "mod-other", toModuleId: "mod-changed", path: "src/Other.swift", line: 2),
        ]

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1", modules: modules, symbols: symbols, edges: edges)
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        let request = ProjectRagQueryRequest(
            paths: ["src/Changed.swift"], symbols: ["Foo"], terms: ["Zeta"], limitModules: 1, limitSymbols: 2
        )
        let result = ProjectRagStore.query(root: root, request: request)

        #expect(result.freshness == .fresh)
        #expect(result.symbols.map(\.name) == ["Foo", "FooBarHelper"]) // exact > prefix, "Zeta" (keyword-only) truncated by limit
        #expect(result.modules.map(\.id) == ["mod-changed"]) // holds the exact-matched symbol, ranks above mod-other
        #expect(!result.warnings.contains("partial"))

        // Determinism: identical query re-run yields identical order.
        let again = ProjectRagStore.query(root: root, request: request)
        #expect(again.symbols.map(\.name) == result.symbols.map(\.name))
        #expect(again.modules.map(\.id) == result.modules.map(\.id))

        // Never returns source bodies - only path/line pointers on the declared record types.
        #expect(result.symbols.allSatisfy { !$0.path.isEmpty && $0.line > 0 })
    }

    @Test func query_flagsPartialSemanticCoverage() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1", semanticCoverage: "partial")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        let result = ProjectRagStore.query(root: root, request: ProjectRagQueryRequest())
        #expect(result.warnings.contains("partial"))
    }

    // MARK: - publish's gitignore auto-add (D12)

    @Test func publish_addsDabIndexEntryWhenGitRepoHasGitignoreWithoutIt() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let gitignoreURL = root.appendingPathComponent(".gitignore")
        try "node_modules/\n".write(to: gitignoreURL, atomically: true, encoding: .utf8)

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        #expect(content.components(separatedBy: .newlines).contains(".dab-index/"))
        #expect(content.hasPrefix("node_modules/"), "existing entries must be preserved")
    }

    @Test func publish_doesNotDuplicateExistingDabIndexEntry() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let gitignoreURL = root.appendingPathComponent(".gitignore")
        try "node_modules/\n.dab-index/\n".write(to: gitignoreURL, atomically: true, encoding: .utf8)

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        let content = try String(contentsOf: gitignoreURL, encoding: .utf8)
        let occurrences = content.components(separatedBy: .newlines).filter { $0 == ".dab-index/" }.count
        #expect(occurrences == 1)
    }

    @Test func publish_doesNotCreateGitignoreWhenMissing() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let tmp = try makeTmpVersion(root: root, snapshotDigest: "d1")
        try ProjectRagStore.publish(root: root, tmpVersionDir: tmp)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    }
}
