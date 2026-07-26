import Foundation

// Types + defaults for global config.json and per-server servers/<guildId>.json.
// Mirrors src/core/configSchema.ts (no Zod — Codable + explicit validate).
// Unknown JSON keys are ignored on decode (Codable default).

// MARK: - Version / normalize

public let CONFIG_VERSION = 2

/// Retired Grok backend ids → sole remaining file-facing id (`grok-build`).
/// Map to `Backend.grok` only at runtime boundaries (enum rawValue stays `"grok"`).
public func normalizeModeId(_ mode: String) -> String {
    if mode == "grok" || mode == "grok-agent" { return "grok-build" }
    return mode
}

// MARK: - Shared leaf types

public struct DiscordSecrets: Codable, Sendable, Equatable {
    public var token: String
    public var clientId: String
    public init(token: String, clientId: String) {
        self.token = token
        self.clientId = clientId
    }
}

/// Global auth block (and effective auth after server layer).
public struct GlobalAuth: Codable, Sendable, Equatable {
    public var adminRoleIds: [String]
    public var executeRoleIds: [String]
    public var readOnlyRoleIds: [String]
    /// User-id-based tier grants (OR'd with the matching *RoleIds set — either satisfies the tier).
    public var adminUserIds: [String]
    public var executeUserIds: [String]
    public var readOnlyUserIds: [String]
    public var dmPolicy: String

    public init(
        adminRoleIds: [String] = [],
        executeRoleIds: [String] = [],
        readOnlyRoleIds: [String] = [],
        adminUserIds: [String] = [],
        executeUserIds: [String] = [],
        readOnlyUserIds: [String] = [],
        dmPolicy: String = "deny"
    ) {
        self.adminRoleIds = adminRoleIds
        self.executeRoleIds = executeRoleIds
        self.readOnlyRoleIds = readOnlyRoleIds
        self.adminUserIds = adminUserIds
        self.executeUserIds = executeUserIds
        self.readOnlyUserIds = readOnlyUserIds
        self.dmPolicy = dmPolicy
    }

    /// Fail-secure default: empty allowlists + dmPolicy=deny.
    public static let empty = GlobalAuth()
}

public struct Profile: Codable, Sendable, Equatable {
    public var permissionMode: String
    public var allowedTools: [String]
    public var policyTier: String
    public init(permissionMode: String, allowedTools: [String], policyTier: String) {
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.policyTier = policyTier
    }
}

public struct DefaultsSection: Codable, Sendable, Equatable {
    public var mode: String
    public var claudeModel: String
    public var codexModel: String
    public var permissionMode: String
    public var permissionProfile: String?
    public var codexHome: String
    public var codexCliCommand: String
    public var codexCliVersion: String?
    public var claudeEffort: String?
    public var codexEffort: String?

    public init(
        mode: String = "claude",
        claudeModel: String = "opus",
        codexModel: String = "",
        permissionMode: String = "default",
        permissionProfile: String? = nil,
        codexHome: String = "~/.codex",
        codexCliCommand: String = "codex",
        codexCliVersion: String? = nil,
        claudeEffort: String? = nil,
        codexEffort: String? = nil
    ) {
        self.mode = mode
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.permissionMode = permissionMode
        self.permissionProfile = permissionProfile
        self.codexHome = codexHome
        self.codexCliCommand = codexCliCommand
        self.codexCliVersion = codexCliVersion
        self.claudeEffort = claudeEffort
        self.codexEffort = codexEffort
    }
}

public struct LimitsSection: Codable, Sendable, Equatable {
    public var maxSessionsPerUser: Int
    public var permissionTimeoutSec: Int
    public var codexTimeoutMs: Int

    public init(maxSessionsPerUser: Int = 0, permissionTimeoutSec: Int = 0, codexTimeoutMs: Int = 1_800_000) {
        self.maxSessionsPerUser = maxSessionsPerUser
        self.permissionTimeoutSec = permissionTimeoutSec
        self.codexTimeoutMs = codexTimeoutMs
    }
}

public struct PolicySection: Codable, Sendable, Equatable {
    public var unknownCommand: String
    public var allowExtraCommands: [String]
    public init(unknownCommand: String = "confirm", allowExtraCommands: [String] = []) {
        self.unknownCommand = unknownCommand
        self.allowExtraCommands = allowExtraCommands
    }
}

