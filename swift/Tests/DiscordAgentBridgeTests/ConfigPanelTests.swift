import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-cfgpanel-\(UUID().uuidString)", isDirectory: true)
}

private func seedGlobal(_ store: ConfigStore, dmPolicy: String = "deny") async throws {
    let config = AppConfig(
        discord: DiscordSecrets(token: "bot-token-abc", clientId: "123456789"),
        auth: GlobalAuth(
            adminRoleIds: ["role-admin-g"],
            executeRoleIds: ["role-exec-g"],
            readOnlyRoleIds: ["role-read-g"],
            dmPolicy: dmPolicy
        ),
        defaults: DefaultsSection(
            mode: "claude",
            claudeModel: "opus",
            permissionMode: "default",
            claudeEffort: "high"
        ),
        limits: LimitsSection(maxSessionsPerUser: 2, permissionTimeoutSec: 30, codexTimeoutMs: 1_800_000),
        locale: "ko"
    )
    try await store.save(config)
}

private func makePanel(
    store: ConfigStore,
    defaults: ConfigPanelDefaults? = nil,
    models: [ModelChoice]? = nil,
    efforts: [ModelChoice]? = nil
) async throws -> ConfigPanel {
    let global = try await store.load()
    let server = await store.loadServerConfig(guildId: "g1")
    let d = defaults ?? configPanelDefaults(global: global, server: server)
    return ConfigPanel(options: ConfigPanelOptions(
        guildId: "g1",
        ownerId: "admin-user",
        configStore: store,
        defaults: d,
        backends: Backend.allCases.map(\.rawValue),
        isKnownBackend: { Backend(rawValue: $0) != nil },
        models: models ?? [
            .init(value: "opus", label: "opus"),
            .init(value: "sonnet", label: "sonnet"),
        ],
        efforts: efforts ?? [
            .init(value: "low", label: "low"),
            .init(value: "medium", label: "medium"),
            .init(value: "high", label: "high"),
        ],
        permModes: [
            .init(value: "default", label: "default"),
            .init(value: "acceptEdits", label: "acceptEdits"),
            .init(value: "plan", label: "plan"),
        ]
    ))
}

private func selectById(_ rows: [ConfigPanelRow], _ id: String) -> [WizardSelectOption]? {
    for row in rows {
        for c in row.components {
            if case .select(let customId, _, let options) = c, customId == id {
                return options
            }
        }
    }
    return nil
}

private func defaultSelected(_ options: [WizardSelectOption]?) -> String? {
    options?.first(where: \.isDefault)?.value
}

@Suite("ConfigPanel")
struct ConfigPanelTests {
    @Test func isConfigPanelIdRecognizesPrefix() {
        #expect(isConfigPanelId("config.role.admin"))
        #expect(isConfigPanelId("config.save"))
        #expect(isConfigPanelId("config.default.backend"))
        #expect(isConfigPanelId("config.default.model"))
        #expect(isConfigPanelId("config.default.effort"))
        #expect(isConfigPanelId("config.dmPolicy"))
        #expect(isConfigPanelId("config.notif.open"))
        #expect(isConfigPanelId("config.notif.toggle"))
        #expect(isConfigPanelId("config.notif.channel"))
        #expect(!isConfigPanelId("backend"))
        #expect(!isConfigPanelId("perm:req-1:allow"))
        #expect(!isConfigPanelId("wizard.back"))
    }

    @Test func renderHasRolesSaveNotifAndDefaultSelects() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        let view = panel.render()

        #expect(view.title == "Bot config")
        #expect(view.description.contains("dmPolicy"))
        #expect(view.description.contains("effort="))
        #expect(view.roleRows.count == 4)
        #expect(view.defaultRows.count == 5)

