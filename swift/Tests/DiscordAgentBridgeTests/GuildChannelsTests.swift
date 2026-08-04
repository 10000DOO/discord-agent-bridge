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

    func setParent(id: String, parentId: String) async throws {
        if var ch = channels[id] {
            ch.parent = parentId
            channels[id] = ch
        }
    }

    func deleteChannel(id: String) async throws {
        channels.removeValue(forKey: id)
        deleted.append(id)
    }

    func childChannelIds(categoryId: String) async throws -> [String] {
        channels.filter { $0.value.parent == categoryId }.map(\.key)
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

    // WO-8b regression: persistChannels must not clobber redmine/capabilities.
    @Test func ensureGuildChannelsPreservesRedmineAndCapabilities() async throws {
        let store = try await tempStore()
        let redmine = RedmineSection(url: "https://redmine.example.com", apiKeyEncrypted: Data("cipher".utf8))
        let capabilities = CapabilitiesPartial(usagePanel: false)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            capabilities: capabilities,
            redmine: redmine
        ))
        let prov = FakeProvisioner()
        _ = try await ensureGuildChannels(provisioner: prov, configStore: store)
        let loaded = await store.loadServerConfig(guildId: "g1")
        #expect(loaded?.redmine == redmine)
        #expect(loaded?.capabilities == capabilities)
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
        #expect(sessionChannelName("/home/me/My_App").hasSuffix("-my-app-proj"))
        #expect(sessionChannelName("/home/me/foo.bar").hasSuffix("-foo-bar-proj"))
        #expect(sessionChannelName("/home/me/repo/").hasSuffix("-repo-proj"))
    }

    @Test func sessionChannelNameFallback() {
        #expect(sessionChannelName("/").hasSuffix("-session-proj"))
        #expect(sessionChannelName("///").hasSuffix("-session-proj"))
    }

    @Test func sessionChannelNameCapsAt100() {
        let long = "/x/" + String(repeating: "a", count: 200)
        let name = sessionChannelName(long)
        #expect(name.count <= 100)
        #expect(name.hasSuffix("-proj"))
    }

    @Test func sessionChannelNameIsUniquePerCall() {
        // Same folder → distinct channel names (random prefix), so repeated sessions from one
        // project folder don't collide.
        #expect(sessionChannelName("/home/me/My_App") != sessionChannelName("/home/me/My_App"))
    }

    @Test func createSessionChannelParentsUnderCategory() async throws {
        let prov = FakeProvisioner()
        let created = try await createSessionChannel(
            provisioner: prov,
            folderPath: "/abs/path/My Project",
            sessionsCategoryId: "sessions-cat"
        )
        #expect(created.name.hasSuffix("-my-project-proj"))
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
        #expect(prov.channels[id]?.name.hasSuffix("-myapp-proj") == true)
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

// MARK: - deleteSessionChannel / shouldDeleteSessionChannelOnClose (G-P0-04)

@Suite("GuildChannels delete session on close")
struct GuildChannelsDeleteSessionTests {
    private let structure = ServerChannels(
        categoryId: "cat",
        controlChannelId: "ctrl",
        sessionsCategoryId: "sess-cat",
        statusChannelId: "status"
    )

    @Test func shouldDeleteWhenUnderSessionsCategory() {
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "sess-1",
                channelName: "my-session",
                parentId: "sess-cat",
                serverChannels: structure
            )
        )
    }

    @Test func shouldDeleteWhenProjNameSuffix() {
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "sess-1",
                channelName: "a1b2c3-thing-proj",
                parentId: nil,
                serverChannels: structure
            )
        )
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "sess-1",
                channelName: "a1b2c3-thing-proj",
                parentId: nil,
                serverChannels: nil
            )
        )
    }

    // Regression guard: pre-update channels used a `proj-` prefix (not the current `-proj` suffix
    // scheme). Those still-live legacy channels must remain deletable on `/agent close`.
    @Test func shouldDeleteWhenLegacyProjNamePrefix() {
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "sess-1",
                channelName: "proj-old-session",
                parentId: nil,
                serverChannels: structure
            )
        )
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "sess-1",
                channelName: "proj-old-session",
                parentId: nil,
                serverChannels: nil
            )
        )
    }

    // WO-7 (design_orchestration_module_agents.md, R8): the 3-5 trap this guards against — a lead
    // ("*-orc") or module ("*-agent") channel matches neither the sessions-category-parent check
    // nor the `-proj` suffix, so without this it would survive `/agent close`.
    @Test func shouldDeleteWhenOrcOrAgentNameSuffix() {
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "orc-1", channelName: "a1b2c3-myproj-orc", parentId: nil, serverChannels: structure
            )
        )
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "agent-1", channelName: "a1b2c3-core-agent", parentId: nil, serverChannels: structure
            )
        )
    }

    @Test func shouldDeleteWhenUnderOrchestrationCategory() {
        #expect(
            shouldDeleteSessionChannelOnClose(
                channelId: "sess-1", channelName: "weirdly-named-channel", parentId: "orch-cat-1",
                serverChannels: structure, orchestrationCategoryIds: ["orch-cat-1"]
            )
        )
        // Neither in the set nor -proj/-orc/-agent suffixed → still protected.
        #expect(
            !shouldDeleteSessionChannelOnClose(
                channelId: "sess-1", channelName: "weirdly-named-channel", parentId: "other-cat",
                serverChannels: structure, orchestrationCategoryIds: ["orch-cat-1"]
            )
        )
    }

    @Test func neverDeletesControlStatusCategory() {
        for id in ["ctrl", "status", "cat", "sess-cat"] {
            #expect(
                !shouldDeleteSessionChannelOnClose(
                    channelId: id,
                    channelName: "a1b2c3-spoof-proj",
                    parentId: "sess-cat",
                    serverChannels: structure
                ),
                "must not delete protected id \(id)"
            )
        }
    }

    // WO-7 completion criterion ②: control/status channels must stay protected even when the
    // orchestration category machinery is in play (e.g. a stale/misconfigured category id that
    // happens to collide with a protected parent).
    @Test func neverDeletesControlStatusCategoryEvenWithOrchestrationCategoryIds() {
        for id in ["ctrl", "status", "cat", "sess-cat"] {
            #expect(
                !shouldDeleteSessionChannelOnClose(
                    channelId: id, channelName: "a1b2c3-spoof-orc", parentId: "orch-cat-1",
                    serverChannels: structure, orchestrationCategoryIds: ["orch-cat-1"]
                ),
                "must not delete protected id \(id)"
            )
        }
    }

    @Test func skipsOrdinaryBoundChannel() {
        #expect(
            !shouldDeleteSessionChannelOnClose(
                channelId: "general",
                channelName: "general",
                parentId: "other-cat",
                serverChannels: structure
            )
        )
        #expect(
            !shouldDeleteSessionChannelOnClose(
                channelId: "general",
                channelName: nil,
                parentId: nil,
                serverChannels: nil
            )
        )
    }

    @Test func deleteSessionChannelCallsProvisionerWhenEligible() async {
        let prov = FakeProvisioner()
        prov.seed(id: "sess-1", name: "a1b2c3-thing-proj", type: "text")
        await deleteSessionChannel(
            provisioner: prov,
            channelId: "sess-1",
            channelName: "a1b2c3-thing-proj",
            parentId: "sess-cat",
            serverChannels: structure
        )
        #expect(prov.deleted == ["sess-1"])
        #expect(prov.channels["sess-1"] == nil)
    }

    @Test func deleteSessionChannelCallsProvisionerForOrchestrationSetChannel() async {
        let prov = FakeProvisioner()
        prov.seed(id: "agent-1", name: "a1b2c3-core-agent", type: "text")
        await deleteSessionChannel(
            provisioner: prov,
            channelId: "agent-1",
            channelName: "a1b2c3-core-agent",
            parentId: "orch-cat-1",
            serverChannels: structure,
            orchestrationCategoryIds: ["orch-cat-1"]
        )
        #expect(prov.deleted == ["agent-1"])
        #expect(prov.channels["agent-1"] == nil)
    }

    @Test func deleteSessionChannelSkipsControlEvenIfNameLooksLikeSession() async {
        let prov = FakeProvisioner()
        prov.seed(id: "ctrl", name: "a1b2c3-spoof-proj", type: "text")
        await deleteSessionChannel(
            provisioner: prov,
            channelId: "ctrl",
            channelName: "a1b2c3-spoof-proj",
            parentId: "sess-cat",
            serverChannels: structure
        )
        #expect(prov.deleted.isEmpty)
        #expect(prov.channels["ctrl"] != nil)
    }

    @Test func deleteSessionChannelNoopsWithoutProvisioner() async {
        await deleteSessionChannel(
            provisioner: nil,
            channelId: "sess-1",
            channelName: "a1b2c3-thing-proj",
            parentId: "sess-cat",
            serverChannels: structure
        )
        // No throw — best-effort only.
    }
}