public struct UsageSection: Codable, Sendable, Equatable {
    public var userAgent: String
    public var cacheSec: Int
    public init(userAgent: String = "claude-code", cacheSec: Int = 15) {
        self.userAgent = userAgent
        self.cacheSec = cacheSec
    }
}

public struct AuditSection: Codable, Sendable, Equatable {
    public var channelId: String?
    public init(channelId: String? = nil) { self.channelId = channelId }
}

public struct RenderSection: Codable, Sendable, Equatable {
    public var enabled: Bool
    public init(enabled: Bool = true) { self.enabled = enabled }
}

public struct DocumentShareSection: Codable, Sendable, Equatable {
    public var maxBytes: Int
    public var bodyMode: String
    public var previewMaxChars: Int
    public var extensions: [String]
    public init(
        maxBytes: Int = 524_288,
        bodyMode: String = "preview",
        previewMaxChars: Int = 8000,
        extensions: [String] = [".md", ".markdown"]
    ) {
        self.maxBytes = maxBytes
        self.bodyMode = bodyMode
        self.previewMaxChars = previewMaxChars
        self.extensions = extensions
    }
}

public struct ChromiumSection: Codable, Sendable, Equatable {
    public var decision: String  // undecided | accepted | declined
    public init(decision: String = "undecided") { self.decision = decision }
}

public struct AutoUpdateSection: Codable, Sendable, Equatable {
    public var enabled: Bool
    public init(enabled: Bool = true) { self.enabled = enabled }
}

// MARK: - Global AppConfig

public struct AppConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var discord: DiscordSecrets
    public var auth: GlobalAuth
    public var defaults: DefaultsSection
    public var limits: LimitsSection
    public var policy: PolicySection
    public var autoAllowClaudeTools: [String]
    public var profiles: [String: Profile]
    public var usage: UsageSection
    public var audit: AuditSection
    public var render: RenderSection?
    public var documentShare: DocumentShareSection?
    public var chromium: ChromiumSection?
    public var locale: String
    public var logLevel: String
    public var favorites: [String]
    public var autoUpdate: AutoUpdateSection
    /// Optional render-capability overrides (toolThreads/fileDiff/usagePanel/streaming).
    /// Absent → backend mode defaults; merged under server + DAB_CAPS (see resolveCapabilities).
    public var capabilities: CapabilitiesPartial?

    public init(
        version: Int = CONFIG_VERSION,
        discord: DiscordSecrets,
        auth: GlobalAuth = GlobalAuth(),
        defaults: DefaultsSection = DefaultsSection(),
        limits: LimitsSection = LimitsSection(),
        policy: PolicySection = PolicySection(),
        autoAllowClaudeTools: [String] = ["Read", "Glob", "Grep"],
        profiles: [String: Profile] = [:],
        usage: UsageSection = UsageSection(),
        audit: AuditSection = AuditSection(),
        render: RenderSection? = RenderSection(),
        documentShare: DocumentShareSection? = DocumentShareSection(),
        chromium: ChromiumSection? = ChromiumSection(),
        locale: String = "ko",
        logLevel: String = "info",
        favorites: [String] = [],
        autoUpdate: AutoUpdateSection = AutoUpdateSection(),
        capabilities: CapabilitiesPartial? = nil
    ) {
        self.version = version
        self.discord = discord
        self.auth = auth
        self.defaults = defaults
        self.limits = limits
        self.policy = policy
        self.autoAllowClaudeTools = autoAllowClaudeTools
        self.profiles = profiles
        self.usage = usage
        self.audit = audit
        self.render = render
        self.documentShare = documentShare
        self.chromium = chromium
        self.locale = locale
        self.logLevel = logLevel
        self.favorites = favorites
        self.autoUpdate = autoUpdate
        self.capabilities = capabilities
    }
}

// MARK: - Preset (per-guild session preset; ConfigStore add/remove helpers)

/// Named backend/model/effort/permission combo for `/agent start` after a folder pick.
/// No cwd — folder is chosen fresh each start (folder-independent, reusable).
public struct Preset: Codable, Sendable, Equatable {
    public var name: String
    public var backend: String
    public var model: String?
    public var effort: String?
    public var permMode: String?
    /// Named profile, or null for raw mode. Optional on disk (TS: string | null | absent).
    public var profile: String?
    public init(
        name: String,
        backend: String,
        model: String? = nil,
        effort: String? = nil,
        permMode: String? = nil,
        profile: String? = nil
    ) {
        self.name = name
        self.backend = backend
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.profile = profile
    }
}

