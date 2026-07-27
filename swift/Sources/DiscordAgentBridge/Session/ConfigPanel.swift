import Foundation

// `/config` settings panel (W16-b residual polish).
// Pure SM + ConfigStore persistence — no DiscordBM. dab maps ConfigPanelView → components.
//
// Mirrors TS `src/discord/configPanel.ts`:
//   - Role tiers (3 role-selects) batch into pending → Save writes servers/<guildId>.json auth
//   - defaults.mode / model / effort / permissionMode / locale AUTO-SAVE to server on each select change
//   - locale AUTO-SAVE to GLOBAL config.json (process-wide UI language; ko/en)
//   - Notifications sub-panel: enable toggle + status channel select → server.notifications
//   - Image/chromium sub-panel (S3): render.enabled toggle + Chromium install
//   - Embed shows effective global+server auth / defaults / limits
//
// Layout: roleRows = 3 role selects + Save/Notif/Render/Access row (4 rows, TS-identical
// budget). defaultRows = backend/model/effort/permMode/locale (5 rows, TS-identical order).

// MARK: - Ids

public let CONFIG_PANEL_PREFIX = "config."

/// Closed set offered by the locale select (TS i18n ships ko/en only).
public let CONFIG_LOCALES: [String] = ["ko", "en"]

public enum ConfigPanelIds {
    public static let roleAdmin = "config.role.admin"
    public static let roleExecute = "config.role.execute"
    public static let roleReadOnly = "config.role.readOnly"
    public static let backend = "config.default.backend"
    public static let model = "config.default.model"
    public static let effort = "config.default.effort"
    public static let permMode = "config.default.permMode"
    public static let locale = "config.default.locale"
    public static let save = "config.save"
    public static let notifOpen = "config.notif.open"
    public static let notifToggle = "config.notif.toggle"
    public static let notifChannel = "config.notif.channel"
    public static let renderOpen = "config.render.open"
    public static let renderToggle = "config.render.toggle"
    public static let renderInstall = "config.render.install"
    public static let renderDecline = "config.render.decline"
    public static let accessOpen = "config.access.open"
    public static let accessAdmin = "config.access.admin"
    public static let accessExecute = "config.access.execute"
    public static let accessReadOnly = "config.access.readOnly"
    public static let accessSave = "config.access.save"
}

/// True when a component id belongs to a `/config` panel (router routing predicate).
public func isConfigPanelId(_ customId: String) -> Bool {
    customId.hasPrefix(CONFIG_PANEL_PREFIX)
}

// MARK: - Types

public struct ConfigPanelDefaults: Sendable, Equatable {
    public var adminRoleIds: [String]
    public var executeRoleIds: [String]
    public var readOnlyRoleIds: [String]
    /// Direct user-id tiers (D절 신규 기능) — OR'd with the role tiers above by `Authorizer`.
    public var adminUserIds: [String]
    public var executeUserIds: [String]
    public var readOnlyUserIds: [String]
    public var backend: String
    public var permMode: String
    /// Display-only (resolved global→server limits).
    public var limits: LimitsSection
    /// UI language: panel edits GLOBAL config.locale (server.locale still wins when set).
    public var locale: String
    /// Default model (resolved; panel edits server claudeModel / codexModel by backend).
    public var model: String
    /// Default reasoning effort (resolved; panel edits claudeEffort / codexEffort by backend).
    public var effort: String

    public init(
        adminRoleIds: [String],
        executeRoleIds: [String],
        readOnlyRoleIds: [String],
        adminUserIds: [String] = [],
        executeUserIds: [String] = [],
        readOnlyUserIds: [String] = [],
        backend: String,
        permMode: String,
        limits: LimitsSection = LimitsSection(),
        locale: String = "ko",
        model: String = "",
        effort: String = ""
    ) {
        self.adminRoleIds = adminRoleIds
        self.executeRoleIds = executeRoleIds
        self.readOnlyRoleIds = readOnlyRoleIds
        self.adminUserIds = adminUserIds
        self.executeUserIds = executeUserIds
        self.readOnlyUserIds = readOnlyUserIds
        self.backend = backend
        self.permMode = permMode
        self.limits = limits
        self.locale = locale
        self.model = model
        self.effort = effort
    }
}

