import Testing
import Foundation
@testable import DiscordAgentBridge

// MARK: - Fake provisioner (mirrors TS FakeProvisioner)

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
        .appendingPathComponent("dab-gc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Global config not required for server-only ops, but keep a real ConfigStore dir.
    return ConfigStore(baseDir: dir)
}

// MARK: - alreadyDone

@Suite("GuildChannels alreadyDone")
struct GuildChannelsAlreadyDoneTests {
    @Test func falseWhenMissingOrIncomplete() {
        #expect(isGuildChannelsAlreadyDone(existing: nil, channelExists: { _ in true }) == false)
        let partial = ServerChannels(
            categoryId: "c", controlChannelId: "ctrl", sessionsCategoryId: "s", statusChannelId: nil
        )
        #expect(isGuildChannelsAlreadyDone(existing: partial, channelExists: { _ in true }) == false)
    }

    @Test func trueWhenAllFourExist() {
        let full = ServerChannels(
            categoryId: "cat",
            controlChannelId: "ctrl",
            sessionsCategoryId: "sess",
            statusChannelId: "stat"
        )
        let alive: Set = ["cat", "ctrl", "sess", "stat"]
        #expect(isGuildChannelsAlreadyDone(existing: full, channelExists: { alive.contains($0) }))
    }

    @Test func falseWhenAnyChannelDeleted() {
        let full = ServerChannels(
            categoryId: "cat",
            controlChannelId: "ctrl",
            sessionsCategoryId: "sess",
            statusChannelId: "stat"
        )
        let alive: Set = ["cat", "ctrl", "sess"] // status missing
        #expect(isGuildChannelsAlreadyDone(existing: full, channelExists: { alive.contains($0) }) == false)
    }
}

// MARK: - ensureGuildChannels

@Suite("GuildChannels ensure")
struct GuildChannelsEnsureTests {
    @Test func createsFourAndPersists() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let channels = try await ensureGuildChannels(provisioner: prov, configStore: store)

        #expect(prov.createdNames.count == 4)
        #expect(!channels.categoryId.isEmpty)
        #expect(!channels.controlChannelId.isEmpty)
        #expect(!channels.sessionsCategoryId.isEmpty)
        #expect(channels.statusChannelId != nil)

        #expect(prov.channels[channels.controlChannelId]?.parent == channels.categoryId)
        #expect(prov.channels[channels.statusChannelId!]?.parent == channels.categoryId)

        let saved = await store.loadServerConfig(guildId: "g1")
        #expect(saved?.channels == channels)
    }

    @Test func idempotentSecondRunCreatesNothing() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let first = try await ensureGuildChannels(provisioner: prov, configStore: store)
        #expect(prov.createdNames.count == 4)
        let second = try await ensureGuildChannels(provisioner: prov, configStore: store)
        #expect(prov.createdNames.count == 4)
        #expect(second == first)
    }

    @Test func recreatesOnlyDeletedChannel() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let first = try await ensureGuildChannels(provisioner: prov, configStore: store)
        prov.channels.removeValue(forKey: first.controlChannelId)
        let second = try await ensureGuildChannels(provisioner: prov, configStore: store)

        #expect(second.categoryId == first.categoryId)
        #expect(second.sessionsCategoryId == first.sessionsCategoryId)
        #expect(second.controlChannelId != first.controlChannelId)
        #expect(prov.createdNames.count == 5)
        #expect(await store.loadServerConfig(guildId: "g1")?.channels?.controlChannelId == second.controlChannelId)
    }

    @Test func renamesOldControlChannelName() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        prov.seed(id: "cat", name: "Control Category", type: "category")
        prov.seed(id: "ctrl", name: "agent-start", type: "text")
        prov.seed(id: "sess-cat", name: "Sessions Category", type: "category")
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            channels: ServerChannels(
                categoryId: "cat",
                controlChannelId: "ctrl",
                sessionsCategoryId: "sess-cat",
                statusChannelId: nil
            )
        ))

        let channels = try await ensureGuildChannels(provisioner: prov, configStore: store)
        #expect(channels.controlChannelId == "ctrl")
        #expect(prov.createdNames == [GuildChannelNames.statusChannel])
        #expect(prov.renamed["ctrl"] == GuildChannelNames.controlChannel)
        #expect(prov.channels["ctrl"]?.name == GuildChannelNames.controlChannel)
    }

    @Test func doesNotRenameWhenNameMatches() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        _ = try await ensureGuildChannels(provisioner: prov, configStore: store)
        prov.renamed.removeAll()
        _ = try await ensureGuildChannels(provisioner: prov, configStore: store)
        #expect(prov.renamed.isEmpty)
    }

    @Test func preservesExistingAuthOnFirstSetup() async throws {
        let store = try await tempStore()
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            auth: ServerAuthPartial(executeRoleIds: ["role-exec"])
        ))
        let prov = FakeProvisioner()
        _ = try await ensureGuildChannels(provisioner: prov, configStore: store)
        let saved = await store.loadServerConfig(guildId: "g1")
        #expect(saved?.auth?.executeRoleIds == ["role-exec"])
        #expect(saved?.channels != nil)
    }

    @Test func preservesNotificationsAcrossReProvision() async throws {
        let notifications = NotificationsSection(
            enabled: false,
            channelId: "custom-status",
            events: NotificationEvents(toolUse: true)
        )
        let store = try await tempStore()
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            notifications: notifications
        ))
        let prov = FakeProvisioner()
        _ = try await ensureGuildChannels(provisioner: prov, configStore: store)
        #expect(await store.loadServerConfig(guildId: "g1")?.notifications == notifications)
    }
}