/// Draft after a normal (non-preset) wizard start — backs the "💾 프리셋으로 저장" modal.
/// Persisted via `SessionStore` (`swift-state.json` `presetDrafts` field) so it survives a restart.
public struct PresetDraft: Sendable, Equatable, Codable {
    public var backend: String
    public var model: String?
    public var effort: String?
    public var permMode: String?
    public var profile: String?
    public init(
        backend: String,
        model: String? = nil,
        effort: String? = nil,
        permMode: String? = nil,
        profile: String? = nil
    ) {
        self.backend = backend
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.profile = profile
    }
}

// MARK: - Server config (all overrides optional)

public struct ServerAuthPartial: Codable, Sendable, Equatable {
    public var adminRoleIds: [String]?
    public var executeRoleIds: [String]?
    public var readOnlyRoleIds: [String]?
    public var adminUserIds: [String]?
    public var executeUserIds: [String]?
    public var readOnlyUserIds: [String]?
    public init(
        adminRoleIds: [String]? = nil,
        executeRoleIds: [String]? = nil,
        readOnlyRoleIds: [String]? = nil,
        adminUserIds: [String]? = nil,
        executeUserIds: [String]? = nil,
        readOnlyUserIds: [String]? = nil
    ) {
        self.adminRoleIds = adminRoleIds
        self.executeRoleIds = executeRoleIds
        self.readOnlyRoleIds = readOnlyRoleIds
        self.adminUserIds = adminUserIds
        self.executeUserIds = executeUserIds
        self.readOnlyUserIds = readOnlyUserIds
    }
}

public struct ServerDefaultsPartial: Codable, Sendable, Equatable {
    public var mode: String?
    public var claudeModel: String?
    public var codexModel: String?
    public var permissionMode: String?
    public var permissionProfile: String?
    public var codexHome: String?
    public var claudeEffort: String?
    public var codexEffort: String?
    public init(
        mode: String? = nil,
        claudeModel: String? = nil,
        codexModel: String? = nil,
        permissionMode: String? = nil,
        permissionProfile: String? = nil,
        codexHome: String? = nil,
        claudeEffort: String? = nil,
        codexEffort: String? = nil
    ) {
        self.mode = mode
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.permissionMode = permissionMode
        self.permissionProfile = permissionProfile
        self.codexHome = codexHome
        self.claudeEffort = claudeEffort
        self.codexEffort = codexEffort
    }
}

public struct PartialLimits: Codable, Sendable, Equatable {
    public var maxSessionsPerUser: Int?
    public var permissionTimeoutSec: Int?
    public var codexTimeoutMs: Int?
    public init(maxSessionsPerUser: Int? = nil, permissionTimeoutSec: Int? = nil, codexTimeoutMs: Int? = nil) {
        self.maxSessionsPerUser = maxSessionsPerUser
        self.permissionTimeoutSec = permissionTimeoutSec
        self.codexTimeoutMs = codexTimeoutMs
    }
}

public struct ServerChannels: Codable, Sendable, Equatable {
    public var categoryId: String
    public var controlChannelId: String
    public var sessionsCategoryId: String
    public var statusChannelId: String?
    public init(categoryId: String, controlChannelId: String, sessionsCategoryId: String, statusChannelId: String? = nil) {
        self.categoryId = categoryId
        self.controlChannelId = controlChannelId
        self.sessionsCategoryId = sessionsCategoryId
        self.statusChannelId = statusChannelId
    }
}

public struct NotificationEvents: Codable, Sendable, Equatable {
    public var result: Bool?
    public var error: Bool?
    public var toolUse: Bool?
    public init(result: Bool? = nil, error: Bool? = nil, toolUse: Bool? = nil) {
        self.result = result
        self.error = error
        self.toolUse = toolUse
    }
}

public struct NotificationsSection: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var channelId: String?
    public var events: NotificationEvents?
    public init(enabled: Bool? = nil, channelId: String? = nil, events: NotificationEvents? = nil) {
        self.enabled = enabled
        self.channelId = channelId
        self.events = events
    }
}