public struct ConfigPanelOptions: Sendable {
    public var guildId: String
    public var ownerId: String
    public var configStore: ConfigStore
    public var defaults: ConfigPanelDefaults
    public var backends: [String]
    public var isKnownBackend: @Sendable (String) -> Bool
    public var models: [ModelChoice]
    public var efforts: [ModelChoice]
    public var permModes: [ModelChoice]

    public init(
        guildId: String,
        ownerId: String,
        configStore: ConfigStore,
        defaults: ConfigPanelDefaults,
        backends: [String],
        isKnownBackend: @escaping @Sendable (String) -> Bool,
        models: [ModelChoice] = [],
        efforts: [ModelChoice] = [],
        permModes: [ModelChoice]
    ) {
        self.guildId = guildId
        self.ownerId = ownerId
        self.configStore = configStore
        self.defaults = defaults
        self.backends = backends
        self.isKnownBackend = isKnownBackend
        self.models = models
        self.efforts = efforts
        self.permModes = permModes
    }
}

public struct ConfigPanelInput: Sendable, Equatable {
    public var id: String
    public var value: String?
    public var values: [String]?

    public init(id: String, value: String? = nil, values: [String]? = nil) {
        self.id = id
        self.value = value
        self.values = values
    }
}

/// Ephemeral sub-panel payload (notifications).
public struct ConfigPanelSubView: Sendable, Equatable {
    public var title: String
    public var description: String
    public var rows: [ConfigPanelRow]

    public init(title: String, description: String, rows: [ConfigPanelRow]) {
        self.title = title
        self.description = description
        self.rows = rows
    }
}

public enum ConfigPanelResult: Sendable, Equatable {
    case pending
    case saved(summary: String)
    case autosaved(notice: String)
    /// 🔔 opened notifications sub-panel (fresh ephemeral message).
    case notifPanel(ConfigPanelSubView)
    /// Toggle/channel change persisted; re-render sub-panel in place.
    case notifUpdated(ConfigPanelSubView)
    /// 🖼 opened image-render sub-panel (fresh ephemeral message).
    case renderPanel(ConfigPanelSubView)
    /// Render on/off or decline persisted; re-render sub-panel in place.
    case renderUpdated(ConfigPanelSubView)
    /// Install Chromium — router runs ChromiumProvisioner.
    case renderInstall
    /// 👤 opened user-access sub-panel (fresh ephemeral message).
    case accessPanel(ConfigPanelSubView)
    case ignored
}

// MARK: - Render specs (Discord-agnostic)

public enum ConfigPanelComponent: Sendable, Equatable {
    case roleSelect(
        customId: String,
        placeholder: String,
        defaultRoleIds: [String],
        minValues: Int,
        maxValues: Int
    )
    case userSelect(
        customId: String,
        placeholder: String,
        defaultUserIds: [String],
        minValues: Int,
        maxValues: Int
    )
    case channelSelect(
        customId: String,
        placeholder: String,
        defaultChannelIds: [String],
        minValues: Int,
        maxValues: Int
    )
    case select(customId: String, placeholder: String, options: [WizardSelectOption])
    case button(customId: String, label: String, style: WizardButtonStyle)
}

public struct ConfigPanelRow: Sendable, Equatable {
    public var components: [ConfigPanelComponent]
    public init(components: [ConfigPanelComponent]) { self.components = components }
}

public struct ConfigPanelView: Sendable, Equatable {
    public var title: String
    public var description: String
    /// Primary message: role tiers + Save/Notif/Render/Access (≤5 rows).
    public var roleRows: [ConfigPanelRow]
    /// Follow-up: backend / model / effort / permMode / locale (≤5 rows).
    public var defaultRows: [ConfigPanelRow]

    public init(
        title: String,
        description: String,
        roleRows: [ConfigPanelRow],
        defaultRows: [ConfigPanelRow]
    ) {
        self.title = title
        self.description = description
        self.roleRows = roleRows
        self.defaultRows = defaultRows
    }
}

// MARK: - Pending roles

private struct PendingRoles {
    var adminRoleIds: [String]?
    var executeRoleIds: [String]?
    var readOnlyRoleIds: [String]?
}

/// Mirrors `PendingRoles` for the Access sub-panel's user-id tiers (D절 신규 기능).
private struct PendingUsers {
    var adminUserIds: [String]?
    var executeUserIds: [String]?
    var readOnlyUserIds: [String]?
}

private enum RoleTierKey {
    case admin, execute, readOnly
}