// MARK: - autoProvision

@Suite("GuildChannels autoProvision")
struct GuildChannelsAutoProvisionTests {
    @Test func provisionsWhenMissing() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let channels = await autoProvisionGuild(provisioner: prov, configStore: store)
        #expect(prov.createdNames.count == 4)
        #expect(channels?.controlChannelId != nil)
        #expect(await store.loadServerConfig(guildId: "g1")?.channels == channels)
    }

    @Test func idempotentWhenAlreadyProvisioned() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let first = await autoProvisionGuild(provisioner: prov, configStore: store)
        let second = await autoProvisionGuild(provisioner: prov, configStore: store)
        #expect(prov.createdNames.count == 4)
        #expect(second == first)
    }

    @Test func missingManageChannelsSkips() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner(manageChannels: false)
        let result = await autoProvisionGuild(provisioner: prov, configStore: store)
        #expect(result == nil)
        #expect(prov.createdNames.isEmpty)
        #expect(await store.loadServerConfig(guildId: "g1")?.channels == nil)
    }
}

// MARK: - sessionChannelName / createSessionChannel

@Suite("GuildChannels session channel")
struct GuildChannelsSessionTests {
    @Test func sessionChannelNameSlugifies() {
        #expect(sessionChannelName("/home/me/My_App") == "proj-my-app")
        #expect(sessionChannelName("/home/me/foo.bar") == "proj-foo-bar")
        #expect(sessionChannelName("/home/me/repo/") == "proj-repo")
    }

    @Test func sessionChannelNameFallback() {
        #expect(sessionChannelName("/") == "proj-session")
        #expect(sessionChannelName("///") == "proj-session")
    }

    @Test func sessionChannelNameCapsAt100() {
        let long = "/x/" + String(repeating: "a", count: 200)
        #expect(sessionChannelName(long).count <= 100)
    }

    @Test func createSessionChannelParentsUnderCategory() async throws {
        let prov = FakeProvisioner()
        let created = try await createSessionChannel(
            provisioner: prov,
            folderPath: "/abs/path/My Project",
            sessionsCategoryId: "sessions-cat"
        )
        #expect(created.name == "proj-my-project")
        #expect(prov.channels[created.id]?.parent == "sessions-cat")
    }

    @Test func createSessionChannelWithoutParent() async throws {
        let prov = FakeProvisioner()
        let created = try await createSessionChannel(
            provisioner: prov,
            folderPath: "/abs/path/thing",
            sessionsCategoryId: nil
        )
        #expect(prov.channels[created.id]?.parent == nil)
    }

    @Test func resolveSessionChannelIdCreatesWhenCategoryPresent() async {
        let prov = FakeProvisioner()
        let id = await resolveSessionChannelId(
            provisioner: prov,
            folderPath: "/home/me/MyApp",
            sessionsCategoryId: "sess-cat",
            fallbackChannelId: "orig-ch"
        )
        #expect(id != "orig-ch")
        #expect(prov.channels[id]?.name == "proj-myapp")
        #expect(prov.channels[id]?.parent == "sess-cat")
    }

    @Test func resolveSessionChannelIdFallsBackWithoutCategory() async {
        let prov = FakeProvisioner()
        let id = await resolveSessionChannelId(
            provisioner: prov,
            folderPath: "/home/me/MyApp",
            sessionsCategoryId: nil,
            fallbackChannelId: "orig-ch"
        )
        #expect(id == "orig-ch")
        #expect(prov.createdNames.isEmpty)
    }

    @Test func resolveSessionChannelIdFallsBackWithoutProvisioner() async {
        let id = await resolveSessionChannelId(
            provisioner: nil,
            folderPath: "/home/me/MyApp",
            sessionsCategoryId: "sess-cat",
            fallbackChannelId: "orig-ch"
        )
        #expect(id == "orig-ch")
    }

    @Test func resolveSessionChannelIdFallsBackOnCreateFailure() async {
        let prov = ThrowingProvisioner()
        let id = await resolveSessionChannelId(
            provisioner: prov,
            folderPath: "/home/me/MyApp",
            sessionsCategoryId: "sess-cat",
            fallbackChannelId: "orig-ch"
        )
        #expect(id == "orig-ch")
    }
}

/// Fake that always fails create — for resolveSessionChannelId fallback tests.
private final class ThrowingProvisioner: GuildChannelProvisioner, @unchecked Sendable {
    let guildId = "g1"
    func canManageChannels() async -> Bool { true }
    func channelExists(_ id: String) async -> Bool { false }
    func ensureCategory(name: String, existingId: String?) async throws -> ProvisionedChannel {
        throw NSError(domain: "test", code: 1)
    }
    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel {
        throw NSError(domain: "test", code: 1)
    }
    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel {
        throw NSError(domain: "test", code: 1)
    }
    func renameChannel(id: String, name: String) async throws {}
    func deleteChannel(id: String) async throws {}
}

// MARK: - alreadyDone async against live fake

@Suite("GuildChannels alreadyDone async")
struct GuildChannelsAlreadyDoneAsyncTests {
    @Test func matchesAfterEnsure() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let channels = try await ensureGuildChannels(provisioner: prov, configStore: store)
        #expect(await isGuildChannelsAlreadyDone(existing: channels, provisioner: prov))
        // Drop status → not done
        if let sid = channels.statusChannelId {
            prov.channels.removeValue(forKey: sid)
        }
        #expect(await isGuildChannelsAlreadyDone(existing: channels, provisioner: prov) == false)
    }
}
