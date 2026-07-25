import Foundation

// `/config` settings panel (W16-b minimal).
// Pure SM + ConfigStore persistence — no DiscordBM. dab maps ConfigPanelView → components.
//
// Mirrors TS `src/discord/configPanel.ts` at reduced surface:
//   - Role tiers (3 role-selects) batch into pending → Save writes servers/<guildId>.json auth
//   - defaults.mode / defaults.permissionMode AUTO-SAVE to server on each select change
//   - auth.dmPolicy AUTO-SAVE to GLOBAL config.json (server has no dmPolicy field)
//   - Embed shows effective global+server auth / defaults / limits
//
// ponytail: model/effort/locale selects · notifications sub-panel · image/chromium sub-panel
// → reopen scope when needed (TS full A4D parity).

// MARK: - Ids

public let CONFIG_PANEL_PREFIX = "config."

public enum ConfigPanelIds {
    public static let roleAdmin = "config.role.admin"
    public static let roleExecute = "config.role.execute"
    public static let roleReadOnly = "config.role.readOnly"
    public static let backend = "config.default.backend"
    public static let permMode = "config.default.permMode"
    public static let dmPolicy = "config.dmPolicy"
    public static let save = "config.save"
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
    public var backend: String
    public var permMode: String
    public var dmPolicy: String
    /// Display-only (resolved global→server limits).
    public var limits: LimitsSection
    /// Display-only locale (server override else global).
    public var locale: String
    /// Display-only model (resolved, no edit in minimal panel).
    public var model: String

    public init(
        adminRoleIds: [String],
        executeRoleIds: [String],
        readOnlyRoleIds: [String],
        backend: String,
        permMode: String,
        dmPolicy: String,
        limits: LimitsSection = LimitsSection(),
        locale: String = "ko",
        model: String = ""
    ) {
        self.adminRoleIds = adminRoleIds
        self.executeRoleIds = executeRoleIds
        self.readOnlyRoleIds = readOnlyRoleIds
        self.backend = backend
        self.permMode = permMode
        self.dmPolicy = dmPolicy
        self.limits = limits
        self.locale = locale
        self.model = model
    }
}

public struct ConfigPanelOptions: Sendable {
    public var guildId: String
    public var ownerId: String
    public var configStore: ConfigStore
    public var defaults: ConfigPanelDefaults
    public var backends: [String]
    public var isKnownBackend: @Sendable (String) -> Bool
    public var permModes: [ModelChoice]