// MARK: - Panel

/// Mutable panel state for one open `/config` session. Held only inside `ConfigPanelRegistry`.
public final class ConfigPanel: @unchecked Sendable {
    public let ownerId: String
    public let guildId: String

    private let store: ConfigStore
    private var defaults: ConfigPanelDefaults
    private let backends: [String]
    private let isKnownBackend: @Sendable (String) -> Bool
    private let models: [ModelChoice]
    private let efforts: [ModelChoice]
    private let permModes: [ModelChoice]
    private var pending = PendingRoles()
    private var pendingUsers = PendingUsers()

    public init(options: ConfigPanelOptions) {
        self.ownerId = options.ownerId
        self.guildId = options.guildId
        self.store = options.configStore
        self.defaults = options.defaults
        self.backends = options.backends
        self.isKnownBackend = options.isKnownBackend
        self.models = options.models
        self.efforts = options.efforts
        self.permModes = options.permModes
    }

    // MARK: Handle

    public func handle(_ input: ConfigPanelInput) async -> ConfigPanelResult {
        if let tier = Self.tier(for: input.id) {
            // Absent values = malformed; ignore (never blank a tier from a glitch).
            guard let values = input.values else { return .ignored }
            setTier(tier, roleIds: values)
            return .pending
        }
        if let tier = Self.accessTier(for: input.id) {
            guard let values = input.values else { return .ignored }
            setUserTier(tier, userIds: values)
            return .pending
        }
        switch input.id {
        case ConfigPanelIds.backend:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosaveBackend(value)
        case ConfigPanelIds.model:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosaveModel(value)
        case ConfigPanelIds.effort:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosaveEffort(value)
        case ConfigPanelIds.permMode:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosavePermMode(value)
        case ConfigPanelIds.locale:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosaveLocale(value)
        case ConfigPanelIds.notifOpen:
            return await .notifPanel(renderNotifications())
        case ConfigPanelIds.notifToggle:
            return await toggleNotifications()
        case ConfigPanelIds.notifChannel:
            // Empty pick clears the override (falls back to /setup status channel).
            let channelId = input.values?.first.flatMap { $0.isEmpty ? nil : $0 }
            return await setNotificationChannel(channelId)
        case ConfigPanelIds.renderOpen:
            return await .renderPanel(renderRenderPanel())
        case ConfigPanelIds.renderToggle:
            return await toggleRender()
        case ConfigPanelIds.renderInstall:
            return .renderInstall
        case ConfigPanelIds.renderDecline:
            return await declineChromium()
        case ConfigPanelIds.accessOpen:
            return .accessPanel(renderAccess())
        case ConfigPanelIds.accessSave:
            return await saveAccess()
        case ConfigPanelIds.save:
            return await saveRoles()
        default:
            return .ignored
        }
    }

    // MARK: Render

