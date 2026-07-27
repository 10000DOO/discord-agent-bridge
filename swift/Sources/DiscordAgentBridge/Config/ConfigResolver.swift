import Foundation

// 3-level config layering: global → server → binding (present value wins).
// Deep-merge for nested objects; arrays/null/non-objects replace wholesale.
// Mirrors src/core/configResolver.ts.

// MARK: - Resolved views

public struct ResolvedConfig: Sendable, Equatable {
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
    public var limits: LimitsSection

    public init(
        mode: String,
        claudeModel: String,
        codexModel: String,
        permissionMode: String,
        permissionProfile: String?,
        codexHome: String,
        codexCliCommand: String,
        codexCliVersion: String?,
        claudeEffort: String?,
        codexEffort: String?,
        limits: LimitsSection
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
        self.limits = limits
    }
}

/// Mode-facing narrow view (TS ModeConfigView).
public struct ModeConfigView: Sendable, Equatable {
    public var model: String
    public var codexModel: String
    public var codexHome: String
    public var codexCliCommand: String
    public var codexCliVersion: String?
    public var permissionTimeoutSec: Int
    public var codexTimeoutMs: Int
}

// MARK: - Binding source (avoid full ChannelRegistry)

public struct ConfigBindingLayer: Sendable, Equatable {
    public var mode: String
    /// Absent / empty → fall through to server/global (TS deepMerge skips undefined).
    public var permissionMode: String?
    public var permissionProfile: String?

    public init(mode: String, permissionMode: String? = nil, permissionProfile: String? = nil) {
        self.mode = mode
        self.permissionMode = permissionMode
        self.permissionProfile = permissionProfile
    }
}

public protocol ConfigBindingSource: Sendable {
    func configBinding(guildId: String, channelId: String) async -> ConfigBindingLayer?
}

/// In-memory fake for tests.
public struct MapBindingSource: ConfigBindingSource {
    public var map: [String: ConfigBindingLayer]  // key = "guildId:channelId" or channelId only

    public init(_ map: [String: ConfigBindingLayer] = [:]) {
        self.map = map
    }

    public func configBinding(guildId: String, channelId: String) async -> ConfigBindingLayer? {
        map["\(guildId):\(channelId)"] ?? map[channelId]
    }
}

/// Adapter over SessionStore: channelId key; mode via normalizeModeId(backend); skips archived.
public struct SessionStoreBindingSource: ConfigBindingSource {
    private let store: SessionStore

    public init(store: SessionStore = .shared) {
        self.store = store
    }

    public func configBinding(guildId: String, channelId: String) async -> ConfigBindingLayer? {
        guard let s = await store.binding(channelId: channelId), !s.archived else { return nil }
        // Optional guild filter: if guildId on record mismatches, still return (channelId keys).
        _ = guildId
        // Empty/missing permMode → nil so resolver falls through to server/global.
        let perm: String? = {
            guard let p = s.permMode, !p.isEmpty else { return nil }
            return p
        }()
        return ConfigBindingLayer(
            mode: normalizeModeId(s.backend.rawValue),
            permissionMode: perm,
            permissionProfile: s.permissionProfile
        )
    }
}

// MARK: - deepMerge (TS 1:1 semantics on JSON-ish trees)

/// Deep-merge plain objects. `nil` / absent keys in overlay fall through.
/// Arrays, null, and non-objects replace wholesale.
func deepMergeJSON(_ base: Any, _ over: Any?) -> Any {
    guard let over else { return base }
    guard let baseObj = base as? [String: Any], let overObj = over as? [String: Any] else {
        return over
    }
    var out = baseObj
    for (k, v) in overObj {
        if v is NSNull {
            out[k] = NSNull()
            continue
        }
        // Optional: skip explicit Optional.none representation — not used with [String: Any]
        if let prev = out[k], prev is [String: Any], v is [String: Any] {
            out[k] = deepMergeJSON(prev, v)
        } else {
            out[k] = v
        }
    }
    return out
}

// MARK: - Resolver

public struct ConfigResolver: Sendable {
    private let configStore: ConfigStore
    private let bindingSource: any ConfigBindingSource

    public init(configStore: ConfigStore, bindingSource: any ConfigBindingSource) {
        self.configStore = configStore
        self.bindingSource = bindingSource
    }

    public func resolve(guildId: String, channelId: String) async throws -> ResolvedConfig {
        let global = try await configStore.load()
        let server = await configStore.loadServerConfig(guildId: guildId)
        let binding = await bindingSource.configBinding(guildId: guildId, channelId: channelId)
        return Self.merge(global: global, server: server, binding: binding)
    }