// MARK: - isControlPlaneChannel (design_orchestration_project_scoped_command.md §4.1)

@Suite("GuildChannels isControlPlaneChannel")
struct GuildChannelsIsControlPlaneChannelTests {
    private let structure = ServerChannels(
        categoryId: "cat",
        controlChannelId: "ctrl",
        sessionsCategoryId: "sess-cat",
        statusChannelId: "status"
    )

    @Test func trueForControlChannel() {
        #expect(isControlPlaneChannel(channelId: "ctrl", serverChannels: structure, redmineReportChannelId: nil))
    }

    @Test func trueForStatusChannel() {
        #expect(isControlPlaneChannel(channelId: "status", serverChannels: structure, redmineReportChannelId: nil))
    }

    @Test func trueForRedmineReportChannel() {
        #expect(isControlPlaneChannel(channelId: "redmine-1", serverChannels: structure, redmineReportChannelId: "redmine-1"))
    }

    @Test func falseForOrdinarySessionChannel() {
        #expect(!isControlPlaneChannel(channelId: "sess-1", serverChannels: structure, redmineReportChannelId: "redmine-1"))
    }

    @Test func falseWhenServerChannelsAndRedmineBothNil() {
        #expect(!isControlPlaneChannel(channelId: "ctrl", serverChannels: nil, redmineReportChannelId: nil))
    }

    @Test func falseForEmptyStatusOrRedmineId() {
        // Empty string ids (never a real Discord snowflake) must not match by accident.
        let sc = ServerChannels(categoryId: "cat", controlChannelId: "ctrl", sessionsCategoryId: "sess-cat", statusChannelId: "")
        #expect(!isControlPlaneChannel(channelId: "", serverChannels: sc, redmineReportChannelId: ""))
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
    func setParent(id: String, parentId: String) async throws {}
    func deleteChannel(id: String) async throws {}
    func childChannelIds(categoryId: String) async throws -> [String] {
        throw NSError(domain: "test", code: 1)
    }
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
