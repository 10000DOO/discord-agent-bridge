import Testing
import Foundation
import DiscordBM
@testable import DiscordAgentBridge
@testable import dab

// WO-1 (design_orchestration_module_agents.md): set category provisioning + lead channel
// move/rename. Mirrors GuildChannelsTests.swift's FakeProvisioner (that one is file-private).

private final class FakeProvisioner: GuildChannelProvisioner, @unchecked Sendable {
    let guildId: String
    /// id → (name, type)
    var channels: [String: (name: String, type: String)] = [:]
    private(set) var createdNames: [String] = []
    /// id → parentId, for createTextChannel calls only (WO-2 createModuleAgentChannel tests /
    /// WO-7 childChannelIds tests).
    private(set) var createdParents: [String: String] = [:]
    private(set) var deleted: [String] = []
    private var seq = 0

    init(guildId: String = "g1") {
        self.guildId = guildId
    }

    func seed(id: String, name: String, type: String = "category") {
        channels[id] = (name, type)
    }

    func canManageChannels() async -> Bool { true }
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
        channels[id] = (name, "category")
        createdNames.append(name)
        return ProvisionedChannel(id: id, name: name)
    }

    // Not exercised by ensureOrchestrationCategory — never called in those tests.
    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel {
        fatalError("unused by ensureOrchestrationCategory")
    }
    // Exercised by createModuleAgentChannel tests (WO-2) — mirrors GuildChannelsTests.swift's FakeProvisioner.
    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel {
        let id = nextId()
        channels[id] = (name, "text")
        createdNames.append(name)
        if let parentId { createdParents[id] = parentId }
        return ProvisionedChannel(id: id, name: name)
    }
    func renameChannel(id: String, name: String) async throws {}
    func setParent(id: String, parentId: String) async throws {}
    func deleteChannel(id: String) async throws {
        channels.removeValue(forKey: id)
        createdParents.removeValue(forKey: id)
        deleted.append(id)
    }
    func childChannelIds(categoryId: String) async throws -> [String] {
        createdParents.filter { $0.value == categoryId }.map(\.key)
    }
}

private func tempStore() async throws -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-orch-chan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ConfigStore(baseDir: dir)
}

// MARK: - ensureOrchestrationCategory

@Suite("ensureOrchestrationCategory")
struct EnsureOrchestrationCategoryTests {
    @Test func createsCategoryAndPersistsWhenMissing() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        let category = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-1",
            folderPath: "/home/me/MyProj"
        )
        #expect(category.name == "Agent - Orch - myproj · orc-1")
        #expect(prov.createdNames == ["Agent - Orch - myproj · orc-1"])
        let saved = await store.loadServerConfig(guildId: "g1")
        #expect(saved?.orchestration?["orc-1"]?.categoryId == category.id)
    }

    @Test func reusesStoredCategoryWithoutCreating() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        prov.seed(id: "cat-1", name: "Agent - Orch - myproj")
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            orchestration: ["orc-1": OrchestrationSet(categoryId: "cat-1")]
        ))

        let category = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-1",
            folderPath: "/home/me/MyProj"
        )
        #expect(category.id == "cat-1")
        #expect(prov.createdNames.isEmpty)
    }

    @Test func recreatesWhenStoredCategoryWasDeleted() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            orchestration: ["orc-1": OrchestrationSet(categoryId: "gone")]
        ))

        let category = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-1",
            folderPath: "/home/me/MyProj"
        )
        #expect(category.id != "gone")
        #expect(prov.createdNames == ["Agent - Orch - myproj · orc-1"])
    }

    @Test func newCategoriesForSameFolderDoNotCollideAcrossOrchestratorSets() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()

        let first = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-111111",
            folderPath: "/home/me/MyProj"
        )
        let second = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-222222",
            folderPath: "/home/me/MyProj"
        )

        #expect(first.id != second.id)
        #expect(first.name != second.name)
        #expect(first.name == "Agent - Orch - myproj · 111111")
        #expect(second.name == "Agent - Orch - myproj · 222222")
        let saved = await store.loadServerConfig(guildId: "g1")
        #expect(saved?.orchestration?["orc-111111"]?.categoryId == first.id)
        #expect(saved?.orchestration?["orc-222222"]?.categoryId == second.id)
    }

    @Test func preservesModuleSpecOnReuse() async throws {
        let store = try await tempStore()
        let prov = FakeProvisioner()
        prov.seed(id: "cat-1", name: "Agent - Orch - myproj")
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            orchestration: [
                "orc-1": OrchestrationSet(categoryId: "cat-1", moduleModel: "sonnet", moduleEffort: "high"),
            ]
        ))

        _ = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-1",
            folderPath: "/home/me/MyProj"
        )

        let saved = await store.loadServerConfig(guildId: "g1")
        #expect(saved?.orchestration?["orc-1"]?.categoryId == "cat-1")
        #expect(saved?.orchestration?["orc-1"]?.moduleModel == "sonnet")
        #expect(saved?.orchestration?["orc-1"]?.moduleEffort == "high")
    }

    @Test func preservesOtherSetsAndExistingServerConfig() async throws {
        let store = try await tempStore()
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(executeRoleIds: ["role-exec"]),
            orchestration: ["orc-other": OrchestrationSet(categoryId: "cat-other", moduleModel: "opus")]
        ))
        let prov = FakeProvisioner()

        _ = try await ensureOrchestrationCategory(
            provisioner: prov,
            configStore: store,
            orchestratorChannelId: "orc-1",
            folderPath: "/home/me/MyProj"
        )

        let saved = await store.loadServerConfig(guildId: "g1")
        #expect(saved?.auth?.executeRoleIds == ["role-exec"])
        #expect(saved?.orchestration?["orc-other"]?.categoryId == "cat-other")
        #expect(saved?.orchestration?["orc-other"]?.moduleModel == "opus")
        #expect(saved?.orchestration?["orc-1"] != nil)
    }
}