    public func render() -> ConfigPanelView {
        let d = defaults
        let admin = roleSelect(
            ConfigPanelIds.roleAdmin,
            placeholder: I18n.t("config.role.admin.placeholder"),
            defaultRoleIds: pending.adminRoleIds ?? d.adminRoleIds
        )
        let exec = roleSelect(
            ConfigPanelIds.roleExecute,
            placeholder: I18n.t("config.role.execute.placeholder"),
            defaultRoleIds: pending.executeRoleIds ?? d.executeRoleIds
        )
        let read = roleSelect(
            ConfigPanelIds.roleReadOnly,
            placeholder: I18n.t("config.role.readOnly.placeholder"),
            defaultRoleIds: pending.readOnlyRoleIds ?? d.readOnlyRoleIds
        )
        let save = ConfigPanelComponent.button(
            customId: ConfigPanelIds.save,
            label: I18n.t("config.save"),
            style: .success
        )
        let notif = ConfigPanelComponent.button(
            customId: ConfigPanelIds.notifOpen,
            label: I18n.t("config.notif.button"),
            style: .secondary
        )
        let renderBtn = ConfigPanelComponent.button(
            customId: ConfigPanelIds.renderOpen,
            label: I18n.t("config.render.button"),
            style: .secondary
        )
        let accessBtn = ConfigPanelComponent.button(
            customId: ConfigPanelIds.accessOpen,
            label: "👤 Access",
            style: .secondary
        )

        let backendSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.backend,
            placeholder: I18n.t("config.default.backend.placeholder"),
            options: backends.map {
                WizardSelectOption(label: $0, value: $0, isDefault: $0 == d.backend)
            }
        )
        let modelOptions = selectOptions(from: models, selected: d.model, fallbackLabel: "model")
        let modelSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.model,
            placeholder: I18n.t("config.default.model.placeholder"),
            options: modelOptions
        )
        let effortOptions = selectOptions(from: efforts, selected: d.effort, fallbackLabel: "effort")
        let effortSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.effort,
            placeholder: I18n.t("config.default.effort.placeholder"),
            options: effortOptions
        )
        let permSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.permMode,
            placeholder: I18n.t("config.default.permMode.placeholder"),
            options: permModes.map {
                WizardSelectOption(label: $0.label, value: $0.value, isDefault: $0.value == d.permMode)
            }
        )
        let localeSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.locale,
            placeholder: I18n.t("config.default.locale.placeholder"),
            options: CONFIG_LOCALES.map {
                WizardSelectOption(label: localeLabel($0), value: $0, isDefault: $0 == d.locale)
            }
        )

        return ConfigPanelView(
            title: I18n.t("config.title"),
            description: buildDescription(),
            roleRows: [
                ConfigPanelRow(components: [admin]),
                ConfigPanelRow(components: [exec]),
                ConfigPanelRow(components: [read]),
                ConfigPanelRow(components: [save, notif, renderBtn, accessBtn]),
            ],
            defaultRows: [
                ConfigPanelRow(components: [backendSelect]),
                ConfigPanelRow(components: [modelSelect]),
                ConfigPanelRow(components: [effortSelect]),
                ConfigPanelRow(components: [permSelect]),
                ConfigPanelRow(components: [localeSelect]),
            ]
        )
    }

    // MARK: - Private

    private static func tier(for id: String) -> RoleTierKey? {
        switch id {
        case ConfigPanelIds.roleAdmin: return .admin
        case ConfigPanelIds.roleExecute: return .execute
        case ConfigPanelIds.roleReadOnly: return .readOnly
        default: return nil
        }
    }

    private static func accessTier(for id: String) -> RoleTierKey? {
        switch id {
        case ConfigPanelIds.accessAdmin: return .admin
        case ConfigPanelIds.accessExecute: return .execute
        case ConfigPanelIds.accessReadOnly: return .readOnly
        default: return nil
        }
    }

    private func setTier(_ tier: RoleTierKey, roleIds: [String]) {
        // De-dupe while preserving order.
        var seen = Set<String>()
        let unique = roleIds.filter { seen.insert($0).inserted }
        switch tier {
        case .admin: pending.adminRoleIds = unique
        case .execute: pending.executeRoleIds = unique
        case .readOnly: pending.readOnlyRoleIds = unique
        }
    }

    private func setUserTier(_ tier: RoleTierKey, userIds: [String]) {
        var seen = Set<String>()
        let unique = userIds.filter { seen.insert($0).inserted }
        switch tier {
        case .admin: pendingUsers.adminUserIds = unique
        case .execute: pendingUsers.executeUserIds = unique
        case .readOnly: pendingUsers.readOnlyUserIds = unique
        }
    }

    private func saveRoles() async -> ConfigPanelResult {
        let existing = await store.loadServerConfig(guildId: guildId)
        let d = defaults
        let adminRoleIds = pending.adminRoleIds ?? existing?.auth?.adminRoleIds ?? d.adminRoleIds
        let executeRoleIds = pending.executeRoleIds ?? existing?.auth?.executeRoleIds ?? d.executeRoleIds
        let readOnlyRoleIds = pending.readOnlyRoleIds ?? existing?.auth?.readOnlyRoleIds ?? d.readOnlyRoleIds

        var auth = existing?.auth ?? ServerAuthPartial()
        auth.adminRoleIds = adminRoleIds
        auth.executeRoleIds = executeRoleIds
        auth.readOnlyRoleIds = readOnlyRoleIds

        var next = existing ?? ServerConfig(guildId: guildId)
        next.version = existing?.version ?? CONFIG_VERSION
        next.guildId = guildId
        next.auth = auth

        do {
            try await store.saveServerConfig(next)
        } catch {
            return .autosaved(notice: "역할 저장 실패: \(error)")
        }

        // Refresh in-memory defaults so re-open of same panel instance shows new roles.
        defaults.adminRoleIds = adminRoleIds
        defaults.executeRoleIds = executeRoleIds
        defaults.readOnlyRoleIds = readOnlyRoleIds
        pending = PendingRoles()

        let summary = """
        역할을 저장했습니다.
        admin: \(formatRoleList(adminRoleIds))
        execute: \(formatRoleList(executeRoleIds))
        read-only: \(formatRoleList(readOnlyRoleIds))
        backend=\(d.backend) model=\(d.model) effort=\(d.effort) perm=\(d.permMode)
        """
        return .saved(summary: summary)
    }

    // MARK: Access (user-id tiers, D절 신규 기능)

    /// Commits the pending user-id tiers. Mirrors `saveRoles()` exactly (same `.saved`
    /// result — Save always finalizes the whole `/config` session, panel included).
    private func saveAccess() async -> ConfigPanelResult {
        let existing = await store.loadServerConfig(guildId: guildId)
        let d = defaults
        let adminUserIds = pendingUsers.adminUserIds ?? existing?.auth?.adminUserIds ?? d.adminUserIds
        let executeUserIds = pendingUsers.executeUserIds ?? existing?.auth?.executeUserIds ?? d.executeUserIds
        let readOnlyUserIds = pendingUsers.readOnlyUserIds ?? existing?.auth?.readOnlyUserIds ?? d.readOnlyUserIds

        var auth = existing?.auth ?? ServerAuthPartial()
        auth.adminUserIds = adminUserIds
        auth.executeUserIds = executeUserIds
        auth.readOnlyUserIds = readOnlyUserIds

        var next = existing ?? ServerConfig(guildId: guildId)
        next.version = existing?.version ?? CONFIG_VERSION
        next.guildId = guildId
        next.auth = auth

        do {
            try await store.saveServerConfig(next)
        } catch {
            return .autosaved(notice: "유저 권한 저장 실패: \(error)")
        }

        defaults.adminUserIds = adminUserIds
        defaults.executeUserIds = executeUserIds
        defaults.readOnlyUserIds = readOnlyUserIds
        pendingUsers = PendingUsers()

        let summary = """
        유저 권한을 저장했습니다.
        admin: \(formatUserList(adminUserIds))
        execute: \(formatUserList(executeUserIds))
        read-only: \(formatUserList(readOnlyUserIds))
        """
        return .saved(summary: summary)
    }

    private func renderAccess() -> ConfigPanelSubView {
        let d = defaults
        let admin = userSelect(
            ConfigPanelIds.accessAdmin,
            placeholder: "Admin users",
            defaultUserIds: pendingUsers.adminUserIds ?? d.adminUserIds
        )
        let exec = userSelect(
            ConfigPanelIds.accessExecute,
            placeholder: "Execute users",
            defaultUserIds: pendingUsers.executeUserIds ?? d.executeUserIds
        )
        let read = userSelect(
            ConfigPanelIds.accessReadOnly,
            placeholder: "Read-only users",
            defaultUserIds: pendingUsers.readOnlyUserIds ?? d.readOnlyUserIds
        )
        let save = ConfigPanelComponent.button(
            customId: ConfigPanelIds.accessSave,
            label: "Save access",
            style: .success
        )
        return ConfigPanelSubView(
            title: "User access (admin/execute/read-only)",
            description: """
            Grant tiers directly by Discord user id, independent of roles.
            admin: \(formatUserList(pendingUsers.adminUserIds ?? d.adminUserIds))
            execute: \(formatUserList(pendingUsers.executeUserIds ?? d.executeUserIds))
            read-only: \(formatUserList(pendingUsers.readOnlyUserIds ?? d.readOnlyUserIds))
            Picks batch until **Save access**.
            """,
            rows: [
                ConfigPanelRow(components: [admin]),
                ConfigPanelRow(components: [exec]),
                ConfigPanelRow(components: [read]),
                ConfigPanelRow(components: [save]),
            ]
        )
    }

    private func autosaveBackend(_ backend: String) async -> ConfigPanelResult {
        if isKnownBackend(backend) {
            do {
                try await patchServerDefaults { $0.mode = backend }
                defaults.backend = backend
            } catch {
                return .autosaved(notice: "backend 저장 실패: \(error)")
            }
        }
        return .autosaved(notice: "기본 backend → `\(backend)`")
    }

    private func autosaveModel(_ model: String) async -> ConfigPanelResult {
        // TS writes claudeModel only; for codex we also write codexModel so the
        // resolver's per-backend field is correct without a second UI.
        let backend = await currentBackendId()
        do {
            try await patchServerDefaults { partial in
                if backend == "codex" {
                    partial.codexModel = model
                } else {
                    partial.claudeModel = model
                }
            }
            defaults.model = model
        } catch {
            return .autosaved(notice: "model 저장 실패: \(error)")
        }
        return .autosaved(notice: "기본 model → `\(model)`")
    }

    private func autosaveEffort(_ effort: String) async -> ConfigPanelResult {
        let backend = await currentBackendId()
        do {
            try await patchServerDefaults { partial in
                if backend == "codex" {
                    partial.codexEffort = effort
                } else {
                    partial.claudeEffort = effort
                }
            }
            defaults.effort = effort
        } catch {
            return .autosaved(notice: "effort 저장 실패: \(error)")
        }
        return .autosaved(notice: "기본 effort → `\(effort)`")
    }

    private func autosavePermMode(_ permMode: String) async -> ConfigPanelResult {
        do {
            try await patchServerDefaults { $0.permissionMode = permMode }
            defaults.permMode = permMode
        } catch {
            return .autosaved(notice: "permMode 저장 실패: \(error)")
        }
        return .autosaved(notice: "기본 권한 모드 → `\(permMode)`")
    }

    private func autosaveLocale(_ locale: String) async -> ConfigPanelResult {
        guard CONFIG_LOCALES.contains(locale) else {
            return .ignored
        }
        do {
            var config = try await store.load()
            config.locale = locale
            try await store.save(config)
            defaults.locale = locale
            // Process-wide UI language (TS app.ts setLocale on config change).
            I18n.applyFromConfigLocale(locale)
        } catch {
            return .autosaved(notice: "locale 저장 실패: \(error)")
        }
        return .autosaved(notice: I18n.t("config.autosaved.locale", ["locale": localeLabel(locale)]))
    }

    // MARK: Notifications

    private func toggleNotifications() async -> ConfigPanelResult {
        let current = await currentNotifications()
        do {
            try await patchNotifications { $0.enabled = !current.enabled }
        } catch {
            return .autosaved(notice: "알림 저장 실패: \(error)")
        }
        return await .notifUpdated(renderNotifications())
    }

    private func setNotificationChannel(_ channelId: String?) async -> ConfigPanelResult {
        do {
            try await patchNotifications { $0.channelId = channelId }
        } catch {
            return .autosaved(notice: "상태 채널 저장 실패: \(error)")
        }
        return await .notifUpdated(renderNotifications())
    }

    private func patchNotifications(_ mut: (inout NotificationsSection) -> Void) async throws {
        let existing = await store.loadServerConfig(guildId: guildId)
        var next = existing ?? ServerConfig(guildId: guildId)
        next.version = existing?.version ?? CONFIG_VERSION
        next.guildId = guildId
        var section = next.notifications ?? NotificationsSection()
        mut(&section)
        next.notifications = section
        try await store.saveServerConfig(next)
    }

    private func currentNotifications() async -> ResolvedNotifications {
        let server = await store.loadServerConfig(guildId: guildId)
        return resolveNotifications(server)
    }

    private func renderNotifications() async -> ConfigPanelSubView {
        let n = await currentNotifications()
        let state = n.enabled ? "on" : "off"
        let channelLine: String = {
            if let id = n.channelId, !id.isEmpty { return "<#\(id)>" }
            return "— (setup status channel when present)"
        }()
        let toggle = ConfigPanelComponent.button(
            customId: ConfigPanelIds.notifToggle,
            label: n.enabled ? "Disable notifications" : "Enable notifications",
            style: n.enabled ? .danger : .success
        )
        let channel = ConfigPanelComponent.channelSelect(
            customId: ConfigPanelIds.notifChannel,
            placeholder: "Status channel (empty → setup default)",
            defaultChannelIds: n.channelId.map { [$0] } ?? [],
            minValues: 0,
            maxValues: 1
        )
        return ConfigPanelSubView(
            title: I18n.t("config.notif.title"),
            description: """
            Forward session result/error summaries to a status channel.
            State: **\(state)** · channel: \(channelLine)
            Clear the channel pick to fall back to `/setup` status channel.
            """,
            rows: [
                ConfigPanelRow(components: [channel]),
                ConfigPanelRow(components: [toggle]),
            ]
        )
    }

    // MARK: Image render (S3 Chromium)

    private func renderEnabled() async -> Bool {
        ((try? await store.load())?.render?.enabled) ?? true
    }

    private func toggleRender() async -> ConfigPanelResult {
        let next = !(await renderEnabled())
        do {
            try await store.setRenderEnabled(next)
        } catch {
            return .autosaved(notice: "render 저장 실패: \(error)")
        }
        return await .renderUpdated(renderRenderPanel())
    }

    private func declineChromium() async -> ConfigPanelResult {
        do {
            try await store.setChromiumDecision("declined")
        } catch {
            return .autosaved(notice: "chromium 저장 실패: \(error)")
        }
        return await .renderUpdated(renderRenderPanel())
    }

    private func renderRenderPanel() async -> ConfigPanelSubView {
        let enabled = await renderEnabled()
        let decision = ((try? await store.load())?.chromium?.decision) ?? "undecided"
        let chrome = findChrome()
        let chromeLine = chrome.map { "system: `\(($0 as NSString).lastPathComponent)`" }
            ?? "no system Chrome (Install downloads Chrome for Testing)"
        let toggle = ConfigPanelComponent.button(
            customId: ConfigPanelIds.renderToggle,
            label: enabled ? "Disable table/mermaid PNG" : "Enable table/mermaid PNG",
            style: enabled ? .danger : .success
        )
        let install = ConfigPanelComponent.button(
            customId: ConfigPanelIds.renderInstall,
            label: I18n.t("config.render.install"),
            style: .primary
        )
        // No TS counterpart button exists here (TS's render sub-panel has only
        // toggle+install) — reuse the closest existing "decline/later" wording.
        let decline = ConfigPanelComponent.button(
            customId: ConfigPanelIds.renderDecline,
            label: I18n.t("render.setup.decline"),
            style: .secondary
        )
        return ConfigPanelSubView(
            title: "Image render (tables · mermaid)",
            description: """
            Render GFM tables and ```mermaid``` blocks as PNG attachments (headless Chrome).
            State: **\(enabled ? "on" : "off")** · chromium.decision: `\(decision)`
            Browser: \(chromeLine)
            Env: `DAB_RENDER=0` force off · `DAB_MERMAID_JS` · `DAB_CHROMIUM_CACHE`
            """,
            rows: [
                ConfigPanelRow(components: [toggle]),
                ConfigPanelRow(components: [install, decline]),
            ]
        )
    }

    private func currentBackendId() async -> String {
        let server = await store.loadServerConfig(guildId: guildId)
        if let mode = server?.defaults?.mode {
            let n = normalizeModeId(mode)
            return n == "grok-build" ? "grok" : n
        }
        return defaults.backend
    }

    private func patchServerDefaults(_ mut: (inout ServerDefaultsPartial) -> Void) async throws {
        let existing = await store.loadServerConfig(guildId: guildId)
        var next = existing ?? ServerConfig(guildId: guildId)
        next.version = existing?.version ?? CONFIG_VERSION
        next.guildId = guildId
        var defaultsPartial = next.defaults ?? ServerDefaultsPartial()
        mut(&defaultsPartial)
        next.defaults = defaultsPartial
        try await store.saveServerConfig(next)
    }

    private func roleSelect(
        _ customId: String,
        placeholder: String,
        defaultRoleIds: [String]
    ) -> ConfigPanelComponent {
        .roleSelect(
            customId: customId,
            placeholder: placeholder,
            defaultRoleIds: defaultRoleIds,
            minValues: 0,
            maxValues: 25
        )
    }

    private func userSelect(
        _ customId: String,
        placeholder: String,
        defaultUserIds: [String]
    ) -> ConfigPanelComponent {
        .userSelect(
            customId: customId,
            placeholder: placeholder,
            defaultUserIds: defaultUserIds,
            minValues: 0,
            maxValues: 25
        )
    }

    private func buildDescription() -> String {
        let d = defaults
        let lim = d.limits
        return """
        **Effective (global → server)**
        roles admin: \(formatRoleList(d.adminRoleIds))
        roles execute: \(formatRoleList(d.executeRoleIds))
        roles read-only: \(formatRoleList(d.readOnlyRoleIds))
        defaults: mode=`\(d.backend)` model=`\(d.model)` effort=`\(d.effort)` perm=`\(d.permMode)` locale=`\(d.locale)`
        limits: maxSessions/user=\(lim.maxSessionsPerUser) permTimeout=\(lim.permissionTimeoutSec)s codexTimeoutMs=\(lim.codexTimeoutMs)

        Role picks batch until **Save roles**. Backend / model / effort / perm / locale auto-save on change. 🔔 opens notifications.
        """
    }
}

