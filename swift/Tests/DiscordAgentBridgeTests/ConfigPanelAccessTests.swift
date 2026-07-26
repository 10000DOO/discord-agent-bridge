import Testing
import Foundation
@testable import DiscordAgentBridge

// WO-4 (docs/post-swift-cutover-issues.md §D/§6): "Access" sub-panel — direct user-id tiers,
// opened from the main /config panel's 👤 button. Mirrors ConfigPanelTests.swift fixture
// conventions (separate file: top-level `private` helpers are file-scoped, not shared).

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-cfgpanel-access-\(UUID().uuidString)", isDirectory: true)
}

private func seedGlobal(_ store: ConfigStore) async throws {
    let config = AppConfig(
        discord: DiscordSecrets(token: "bot-token-abc", clientId: "123456789"),
        auth: GlobalAuth(
            adminRoleIds: ["role-admin-g"],
            executeRoleIds: ["role-exec-g"],
            readOnlyRoleIds: ["role-read-g"],
            dmPolicy: "deny"
        ),
        defaults: DefaultsSection(mode: "claude", claudeModel: "opus", permissionMode: "default"),
        locale: "ko"
    )
    try await store.save(config)
}

private func makePanel(store: ConfigStore) async throws -> ConfigPanel {
    let global = try await store.load()
    let server = await store.loadServerConfig(guildId: "g1")
    let d = configPanelDefaults(global: global, server: server)
    return ConfigPanel(options: ConfigPanelOptions(
        guildId: "g1",
        ownerId: "admin-user",
        configStore: store,
        defaults: d,
        backends: Backend.allCases.map(\.rawValue),
        isKnownBackend: { Backend(rawValue: $0) != nil },
        permModes: [.init(value: "default", label: "default")]
    ))
}

private func accessUserSelects(_ sub: ConfigPanelSubView) -> [(id: String, defaultUserIds: [String])] {
    sub.rows.flatMap(\.components).compactMap { c in
        if case .userSelect(let id, _, let defaultUserIds, _, _) = c { return (id, defaultUserIds) }
        return nil
    }
}

@Suite("ConfigPanel Access sub-panel (WO-4)")
struct ConfigPanelAccessTests {
    @Test func isConfigPanelIdRecognizesAccessIds() {
        #expect(isConfigPanelId(ConfigPanelIds.accessOpen))
        #expect(isConfigPanelId(ConfigPanelIds.accessAdmin))
        #expect(isConfigPanelId(ConfigPanelIds.accessExecute))
        #expect(isConfigPanelId(ConfigPanelIds.accessReadOnly))
        #expect(isConfigPanelId(ConfigPanelIds.accessSave))
    }

    /// 요구사항 1: 메인 패널 렌더링에 Access 버튼이 존재하는지, 그리고 기존 role/notif/render
    /// 행 개수·버튼은 그대로인지(엄수사항 — 옆에 나란히 추가만).
    @Test func mainPanelRenderHasAccessButtonBesideExistingOnes() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        let view = panel.render()

