import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-cfg-redmine-\(UUID().uuidString)", isDirectory: true)
}

@Suite("RedmineConfigStore")
struct RedmineConfigStoreTests {
    @Test func saveRedmineConfigPreservesOtherFields() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.saveServerConfig(ServerConfig(
            version: CONFIG_VERSION,
            guildId: "g1",
            notifications: NotificationsSection(enabled: true, channelId: "chan-1")
        ))
        let section = RedmineSection(
            url: "https://redmine.example.com",
            apiKeyEncrypted: Data("cipher".utf8),
            projectId: "proj",
            reportChannelId: "chan-redmine",
            lastCheckedAt: 1_000
        )
        try await store.saveRedmineConfig(guildId: "g1", section: section)
        let loaded = await store.loadServerConfig(guildId: "g1")
        #expect(loaded?.redmine == section)
        #expect(loaded?.notifications == NotificationsSection(enabled: true, channelId: "chan-1"))
    }

    // The 5-minute poller writes `lastCheckedAt` through this path. A field-by-field rebuild here
    // silently drops every section the rebuild forgot to list, so this guards that the save is a
    // read-modify-write of the loaded value.
    @Test func saveRedmineConfigPreservesUnrelatedSections() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            favorites: ["/repo/a"],
            channels: ServerChannels(categoryId: "cat-1", controlChannelId: "ctl-1", sessionsCategoryId: "sess-1")
        ))
        try await store.saveRedmineConfig(guildId: "g1", section: RedmineSection(
            url: "https://redmine.example.com",
            apiKeyEncrypted: Data("cipher".utf8),
            lastCheckedAt: 42
        ))
        let loaded = await store.loadServerConfig(guildId: "g1")
        #expect(loaded?.favorites == ["/repo/a"])
        #expect(loaded?.channels?.controlChannelId == "ctl-1")
        #expect(loaded?.redmine?.lastCheckedAt == 42)
    }

    @Test func saveRedmineConfigOverwritesPreviousValue() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.saveRedmineConfig(guildId: "g1", section: RedmineSection(
            url: "https://old.example.com",
            apiKeyEncrypted: Data("old".utf8)
        ))
        let updated = RedmineSection(
            url: "https://new.example.com",
            apiKeyEncrypted: Data("new".utf8),
            projectId: "proj-2"
        )
        try await store.saveRedmineConfig(guildId: "g1", section: updated)
        #expect(await store.loadServerConfig(guildId: "g1")?.redmine == updated)
    }

    @Test func nullUrlInRedmineSectionRejectsLoad() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        let path = await store.serverConfigPath(guildId: "g1")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"guildId":"g1","redmine":{"url":null,"apiKeyEncrypted":"Y2lwaGVy"}}"#.utf8)
            .write(to: path)
        #expect(await store.loadServerConfig(guildId: "g1") == nil)
    }

    @Test func nullOptionalRedmineFieldsAreAllowed() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        let path = await store.serverConfigPath(guildId: "g1")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"guildId":"g1","redmine":{"url":"https://r.example.com","apiKeyEncrypted":"Y2lwaGVy","projectId":null,"reportChannelId":null,"lastCheckedAt":null}}"#.utf8)
            .write(to: path)
        #expect(await store.loadServerConfig(guildId: "g1")?.redmine?.url == "https://r.example.com")
    }
}