public struct ServerConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var guildId: String
    public var auth: ServerAuthPartial?
    public var defaults: ServerDefaultsPartial?
    public var limits: PartialLimits?
    public var locale: String?
    public var auditChannelId: String?
    public var favorites: [String]?
    public var presets: [Preset]?
    public var channels: ServerChannels?
    public var notifications: NotificationsSection?
    /// Per-guild render-capability overrides (merged over global; under DAB_CAPS).
    public var capabilities: CapabilitiesPartial?

    public init(
        version: Int = CONFIG_VERSION,
        guildId: String,
        auth: ServerAuthPartial? = nil,
        defaults: ServerDefaultsPartial? = nil,
        limits: PartialLimits? = nil,
        locale: String? = nil,
        auditChannelId: String? = nil,
        favorites: [String]? = nil,
        presets: [Preset]? = nil,
        channels: ServerChannels? = nil,
        notifications: NotificationsSection? = nil,
        capabilities: CapabilitiesPartial? = nil
    ) {
        self.version = version
        self.guildId = guildId
        self.auth = auth
        self.defaults = defaults
        self.limits = limits
        self.locale = locale
        self.auditChannelId = auditChannelId
        self.favorites = favorites
        self.presets = presets
        self.channels = channels
        self.notifications = notifications
        self.capabilities = capabilities
    }
}

// MARK: - Defaults constants (TS CONFIG_DEFAULTS)

public enum ConfigDefaults {
    public static let auth = GlobalAuth()
    public static let defaults = DefaultsSection()
    public static let limits = LimitsSection()
    public static let policy = PolicySection()
    public static let autoAllowClaudeTools = ["Read", "Glob", "Grep"]
    public static let usage = UsageSection()
    public static let audit = AuditSection()
    public static let render = RenderSection()
    public static let documentShare = DocumentShareSection()
    public static let chromium = ChromiumSection()
    public static let locale = "ko"
    public static let logLevel = "info"
    public static let favorites: [String] = []
    public static let autoUpdate = AutoUpdateSection()
}

// MARK: - Validation helpers

private let PERM_MODES: Set<String> = [
    "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto",
]
private let DM_POLICIES: Set<String> = ["deny", "allow"]
private let LOG_LEVELS: Set<String> = ["debug", "info", "warn", "error"]
private let UNKNOWN_COMMANDS: Set<String> = ["confirm", "allow", "deny"]
private let CHROMIUM_DECISIONS: Set<String> = ["undecided", "accepted", "declined"]
private let BODY_MODES: Set<String> = ["full", "preview", "attachment_only"]

public enum ConfigValidationError: Error, CustomStringConvertible, Sendable {
    case missingSecrets
    case invalidField(String)
    case malformedNested(String)

    public var description: String {
        switch self {
        case .missingSecrets: return "discord.token and discord.clientId are required"
        case .invalidField(let f): return "invalid config field: \(f)"
        case .malformedNested(let f): return "malformed nested config section: \(f)"
        }
    }
}

/// Validate a fully-defaulted AppConfig (after applyDefaults + decode).
public func validateAppConfig(_ c: AppConfig) throws {
    if c.discord.token.isEmpty || c.discord.clientId.isEmpty {
        throw ConfigValidationError.missingSecrets
    }
    if !DM_POLICIES.contains(c.auth.dmPolicy) {
        throw ConfigValidationError.invalidField("auth.dmPolicy")
    }
    if !PERM_MODES.contains(c.defaults.permissionMode) {
        throw ConfigValidationError.invalidField("defaults.permissionMode")
    }
    if !LOG_LEVELS.contains(c.logLevel) {
        throw ConfigValidationError.invalidField("logLevel")
    }
    if !UNKNOWN_COMMANDS.contains(c.policy.unknownCommand) {
        throw ConfigValidationError.invalidField("policy.unknownCommand")
    }
    if let d = c.chromium?.decision, !CHROMIUM_DECISIONS.contains(d) {
        throw ConfigValidationError.invalidField("chromium.decision")
    }
    if let m = c.documentShare?.bodyMode, !BODY_MODES.contains(m) {
        throw ConfigValidationError.invalidField("documentShare.bodyMode")
    }
}