// MARK: - Helpers

/// Human label for a locale code (TS `config.locale.ko` / `config.locale.en`).
public func localeLabel(_ locale: String) -> String {
    switch locale {
    case "ko": return I18n.t("config.locale.ko")
    case "en": return I18n.t("config.locale.en")
    default: return locale
    }
}

private func formatRoleList(_ roleIds: [String]) -> String {
    if roleIds.isEmpty { return "—" }
    return roleIds.map { "<@&\($0)>" }.joined(separator: ", ")
}

private func formatUserList(_ userIds: [String]) -> String {
    if userIds.isEmpty { return "—" }
    return userIds.map { "<@\($0)>" }.joined(separator: ", ")
}

/// Build string-select options (≤25). Ensures the current value is present and marked default.
private func selectOptions(
    from choices: [ModelChoice],
    selected: String,
    fallbackLabel: String
) -> [WizardSelectOption] {
    var list = Array(choices.prefix(25))
    if !selected.isEmpty, !list.contains(where: { $0.value == selected }) {
        list.insert(ModelChoice(value: selected, label: selected), at: 0)
        if list.count > 25 { list = Array(list.prefix(25)) }
    }
    if list.isEmpty {
        let v = selected.isEmpty ? fallbackLabel : selected
        list = [ModelChoice(value: v, label: v)]
    }
    return list.map {
        WizardSelectOption(label: $0.label, value: $0.value, isDefault: $0.value == selected)
    }
}