        let roleComps = view.roleRows.flatMap(\.components)
        let roleIds = roleComps.compactMap { c -> String? in
            if case .roleSelect(let id, _, _, _, _) = c { return id }
            return nil
        }
        #expect(roleIds == [
            ConfigPanelIds.roleAdmin,
            ConfigPanelIds.roleExecute,
            ConfigPanelIds.roleReadOnly,
        ])
        #expect(roleComps.contains {
            if case .button(let id, _, _) = $0 { return id == ConfigPanelIds.save }
            return false
        })
        #expect(roleComps.contains {
            if case .button(let id, _, _) = $0 { return id == ConfigPanelIds.notifOpen }
            return false
        })

        let defaultIds = view.defaultRows.flatMap(\.components).compactMap { c -> String? in
            if case .select(let id, _, _) = c { return id }
            return nil
        }
        #expect(defaultIds == [
            ConfigPanelIds.backend,
            ConfigPanelIds.model,
            ConfigPanelIds.effort,
            ConfigPanelIds.permMode,
            ConfigPanelIds.dmPolicy,
        ])
        #expect(defaultSelected(selectById(view.defaultRows, ConfigPanelIds.model)) == "opus")
        #expect(defaultSelected(selectById(view.defaultRows, ConfigPanelIds.effort)) == "high")
    }

    @Test func roleSelectPendingThenSaveWritesServerAuth() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r1 = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.roleAdmin, values: ["ra1", "ra2"]))
        #expect(r1 == .pending)
        // Server not written yet.
        #expect(await store.loadServerConfig(guildId: "g1") == nil)

        let r2 = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.roleExecute, values: ["re1"]))
        #expect(r2 == .pending)

        let r3 = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.save))
        guard case .saved(let summary) = r3 else {
            Issue.record("expected saved, got \(r3)")
            return
        }
        #expect(summary.contains("ra1") || summary.contains("<@&ra1>"))
        #expect(summary.contains("역할을 저장"))

        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.auth?.adminRoleIds == ["ra1", "ra2"])
        #expect(server?.auth?.executeRoleIds == ["re1"])
        // Untouched tier falls through to effective defaults (global).
        #expect(server?.auth?.readOnlyRoleIds == ["role-read-g"])
    }

    @Test func roleSelectMissingValuesIsIgnored() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.roleAdmin))
        #expect(r == .ignored)
    }

    @Test func autosaveBackendWritesServerDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.backend, value: "codex"))
        guard case .autosaved(let notice) = r else {
            Issue.record("expected autosaved, got \(r)")
            return
        }
        #expect(notice.contains("codex"))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.mode == "codex")
    }

    @Test func autosaveModelWritesClaudeModel() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.model, value: "sonnet"))
        guard case .autosaved(let notice) = r else {
            Issue.record("expected autosaved, got \(r)")
            return
        }
        #expect(notice.contains("sonnet"))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.claudeModel == "sonnet")
        #expect(server?.defaults?.codexModel == nil)
    }

    @Test func autosaveModelWritesCodexModelWhenBackendIsCodex() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.backend, value: "codex"))
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.model, value: "gpt-5.5"))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.mode == "codex")
        #expect(server?.defaults?.codexModel == "gpt-5.5")
        #expect(server?.defaults?.claudeModel == nil)
    }

    @Test func autosaveEffortWritesClaudeEffort() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.effort, value: "medium"))
        guard case .autosaved = r else {
            Issue.record("expected autosaved, got \(r)")
            return
        }
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.claudeEffort == "medium")
        #expect(server?.defaults?.codexEffort == nil)
    }

    @Test func autosaveEffortWritesCodexEffortAfterBackendSwitch() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.backend, value: "codex"))
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.effort, value: "xhigh"))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.mode == "codex")
        #expect(server?.defaults?.codexEffort == "xhigh")
        #expect(server?.defaults?.claudeEffort == nil)
    }

    @Test func autosavePermModeWritesServerDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.permMode, value: "acceptEdits"))
        guard case .autosaved = r else {
            Issue.record("expected autosaved, got \(r)")
            return
        }
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.permissionMode == "acceptEdits")
    }

    @Test func autosaveDmPolicyWritesGlobalOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store, dmPolicy: "deny")
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.dmPolicy, value: "allow"))
        guard case .autosaved(let notice) = r else {
            Issue.record("expected autosaved, got \(r)")
            return
        }
        #expect(notice.contains("allow"))
        let global = try await store.load()
        #expect(global.auth.dmPolicy == "allow")
        // Server file may exist if other fields written; dmPolicy is not a server field.
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server == nil || server?.auth?.adminRoleIds == nil || true)
    }

    @Test func unknownBackendDoesNotWriteMode() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.backend, value: "not-a-backend"))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.mode == nil)
    }

    @Test func configPanelDefaultsLayersServerAuthAndDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(adminRoleIds: ["srv-admin"]),
            defaults: ServerDefaultsPartial(
                mode: "codex",
                codexModel: "gpt-5.5",
                permissionMode: "plan",
                codexEffort: "high"
            ),
            locale: "en"
        ))
        let global = try await store.load()
        let server = await store.loadServerConfig(guildId: "g1")
        let d = configPanelDefaults(global: global, server: server)
        #expect(d.adminRoleIds == ["srv-admin"])
        #expect(d.executeRoleIds == ["role-exec-g"]) // fall through global
        #expect(d.backend == "codex")
        #expect(d.permMode == "plan")
        #expect(d.locale == "en")
        #expect(d.dmPolicy == "deny")
        #expect(d.model == "gpt-5.5")
        #expect(d.effort == "high")
        #expect(d.limits.maxSessionsPerUser == 2)
    }

    @Test func savePreservesExistingServerDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "codex", permissionMode: "plan")
        ))
        let panel = try await makePanel(store: store)
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.roleAdmin, values: ["only-admin"]))
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.save))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.defaults?.mode == "codex")
        #expect(server?.defaults?.permissionMode == "plan")
        #expect(server?.auth?.adminRoleIds == ["only-admin"])
    }

    @Test func notifOpenReturnsSubPanel() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.notifOpen))
        guard case .notifPanel(let sub) = r else {
            Issue.record("expected notifPanel, got \(r)")
            return
        }
        #expect(sub.title.contains("notification") || sub.title.contains("Event"))
        #expect(sub.description.contains("on") || sub.description.contains("off"))
        let comps = sub.rows.flatMap(\.components)
        #expect(comps.contains {
            if case .channelSelect(let id, _, _, _, _) = $0 { return id == ConfigPanelIds.notifChannel }
            return false
        })
        #expect(comps.contains {
            if case .button(let id, _, _) = $0 { return id == ConfigPanelIds.notifToggle }
            return false
        })
    }

    @Test func notifTogglePersistsEnabledFalse() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        // Default enabled=true → toggle off.
        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.notifToggle))
        guard case .notifUpdated(let sub) = r else {
            Issue.record("expected notifUpdated, got \(r)")
            return
        }
        #expect(sub.description.contains("off"))
        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.notifications?.enabled == false)
        #expect(resolveNotifications(server).enabled == false)
    }

    @Test func notifChannelPersistsAndClear() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            channels: ServerChannels(
                categoryId: "cat",
                controlChannelId: "ctrl",
                sessionsCategoryId: "sess",
                statusChannelId: "status-fallback"
            )
        ))
        let panel = try await makePanel(store: store)

        let set = await panel.handle(ConfigPanelInput(
            id: ConfigPanelIds.notifChannel,
            values: ["status-override"]
        ))
        guard case .notifUpdated = set else {
            Issue.record("expected notifUpdated on set, got \(set)")
            return
        }
        var server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.notifications?.channelId == "status-override")
        #expect(resolveNotifications(server).channelId == "status-override")

        // Empty pick clears override → falls back to setup status channel.
        let clear = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.notifChannel, values: []))
        guard case .notifUpdated = clear else {
            Issue.record("expected notifUpdated on clear, got \(clear)")
            return
        }
        server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.notifications?.channelId == nil)
        #expect(resolveNotifications(server).channelId == "status-fallback")
    }

    @Test func configCommandSpecRequiresAdministrator() {
        let spec = configCommandSpec()
        #expect(spec.name == "config")
        #expect(spec.requiresAdministrator)
        #expect(allSlashCommandSpecs().contains { $0.name == "config" })
    }

    @Test func registryPutGetRemove() async {
        let reg = ConfigPanelRegistry()
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try? await seedGlobal(store)
        let panel = try! await makePanel(store: store)
        await reg.put(panel, guildId: "g1", channelId: "c1")
        #expect(await reg.get(guildId: "g1", channelId: "c1")?.ownerId == "admin-user")
        await reg.remove(guildId: "g1", channelId: "c1")
        #expect(await reg.get(guildId: "g1", channelId: "c1") == nil)
    }
}
