import Testing
import Foundation
@testable import DiscordAgentBridge

/// W16-e Always-Allow: config persistence + host auto-allow lookup (TS alwaysAllow.test.ts parity).

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-always-\(UUID().uuidString)", isDirectory: true)
}

private func makeConfig(autoAllow: [String] = ["Read", "Glob", "Grep"]) -> AppConfig {
    AppConfig(
        discord: DiscordSecrets(token: "fake-token", clientId: "client-000"),
        auth: .empty,
        autoAllowClaudeTools: autoAllow
    )
}

@Suite("Always-Allow persistence")
struct AlwaysAllowTests {
    @Test func addAutoAllowPersistsGlobally() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())

        #expect(try await store.load().autoAllowClaudeTools.contains("Bash") == false)
        #expect(try await store.addAutoAllowClaudeTool("Bash") == true)
        #expect(try await store.load().autoAllowClaudeTools.contains("Bash"))
        // Idempotent.
        #expect(try await store.addAutoAllowClaudeTool("Bash") == false)
        let tools = try await store.load().autoAllowClaudeTools
        #expect(tools.filter { $0 == "Bash" }.count == 1)
        #expect(tools.contains("Read"))
    }

    @Test func plainAllowDoesNotPersist() async throws {
        // Wiring contract: only action == always writes. ConfigStore itself is the persist path;
        // this test documents that allow-only leaves the set untouched.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        let before = try await store.load().autoAllowClaudeTools
        // No addAutoAllowClaudeTool call (mirrors plain Allow button path).
        #expect(try await store.load().autoAllowClaudeTools == before)
        #expect(!before.contains("Bash"))
    }

    @Test func isAutoAllowedClaudeToolReadsConfig() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(autoAllow: ["Read", "Bash"]))

        #expect(await isAutoAllowedClaudeTool("Bash", store: store) == true)
        #expect(await isAutoAllowedClaudeTool("Read", store: store) == true)
        #expect(await isAutoAllowedClaudeTool("Write", store: store) == false)
    }

    @Test func isAutoAllowedFailClosedWhenNoConfig() async {
        let dir = tempDir()  // no config.json
        let store = ConfigStore(baseDir: dir)
        #expect(await isAutoAllowedClaudeTool("Bash", store: store) == false)
    }

    @Test func emptyToolNameIsNoOp() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        #expect(try await store.addAutoAllowClaudeTool("") == false)
        #expect(try await store.addAutoAllowClaudeTool("   ") == false)
        #expect(try await store.load().autoAllowClaudeTools == ["Read", "Glob", "Grep"])
    }

    @Test func subsequentLookupSeesPersistedTool() async throws {
        // TS alwaysAllow: after Always button → next turn's canUseTool auto-allows without prompt.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())

        #expect(await isAutoAllowedClaudeTool("Bash", store: store) == false)
        _ = try await store.addAutoAllowClaudeTool("Bash")
        #expect(await isAutoAllowedClaudeTool("Bash", store: store) == true)
    }

    @Test func autoAllowClaudeToolsHelper() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        #expect(await store.autoAllowClaudeTools().isEmpty)   // no file → empty
        try await store.save(makeConfig(autoAllow: ["A", "B"]))
        #expect(await store.autoAllowClaudeTools() == ["A", "B"])
    }

    @Test func alwaysCustomIdRoundtripAndPeek() async {
        #expect(parseCustomId("perm:req-9:always")?.action == .always)
        #expect(buildCustomId(reqKey: "req-9", action: .always) == "perm:req-9:always")
    }
}
