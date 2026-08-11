import Testing
import Foundation
@testable import DiscordAgentBridge
@testable import dab

// Boot must never die on config.json (docs/all-members-admin.md R10). Before this, a present but
// unreadable file called exit(1); under a keep-alive supervisor that is a die/restart loop, and the
// machine can no longer be updated out of it. The regression that actually happened needed no
// corruption at all — a config.json carrying only an `auth` block was enough, because the absent
// `discord` section was validated as an invalid value rather than an absent one.

private func bootTempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-boot-\(UUID().uuidString)", isDirectory: true)
}

private func validConfig() -> AppConfig {
    AppConfig(discord: DiscordSecrets(token: "t", clientId: "c"))
}

@Suite("Config boot recovery")
struct ConfigBootRecoveryTests {
    @Test func noFileRunsOnDefaultsWithoutAWarning() async {
        let outcome = await resolveBootConfig(exists: false, path: "/nowhere/config.json") {
            throw ConfigStoreError.notFound("/nowhere/config.json")
        }
        #expect(outcome.config == nil)
        #expect(outcome.warning == nil)
    }

    @Test func readableFileIsUsedWithoutAWarning() async {
        let outcome = await resolveBootConfig(exists: true, path: "/x/config.json") { validConfig() }
        #expect(outcome.config == validConfig())
        #expect(outcome.warning == nil)
    }

    /// The exact file that bricked a machine: auth block only, no `discord` section. It must be
    /// ignored (defaults) and reported — never fatal.
    @Test func authOnlyConfigIsIgnoredAndReportedNotFatal() async throws {
        let dir = bootTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = ["version": 2, "auth": ["memberDefaultTier": "admin"]]
        let url = dir.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let store = ConfigStore(baseDir: dir)
        // Confirm the precondition: this file really is unreadable to the loader.
        await #expect(throws: (any Error).self) { try await store.load() }

        let outcome = await resolveBootConfig(exists: true, path: url.path) { try await store.load() }
        #expect(outcome.config == nil)
        let warning = try #require(outcome.warning)
        #expect(warning.contains(url.path))
        #expect(warning.contains("discord"))
    }

    @Test func corruptJsonIsIgnoredAndReportedNotFatal() async throws {
        let dir = bootTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("}{ not json".utf8).write(to: url)

        let store = ConfigStore(baseDir: dir)
        let outcome = await resolveBootConfig(exists: true, path: url.path) { try await store.load() }
        #expect(outcome.config == nil)
        #expect(outcome.warning != nil)
    }

    @Test func warningIsDeliveredOnceSoAReconnectDoesNotRepeatIt() async {
        let registry = BootWarningRegistry()
        await registry.set("boom")
        #expect(await registry.take() == "boom")
        #expect(await registry.take() == nil)
    }
}