// MARK: - channel name slug rules

@Suite("orchestration channel name slugs")
struct OrchestrationChannelNameSlugTests {
    @Test func orchestratorChannelNameSlugifies() {
        #expect(orchestratorChannelName("/home/me/My_App").hasSuffix("-my-app-orc"))
        #expect(orchestratorChannelName("/home/me/foo bar!!").hasSuffix("-foo-bar-orc"))
        #expect(orchestratorChannelName("/home/me/repo/").hasSuffix("-repo-orc"))
    }

    @Test func orchestratorChannelNameFallback() {
        #expect(orchestratorChannelName("/").hasSuffix("-session-orc"))
        #expect(orchestratorChannelName("///").hasSuffix("-session-orc"))
    }

    @Test func orchestratorChannelNameCapsAt100() {
        let long = "/x/" + String(repeating: "a", count: 200)
        let name = orchestratorChannelName(long)
        #expect(name.count <= 100)
        #expect(name.hasSuffix("-orc"))
    }

    @Test func moduleAgentChannelNameSlugifies() {
        #expect(moduleAgentChannelName("Core Module").hasSuffix("-core-module-agent"))
        #expect(moduleAgentChannelName("UI!!").hasSuffix("-ui-agent"))
    }

    @Test func moduleAgentChannelNameFallback() {
        #expect(moduleAgentChannelName("").hasSuffix("-module-agent"))
    }

    @Test func moduleAgentChannelNameCapsAt100() {
        let long = String(repeating: "a", count: 200)
        let name = moduleAgentChannelName(long)
        #expect(name.count <= 100)
        #expect(name.hasSuffix("-agent"))
    }

    // sessionChannelName's own behavior must be untouched by the slugifyPathComponent extraction
    // (regression guard alongside GuildChannelsTests.swift's own coverage).
    @Test func sessionChannelNameUnaffected() {
        #expect(sessionChannelName("/home/me/My_App").hasSuffix("-my-app-proj"))
        #expect(sessionChannelName("/").hasSuffix("-session-proj"))
    }
}

// MARK: - createModuleAgentChannel (WO-2, mirrors GuildChannelsTests.swift's createSessionChannel tests)

@Suite("createModuleAgentChannel")
struct CreateModuleAgentChannelTests {
    @Test func parentsUnderSetCategory() async throws {
        let prov = FakeProvisioner()
        let created = try await createModuleAgentChannel(
            provisioner: prov,
            moduleName: "Core Module",
            categoryId: "cat-1"
        )
        #expect(created.name.hasSuffix("-core-module-agent"))
        #expect(prov.createdParents[created.id] == "cat-1")
    }
}

// MARK: - childChannelIds (WO-7 category-empty check)

@Suite("GuildChannelProvisioner childChannelIds")
struct ChildChannelIdsTests {
    @Test func reportsOnlyChildrenOfGivenCategoryAndDropsDeleted() async throws {
        let prov = FakeProvisioner()
        let core = try await createModuleAgentChannel(provisioner: prov, moduleName: "core", categoryId: "cat-1")
        let ui = try await createModuleAgentChannel(provisioner: prov, moduleName: "ui", categoryId: "cat-1")
        _ = try await createModuleAgentChannel(provisioner: prov, moduleName: "other", categoryId: "cat-2")

        #expect(try Set(await prov.childChannelIds(categoryId: "cat-1")) == [core.id, ui.id])

        try await prov.deleteChannel(id: core.id)
        #expect(try await prov.childChannelIds(categoryId: "cat-1") == [ui.id])
    }
}

// MARK: - setParent adapter best-effort (mirrors renameChannel)

private enum FakeSendError: Error { case simulated }

private final class ThrowingDiscordClient: DiscordClient, @unchecked Sendable {
    let appId: ApplicationSnowflake? = nil
    func send(request: DiscordHTTPRequest) async throws -> DiscordHTTPResponse {
        throw FakeSendError.simulated
    }
    func send<E: Sendable & Encodable & ValidatablePayload>(
        request: DiscordHTTPRequest,
        payload: E
    ) async throws -> DiscordHTTPResponse {
        throw FakeSendError.simulated
    }
    func sendMultipart<E: Sendable & MultipartEncodable & ValidatablePayload>(
        request: DiscordHTTPRequest,
        payload: E
    ) async throws -> DiscordHTTPResponse {
        throw FakeSendError.simulated
    }
}

@Suite("GuildChannelProvisioner adapter setParent")
struct SetParentAdapterTests {
    @Test func failedUpdateDoesNotThrow() async throws {
        let client = ThrowingDiscordClient()
        let provisioner = DiscordGuildChannelProvisioner(client: client, guildId: "g1")
        // The assertion is simply reaching the next line without a thrown error.
        try await provisioner.setParent(id: "chan-1", parentId: "cat-1")
    }
}
