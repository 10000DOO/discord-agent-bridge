import Testing
import Foundation
@testable import DiscordAgentBridge

// MARK: - Fake provisioner (duplicated from GuildChannelsTests.swift — that one is `private`)

private final class FakeProvisioner: GuildChannelProvisioner, @unchecked Sendable {
    let guildId: String
    var manageChannels: Bool
    /// id → (name, type, parent?)
    var channels: [String: (name: String, type: String, parent: String?)] = [:]
    private(set) var createdNames: [String] = []
    private(set) var deleted: [String] = []
    var renamed: [String: String] = [:]
    private var seq = 0

    init(guildId: String = "g1", manageChannels: Bool = true) {
        self.guildId = guildId
        self.manageChannels = manageChannels
    }

    func seed(id: String, name: String, type: String) {
        channels[id] = (name, type, nil)
    }

    func canManageChannels() async -> Bool { manageChannels }

    func channelExists(_ id: String) async -> Bool { channels[id] != nil }

    private func nextId() -> String {
        seq += 1
        return "chan-\(seq)"
    }

    func ensureCategory(name: String, existingId: String?) async throws -> ProvisionedChannel {
        if let existingId, let ch = channels[existingId] {
            return ProvisionedChannel(id: existingId, name: ch.name)
        }
        let id = nextId()
        channels[id] = (name, "category", nil)
        createdNames.append(name)
        return ProvisionedChannel(id: id, name: name)
    }

    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel {
        if let existingId, let ch = channels[existingId] {
            return ProvisionedChannel(id: existingId, name: ch.name)
        }
        let id = nextId()
        channels[id] = (name, "text", parentId)
        createdNames.append(name)
        return ProvisionedChannel(id: id, name: name)
    }

    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel {
        let id = nextId()
        channels[id] = (name, "text", parentId)
        createdNames.append(name)
        return ProvisionedChannel(id: id, name: name)
    }

    func renameChannel(id: String, name: String) async throws {
        if var ch = channels[id] {
            ch.name = name
            channels[id] = ch
            renamed[id] = name
        }
    }

    func deleteChannel(id: String) async throws {
        channels.removeValue(forKey: id)
        deleted.append(id)
    }
}

private func tempStore() async throws -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-redmine-chan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ConfigStore(baseDir: dir)
}

// MARK: - ensureRedmineReportChannel

@Suite("RedmineChannel ensure")
struct RedmineChannelEnsureTests {
    @Test func createsFreshWhenNoStoredChannelId() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let channel = try await ensureRedmineReportChannel(provisioner: prov, configStore: store)

        // Creates the 🤖 Agent control category (none stored yet) before the channel itself,
        // and parents the channel under it instead of leaving it uncategorized.
        #expect(prov.createdNames == [GuildChannelNames.controlCategory, GuildChannelNames.redmineReportChannel])
        #expect(channel.name == GuildChannelNames.redmineReportChannel)
        #expect(prov.channels[channel.id] != nil)
        #expect(prov.channels[channel.id]?.parent == prov.channels.first(where: { $0.value.name == GuildChannelNames.controlCategory })?.key)
    }

    @Test func createsUnderExistingControlCategoryWhenAlreadyProvisioned() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        prov.seed(id: "existing-category", name: GuildChannelNames.controlCategory, type: "category")
        prov.seed(id: "c1", name: GuildChannelNames.controlChannel, type: "text")
        prov.seed(id: "s1", name: GuildChannelNames.sessionsCategory, type: "category")
        prov.seed(id: "st1", name: GuildChannelNames.statusChannel, type: "text")
        // Simulate ensureGuildChannels() having already run and stored the category id.
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            channels: ServerChannels(
                categoryId: "existing-category",
                controlChannelId: "c1",
                sessionsCategoryId: "s1",
                statusChannelId: "st1"
            )
        ))

        let channel = try await ensureRedmineReportChannel(provisioner: prov, configStore: store)

        #expect(prov.createdNames == [GuildChannelNames.redmineReportChannel])
        #expect(prov.channels[channel.id]?.parent == "existing-category")
    }

    @Test func reusesStoredChannelIdWhenStillExists() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        prov.seed(id: "existing-report", name: GuildChannelNames.redmineReportChannel, type: "text")
        try await store.saveRedmineConfig(
            guildId: "g1",
            section: RedmineSection(
                url: "https://redmine.example.com",
                apiKeyEncrypted: Data(),
                reportChannelId: "existing-report"
            )
        )

        let channel = try await ensureRedmineReportChannel(provisioner: prov, configStore: store)

        #expect(channel.id == "existing-report")
        #expect(prov.createdNames.isEmpty)
    }

    @Test func recreatesWhenStoredChannelIdNoLongerExists() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        try await store.saveRedmineConfig(
            guildId: "g1",
            section: RedmineSection(
                url: "https://redmine.example.com",
                apiKeyEncrypted: Data(),
                reportChannelId: "deleted-channel"
            )
        )

        let channel = try await ensureRedmineReportChannel(provisioner: prov, configStore: store)

        #expect(channel.id != "deleted-channel")
        #expect(prov.createdNames == [GuildChannelNames.controlCategory, GuildChannelNames.redmineReportChannel])
    }
}