        #expect(view.roleRows.count == 4) // 행 개수 불변 (locale은 defaultRows로 복귀, dmPolicy 없음)
        let buttonRow = view.roleRows[3].components
        let buttonIds = buttonRow.compactMap { c -> String? in
            if case .button(let id, _, _) = c { return id }
            return nil
        }
        #expect(buttonIds == [
            ConfigPanelIds.save,
            ConfigPanelIds.notifOpen,
            ConfigPanelIds.renderOpen,
            ConfigPanelIds.accessOpen,
        ])
    }

    @Test func accessOpenReturnsSubPanelWithThreeUserSelectsAndSaveButton() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessOpen))
        guard case .accessPanel(let sub) = r else {
            Issue.record("expected accessPanel, got \(r)")
            return
        }
        let selects = accessUserSelects(sub)
        #expect(selects.map(\.id) == [
            ConfigPanelIds.accessAdmin,
            ConfigPanelIds.accessExecute,
            ConfigPanelIds.accessReadOnly,
        ])
        // Effective (global) defaults are empty — no adminUserIds seeded.
        #expect(selects.allSatisfy { $0.defaultUserIds.isEmpty })
        let hasSave = sub.rows.flatMap(\.components).contains {
            if case .button(let id, _, _) = $0 { return id == ConfigPanelIds.accessSave }
            return false
        }
        #expect(hasSave)
    }

    /// 요구사항 2: userSelect로 고른 값이 pending 상태에 반영되는지 — Save 전엔 파일에 안 쓰임,
    /// 서브패널을 다시 열면 방금 고른 값이 반영돼 보임.
    @Test func userSelectPicksArePendingUntilSave() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessAdmin, values: ["u-admin-1"]))
        #expect(r == .pending)
        #expect(await store.loadServerConfig(guildId: "g1") == nil) // not written yet

        let reopened = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessOpen))
        guard case .accessPanel(let sub) = reopened else {
            Issue.record("expected accessPanel, got \(reopened)")
            return
        }
        let admin = accessUserSelects(sub).first { $0.id == ConfigPanelIds.accessAdmin }
        #expect(admin?.defaultUserIds == ["u-admin-1"])
    }

    @Test func accessSelectMissingValuesIsIgnored() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)
        let r = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessAdmin))
        #expect(r == .ignored)
    }

    /// 요구사항 3: Save를 누르면 실제 config(servers/<guildId>.json)에 반영되는지. 옵션1(역할 Save
    /// 재사용) — 저장 결과는 기존 `.saved` 케이스, 세션 종료 의미까지 role Save와 동일.
    @Test func accessSaveWritesServerAuthUserIds() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        let panel = try await makePanel(store: store)

        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessAdmin, values: ["u-admin-1", "u-admin-2"]))
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessExecute, values: ["u-exec-1"]))

        let saved = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessSave))
        guard case .saved(let summary) = saved else {
            Issue.record("expected saved, got \(saved)")
            return
        }
        #expect(summary.contains("<@u-admin-1>"))
        #expect(summary.contains("유저 권한을 저장"))

        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.auth?.adminUserIds == ["u-admin-1", "u-admin-2"])
        #expect(server?.auth?.executeUserIds == ["u-exec-1"])
        // Untouched tier falls through to effective default (global has none).
        #expect(server?.auth?.readOnlyUserIds == [])
    }

    /// Access Save만 손대고, 기존 role-id 필드는 보존해야 한다(같은 auth 객체를 공유하므로).
    @Test func accessSavePreservesExistingRoleIds() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(adminRoleIds: ["srv-role-admin"])
        ))
        let panel = try await makePanel(store: store)
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessAdmin, values: ["u-admin-1"]))
        _ = await panel.handle(ConfigPanelInput(id: ConfigPanelIds.accessSave))

        let server = await store.loadServerConfig(guildId: "g1")
        #expect(server?.auth?.adminRoleIds == ["srv-role-admin"]) // untouched
        #expect(server?.auth?.adminUserIds == ["u-admin-1"])
    }

    /// 요구사항 4: 관리자가 아닌 사람은 이 패널 자체를 못 연다 — `/config` 오픈과
    /// handleConfigComponent(Access 버튼 포함 모든 config.* 컴포넌트)를 지키는 게이트는
    /// 동일한 `Authorizer.authorize(action: .admin)` 호출이다(DabMain.swift:950-960 근처,
    /// dab 실행 타깃엔 테스트 타깃이 없어 라이브러리 레벨에서 동일 게이트를 검증).
    @Test func adminGateDeniesNonAdminAndAllowsUserIdAdmin() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await seedGlobal(store)
        try await store.saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(adminUserIds: ["u-admin-1"])
        ))
        let authz = Authorizer(config: store)

        let denied = await authz.authorize(AuthInput(
            userId: "bystander", roleIds: [], action: .admin, guildId: "g1", channelId: "c1"
        ))
        #expect(denied.allowed == false)

        // WO-3 기능(유저ID 기반 admin)으로 등록된 사람은 역할이 전혀 없어도 패널을 열 수 있다.
        let allowed = await authz.authorize(AuthInput(
            userId: "u-admin-1", roleIds: [], action: .admin, guildId: "g1", channelId: "c1"
        ))
        #expect(allowed.allowed == true)
        #expect(allowed.tier == .admin)
    }
}