/// Build panel defaults from global + optional server (no binding layer for /config).
public func configPanelDefaults(
    global: AppConfig,
    server: ServerConfig?
) -> ConfigPanelDefaults {
    let effective = Authorizer.effectiveAuth(global: global.auth, server: server)
    let resolved = ConfigResolver.merge(global: global, server: server, binding: nil)
    // permMode for the defaults select: server override else global — NOT channel binding.
    let perm = server?.defaults?.permissionMode ?? global.defaults.permissionMode
    let backendRaw = server?.defaults?.mode.map(normalizeModeId) ?? normalizeModeId(global.defaults.mode)
    // File id → runtime Backend raw for the select.
    let backend = backendRaw == "grok-build" ? "grok" : backendRaw
    let model = backend == "codex"
        ? (resolved.codexModel.isEmpty ? resolved.claudeModel : resolved.codexModel)
        : resolved.claudeModel
    let effort: String = {
        if backend == "codex" {
            return resolved.codexEffort ?? ""
        }
        return resolved.claudeEffort ?? ""
    }()
    return ConfigPanelDefaults(
        adminRoleIds: effective.adminRoleIds,
        executeRoleIds: effective.executeRoleIds,
        readOnlyRoleIds: effective.readOnlyRoleIds,
        adminUserIds: effective.adminUserIds,
        executeUserIds: effective.executeUserIds,
        readOnlyUserIds: effective.readOnlyUserIds,
        backend: backend,
        permMode: perm,
        limits: resolved.limits,
        locale: server?.locale ?? global.locale,
        model: model,
        effort: effort
    )
}

// MARK: - Registry

/// channelKey (`guildId:channelId`) → open config panel (owner-gated).
public actor ConfigPanelRegistry {
    public static let shared = ConfigPanelRegistry()
    private var panels: [String: ConfigPanel] = [:]

    public init() {}

    public static func channelKey(guildId: String, channelId: String) -> String {
        "\(guildId):\(channelId)"
    }

    public func put(_ panel: ConfigPanel, guildId: String, channelId: String) {
        panels[Self.channelKey(guildId: guildId, channelId: channelId)] = panel
    }

    public func get(guildId: String, channelId: String) -> ConfigPanel? {
        panels[Self.channelKey(guildId: guildId, channelId: channelId)]
    }

    public func remove(guildId: String, channelId: String) {
        panels[Self.channelKey(guildId: guildId, channelId: channelId)] = nil
    }
}