    public func resolveModeConfig(guildId: String, channelId: String) async throws -> ModeConfigView {
        let r = try await resolve(guildId: guildId, channelId: channelId)
        return ModeConfigView(
            model: r.claudeModel,
            codexModel: r.codexModel,
            codexHome: r.codexHome,
            codexCliCommand: r.codexCliCommand,
            codexCliVersion: r.codexCliVersion,
            permissionTimeoutSec: r.limits.permissionTimeoutSec,
            codexTimeoutMs: r.limits.codexTimeoutMs
        )
    }

    /// Pure merge (no disk). Exposed for unit tests.
    public static func merge(
        global: AppConfig,
        server: ServerConfig?,
        binding: ConfigBindingLayer?
    ) -> ResolvedConfig {
        // Level 1: global defaults.
        var result = ResolvedConfig(
            mode: global.defaults.mode,
            claudeModel: global.defaults.claudeModel,
            codexModel: global.defaults.codexModel,
            permissionMode: global.defaults.permissionMode,
            permissionProfile: global.defaults.permissionProfile,
            codexHome: global.defaults.codexHome,
            codexCliCommand: global.defaults.codexCliCommand,
            codexCliVersion: global.defaults.codexCliVersion,
            claudeEffort: global.defaults.claudeEffort,
            codexEffort: global.defaults.codexEffort,
            limits: global.limits
        )

        // Level 2: server (only fields §8.1 allows; NOT codexCliCommand/Version).
        if let server {
            var overlay: [String: Any] = [:]
            if let d = server.defaults {
                if let v = d.mode { overlay["mode"] = v }
                if let v = d.claudeModel { overlay["claudeModel"] = v }
                if let v = d.codexModel { overlay["codexModel"] = v }
                if let v = d.permissionMode { overlay["permissionMode"] = v }
                // permissionProfile: string value overrides; explicit JSON `null` (tracked via
                // permissionProfileExplicitlyNull, set only by ServerDefaultsPartial's custom
                // decoder) clears the global value instead of being ignored (H19).
                if let v = d.permissionProfile {
                    overlay["permissionProfile"] = v
                } else if d.permissionProfileExplicitlyNull {
                    overlay["permissionProfile"] = NSNull()
                }
                if let v = d.codexHome { overlay["codexHome"] = v }
                if let v = d.claudeEffort { overlay["claudeEffort"] = v }
                if let v = d.codexEffort { overlay["codexEffort"] = v }
            }
            if let lim = server.limits {
                var limDict: [String: Any] = [:]
                if let v = lim.maxSessionsPerUser { limDict["maxSessionsPerUser"] = v }
                if let v = lim.permissionTimeoutSec { limDict["permissionTimeoutSec"] = v }
                if let v = lim.codexTimeoutMs { limDict["codexTimeoutMs"] = v }
                if !limDict.isEmpty { overlay["limits"] = limDict }
            }
            if !overlay.isEmpty {
                result = applyOverlay(result, overlay)
            }
        }

        // Level 3: binding — mode always; permissionMode only when non-empty; profile as given.
        if let binding {
            result.mode = binding.mode
            if let p = binding.permissionMode, !p.isEmpty {
                result.permissionMode = p
            }
            // Always layer profile (including nil) when a binding is present — matches TS
            // deepMerge of binding.profile (null leaf replaces).
            result.permissionProfile = binding.permissionProfile
        }

        return result
    }

    private static func applyOverlay(_ base: ResolvedConfig, _ overlay: [String: Any]) -> ResolvedConfig {
        var r = base
        if let v = overlay["mode"] as? String { r.mode = v }
        if let v = overlay["claudeModel"] as? String { r.claudeModel = v }
        if let v = overlay["codexModel"] as? String { r.codexModel = v }
        if let v = overlay["permissionMode"] as? String { r.permissionMode = v }
        if let v = overlay["permissionProfile"] as? String { r.permissionProfile = v }
        if overlay["permissionProfile"] is NSNull { r.permissionProfile = nil }
        if let v = overlay["codexHome"] as? String { r.codexHome = v }
        if let v = overlay["claudeEffort"] as? String { r.claudeEffort = v }
        if let v = overlay["codexEffort"] as? String { r.codexEffort = v }
        if let lim = overlay["limits"] as? [String: Any] {
            if let v = lim["maxSessionsPerUser"] as? Int { r.limits.maxSessionsPerUser = v }
            if let v = lim["permissionTimeoutSec"] as? Int { r.limits.permissionTimeoutSec = v }
            if let v = lim["codexTimeoutMs"] as? Int { r.limits.codexTimeoutMs = v }
            // NSNumber bridge
            if let v = lim["maxSessionsPerUser"] as? NSNumber { r.limits.maxSessionsPerUser = v.intValue }
            if let v = lim["permissionTimeoutSec"] as? NSNumber { r.limits.permissionTimeoutSec = v.intValue }
            if let v = lim["codexTimeoutMs"] as? NSNumber { r.limits.codexTimeoutMs = v.intValue }
        }
        return r
    }
}