/// Server file: require version + non-empty guildId; optional nested enums when present.
public func validateServerConfig(_ c: ServerConfig) throws {
    if c.guildId.isEmpty {
        throw ConfigValidationError.invalidField("guildId")
    }
    if let mode = c.defaults?.permissionMode, !PERM_MODES.contains(mode) {
        throw ConfigValidationError.invalidField("defaults.permissionMode")
    }
}

// MARK: - applyDefaults (port config.ts:39–74)

/// Merge one nested section over its default. Malformed array/primitive passes through so
/// subsequent decode/validate fails loudly (TS mergeNested).
func mergeNestedDict(_ raw: Any?, def: [String: Any]) -> Any {
    guard let raw else { return def }
    guard let asObj = raw as? [String: Any] else { return raw }
    var out = def
    for (k, v) in asObj { out[k] = v }
    return out
}

func configDefaultsDict() -> [String: Any] {
    [
        "version": CONFIG_VERSION,
        "auth": [
            "adminRoleIds": [String](),
            "executeRoleIds": [String](),
            "readOnlyRoleIds": [String](),
            "adminUserIds": [String](),
            "executeUserIds": [String](),
            "readOnlyUserIds": [String](),
            "dmPolicy": "deny",
        ] as [String: Any],
        "defaults": [
            "mode": "claude",
            "claudeModel": "opus",
            "codexModel": "",
            "permissionMode": "default",
            "permissionProfile": NSNull(),
            "codexHome": "~/.codex",
            "codexCliCommand": "codex",
            "codexCliVersion": NSNull(),
        ] as [String: Any],
        "limits": [
            "maxSessionsPerUser": 0,
            "permissionTimeoutSec": 0,
            "codexTimeoutMs": 1_800_000,
        ] as [String: Any],
        "policy": [
            "unknownCommand": "confirm",
            "allowExtraCommands": [String](),
        ] as [String: Any],
        "autoAllowClaudeTools": ["Read", "Glob", "Grep"],
        "profiles": [String: Any](),
        "usage": [
            "userAgent": "claude-code",
            "cacheSec": 15,
        ] as [String: Any],
        "audit": [
            "channelId": NSNull(),
        ] as [String: Any],
        "render": ["enabled": true] as [String: Any],
        "documentShare": [
            "maxBytes": 524_288,
            "bodyMode": "preview",
            "previewMaxChars": 8000,
            "extensions": [".md", ".markdown"],
        ] as [String: Any],
        "chromium": ["decision": "undecided"] as [String: Any],
        "locale": "ko",
        "logLevel": "info",
        "favorites": [String](),
        "autoUpdate": ["enabled": true] as [String: Any],
    ]
}

/// Fill missing fields from CONFIG_DEFAULTS. Secrets (discord) have no default.
func applyDefaults(_ raw: [String: Any]) -> [String: Any] {
    let base = configDefaultsDict()
    var out = base
    for (k, v) in raw { out[k] = v }

    if let v = raw["version"] as? Int {
        out["version"] = v
    } else if let v = raw["version"] as? NSNumber {
        out["version"] = v.intValue
    } else {
        out["version"] = CONFIG_VERSION
    }

    // discord: no default — carry raw (may be missing → validation fails)
    out["discord"] = raw["discord"] as Any

    let defs = configDefaultsDict()
    out["auth"] = mergeNestedDict(raw["auth"], def: defs["auth"] as! [String: Any])
    out["defaults"] = mergeNestedDict(raw["defaults"], def: defs["defaults"] as! [String: Any])
    out["limits"] = mergeNestedDict(raw["limits"], def: defs["limits"] as! [String: Any])
    out["policy"] = mergeNestedDict(raw["policy"], def: defs["policy"] as! [String: Any])
    out["usage"] = mergeNestedDict(raw["usage"], def: defs["usage"] as! [String: Any])
    out["audit"] = mergeNestedDict(raw["audit"], def: defs["audit"] as! [String: Any])
    out["render"] = mergeNestedDict(raw["render"], def: defs["render"] as! [String: Any])
    out["documentShare"] = mergeNestedDict(raw["documentShare"], def: defs["documentShare"] as! [String: Any])
    out["chromium"] = mergeNestedDict(raw["chromium"], def: defs["chromium"] as! [String: Any])
    out["autoUpdate"] = mergeNestedDict(raw["autoUpdate"], def: defs["autoUpdate"] as! [String: Any])

    return out
}