    public init(
        guildId: String,
        ownerId: String,
        configStore: ConfigStore,
        defaults: ConfigPanelDefaults,
        backends: [String],
        isKnownBackend: @escaping @Sendable (String) -> Bool,
        permModes: [ModelChoice]
    ) {
        self.guildId = guildId
        self.ownerId = ownerId
        self.configStore = configStore
        self.defaults = defaults
        self.backends = backends
        self.isKnownBackend = isKnownBackend
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

public enum ConfigPanelResult: Sendable, Equatable {
    case pending
    case saved(summary: String)
    case autosaved(notice: String)
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
    /// Primary message: role tiers + Save (≤4 rows).
    public var roleRows: [ConfigPanelRow]
    /// Follow-up: defaults + dmPolicy selects (≤5 rows).
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
    private let permModes: [ModelChoice]
    private var pending = PendingRoles()

    public init(options: ConfigPanelOptions) {
        self.ownerId = options.ownerId
        self.guildId = options.guildId
        self.store = options.configStore
        self.defaults = options.defaults
        self.backends = options.backends
        self.isKnownBackend = options.isKnownBackend
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
        switch input.id {
        case ConfigPanelIds.backend:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosaveBackend(value)
        case ConfigPanelIds.permMode:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosavePermMode(value)
        case ConfigPanelIds.dmPolicy:
            guard let value = input.value, !value.isEmpty else { return .pending }
            return await autosaveDmPolicy(value)
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
            placeholder: "Admin roles",
            defaultRoleIds: pending.adminRoleIds ?? d.adminRoleIds
        )
        let exec = roleSelect(
            ConfigPanelIds.roleExecute,
            placeholder: "Execute roles",
            defaultRoleIds: pending.executeRoleIds ?? d.executeRoleIds
        )
        let read = roleSelect(
            ConfigPanelIds.roleReadOnly,
            placeholder: "Read-only roles",
            defaultRoleIds: pending.readOnlyRoleIds ?? d.readOnlyRoleIds
        )
        let save = ConfigPanelComponent.button(
            customId: ConfigPanelIds.save,
            label: "Save roles",
            style: .success
        )

        let backendSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.backend,
            placeholder: "Default backend",
            options: backends.map {
                WizardSelectOption(label: $0, value: $0, isDefault: $0 == d.backend)
            }
        )
        let permSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.permMode,
            placeholder: "Default permission mode",
            options: permModes.map {
                WizardSelectOption(label: $0.label, value: $0.value, isDefault: $0.value == d.permMode)
            }
        )
        let dmSelect = ConfigPanelComponent.select(
            customId: ConfigPanelIds.dmPolicy,
            placeholder: "DM policy (global)",
            options: ["deny", "allow"].map {
                WizardSelectOption(label: $0, value: $0, isDefault: $0 == d.dmPolicy)
            }
        )

        return ConfigPanelView(
            title: "Bot config",
            description: buildDescription(),
            roleRows: [
                ConfigPanelRow(components: [admin]),
                ConfigPanelRow(components: [exec]),
                ConfigPanelRow(components: [read]),
                ConfigPanelRow(components: [save]),
            ],
            defaultRows: [
                ConfigPanelRow(components: [backendSelect]),
                ConfigPanelRow(components: [permSelect]),
                ConfigPanelRow(components: [dmSelect]),
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
        backend=\(d.backend) perm=\(d.permMode) dmPolicy=\(d.dmPolicy)
        """
        return .saved(summary: summary)
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

    private func autosavePermMode(_ permMode: String) async -> ConfigPanelResult {
        do {
            try await patchServerDefaults { $0.permissionMode = permMode }
            defaults.permMode = permMode
        } catch {
            return .autosaved(notice: "permMode 저장 실패: \(error)")
        }
        return .autosaved(notice: "기본 권한 모드 → `\(permMode)`")
    }

    private func autosaveDmPolicy(_ policy: String) async -> ConfigPanelResult {
        guard policy == "allow" || policy == "deny" else {
            return .ignored
        }
        do {
            var config = try await store.load()
            config.auth.dmPolicy = policy
            try await store.save(config)
            defaults.dmPolicy = policy
        } catch {
            return .autosaved(notice: "dmPolicy 저장 실패: \(error)")
        }
        return .autosaved(notice: "DM policy (global) → `\(policy)`")
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

    private func buildDescription() -> String {
        let d = defaults
        let lim = d.limits
        return """
        **Effective (global → server)**
        roles admin: \(formatRoleList(d.adminRoleIds))
        roles execute: \(formatRoleList(d.executeRoleIds))
        roles read-only: \(formatRoleList(d.readOnlyRoleIds))
        dmPolicy: `\(d.dmPolicy)` (global)
        defaults: mode=`\(d.backend)` model=`\(d.model)` perm=`\(d.permMode)` locale=`\(d.locale)`
        limits: maxSessions/user=\(lim.maxSessionsPerUser) permTimeout=\(lim.permissionTimeoutSec)s codexTimeoutMs=\(lim.codexTimeoutMs)

        Role picks batch until **Save roles**. Backend / perm / DM policy auto-save on change.
        """
    }
}

// MARK: - Helpers

private func formatRoleList(_ roleIds: [String]) -> String {
    if roleIds.isEmpty { return "—" }
    return roleIds.map { "<@&\($0)>" }.joined(separator: ", ")
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
    let backend = server?.defaults?.mode.map(normalizeModeId) ?? normalizeModeId(global.defaults.mode)
    return ConfigPanelDefaults(
        adminRoleIds: effective.adminRoleIds,
        executeRoleIds: effective.executeRoleIds,
        readOnlyRoleIds: effective.readOnlyRoleIds,
        backend: backend == "grok-build" ? "grok" : backend, // file id → runtime Backend raw when needed
        permMode: perm,
        dmPolicy: global.auth.dmPolicy,
        limits: resolved.limits,
        locale: server?.locale ?? global.locale,
        model: resolved.claudeModel
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
