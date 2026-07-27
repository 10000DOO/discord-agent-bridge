import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-cfgpanel-access-\(UUID().uuidString)", isDirectory: true)
}

private func seedGlobal(_ store: ConfigStore) async throws {
    try await store.save(AppConfig(
        discord: DiscordSecrets(token: "bot-token-abc", clientId: "123456789"),
        auth: GlobalAuth(
            adminRoleIds: ["role-admin-g"],
            executeRoleIds: ["role-exec-g"],
            readOnlyRoleIds: ["role-read-g"],
            dmPolicy: "deny"
        ),
        defaults: DefaultsSection(mode: "claude", claudeModel: "opus", permissionMode: "default"),
        locale: "ko"
    ))
}

private func makePanel(store: ConfigStore) async throws -> ConfigPanel {
    let global = try await store.load()
    let server = await store.loadServerConfig(guildId: "g1")
    return ConfigPanel(options: ConfigPanelOptions(
        guildId: "g1",
        ownerId: "discord-admin",
        configStore: store,
        defaults: configPanelDefaults(global: global, server: server),
        backends: Backend.allCases.map(\.rawValue),
        isKnownBackend: { Backend(rawValue: $0) != nil },
        permModes: [.init(value: "default", label: "default")]
    ))
}

private func accessUserSelect(_ sub: ConfigPanelSubView) -> (id: String, defaultUserIds: [String], maxValues: Int)? {
    sub.rows.flatMap(\.components).compactMap { component in
        if case .userSelect(
            customId: let id,
            placeholder: _,
            defaultUserIds: let ids,
            minValues: _,
            maxValues: let maxValues
        ) = component {
            return (id: id, defaultUserIds: ids, maxValues: maxValues)
        }
        return nil
    }.first
}

private func accessTierOptions(_ sub: ConfigPanelSubView) -> [WizardSelectOption]? {
    sub.rows.flatMap(\.components).compactMap { component in
        if case .select(let id, _, let options) = component, id == ConfigPanelIds.accessTier {
            return options
        }
        return nil
    }.first
}

@Suite("ConfigPanel member override sub-panel")
struct ConfigPanelAccessTests {
    @Test func accessIdsUseTheConfigPanelPrefix() {
        #expect(isConfigPanelId(ConfigPanelIds.accessOpen))
        #expect(isConfigPanelId(ConfigPanelIds.accessUser))
        #expect(isConfigPanelId(ConfigPanelIds.accessTier))
        #expect(isConfigPanelId(ConfigPanelIds.accessApply))
        #expect(isConfigPanelId(ConfigPanelIds.accessReset))
    }

    @Test func mainPanelKeepsAccessButtonBesideExistingButtons() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let view = try await makePanel(store: store).render()

        #expect(view.roleRows.count == 4)
        let ids = view.roleRows[3].components.compactMap { component -> String? in
            if case .button(let id, _, _) = component { return id }
            return nil
        }
        #expect(ids == [
            ConfigPanelIds.save,
            ConfigPanelIds.notifOpen,
            ConfigPanelIds.renderOpen,
            ConfigPanelIds.accessOpen,
        ])
    }

    @Test func accessPanelEditsOneMemberWithAllFourTiers() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        guard case .accessPanel(let sub) = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessOpen)) else {
            Issue.record("expected access panel")
            return
        }
        #expect(accessUserSelect(sub)?.id == ConfigPanelIds.accessUser)
        #expect(accessUserSelect(sub)?.defaultUserIds == [])
        #expect(accessUserSelect(sub)?.maxValues == 1)
        #expect(accessTierOptions(sub)?.map(\.value) == MemberTierSetting.allCases.map(\.rawValue))
        let buttonIds = sub.rows.flatMap(\.components).compactMap { component -> String? in
            if case .button(let id, _, _) = component { return id }
            return nil
        }
        #expect(buttonIds == [ConfigPanelIds.accessApply, ConfigPanelIds.accessReset])
    }

    @Test func selectionIsNotPersistedUntilApplyAndNoneOverrideIsStored() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        guard case .accessUpdated = await panel.handle(ConfigPanelInput(
            id: ConfigPanelIds.accessUser,
            values: ["member-1"]
        )) else {
            Issue.record("expected access refresh after member selection")
            return
        }
        guard case .accessUpdated = await panel.handle(ConfigPanelInput(
            id: ConfigPanelIds.accessTier,
            value: MemberTierSetting.none.rawValue
        )) else {
            Issue.record("expected access refresh after tier selection")
            return
        }
        #expect(await store.loadServerConfig(guildId: "g1") == nil)

        guard case .accessUpdated = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessApply)) else {
            Issue.record("expected access refresh after save")
            return
        }
        #expect(await store.loadServerConfig(guildId: "g1")?.auth?.memberTierOverrides == ["member-1": .none])
    }

    @Test func resetRemovesOnlySelectedOverrideAndRestoresEffectiveDefault() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(
                adminRoleIds: ["legacy-role"],
                adminUserIds: ["legacy-user"],
                memberTierOverrides: ["member-1": .execute, "member-2": .readOnly]
            )
        ))
        let panel = try await makePanel(store: store)
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessUser, values: ["member-1"]))

        guard case .accessUpdated(let sub) = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessReset)) else {
            Issue.record("expected access refresh after reset")
            return
        }
        #expect(sub.description.contains("기본 권한"))
        let auth = await store.loadServerConfig(guildId: "g1")?.auth
        #expect(auth?.memberTierOverrides == ["member-2": .readOnly])
        #expect(auth?.adminRoleIds == ["legacy-role"])
        #expect(auth?.adminUserIds == ["legacy-user"])
    }
}
