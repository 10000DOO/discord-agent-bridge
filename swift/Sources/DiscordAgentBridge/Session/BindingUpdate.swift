import Foundation

/// Field-level patch for a channel binding (W11-d). Pure — no I/O.
public struct BindingPatch: Sendable, Equatable {
    public var model: String?
    public var effort: String?
    public var permMode: String?
    public var backend: Backend?
    /// Named permission profile (SessionStore `permissionProfile`). Applied only when
    /// `updatePermissionProfile` is true so a raw permMode switch can leave it alone.
    public var permissionProfile: String?
    /// When true, write `permissionProfile` (including nil) onto the persisted session.
    public var updatePermissionProfile: Bool
    /// When true, wipe `backendSessionId` so the next turn starts fresh (not resume).
    public var clearBackendSessionId: Bool

    public init(
        model: String? = nil,
        effort: String? = nil,
        permMode: String? = nil,
        backend: Backend? = nil,
        permissionProfile: String? = nil,
        updatePermissionProfile: Bool = false,
        clearBackendSessionId: Bool = false
    ) {
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.backend = backend
        self.permissionProfile = permissionProfile
        self.updatePermissionProfile = updatePermissionProfile
        self.clearBackendSessionId = clearBackendSessionId
    }
}

// MARK: - G-P1-04 /mode perm profile resolution (TS switchPerm)

/// Result of resolving a `/mode perm` value against `config.profiles`.
public struct ModePermResolution: Sendable, Equatable {
    public var permMode: String
    /// Set when `value` named a known profile; nil for a raw permMode switch.
    public var permissionProfile: String?
    /// Whether the caller should persist `permissionProfile` (profile path only).
    public var updatePermissionProfile: Bool

    public init(permMode: String, permissionProfile: String?, updatePermissionProfile: Bool) {
        self.permMode = permMode
        self.permissionProfile = permissionProfile
        self.updatePermissionProfile = updatePermissionProfile
    }

    /// Display label for the slash reply (TS: `resolved.profile ?? resolved.permMode`).
    public var display: String { permissionProfile ?? permMode }

    /// Binding patch carrying resolved permMode (+ profile when applicable).
    public var bindingPatch: BindingPatch {
        BindingPatch(
            permMode: permMode,
            permissionProfile: permissionProfile,
            updatePermissionProfile: updatePermissionProfile
        )
    }
}

/// TS `switchPerm`: if `value` is a key in `config.profiles`, store that profile and its
/// bundled `permissionMode`; otherwise treat `value` as a raw permission mode and leave
/// any existing `permissionProfile` untouched.
public func resolveModePerm(
    value: String,
    profiles: [String: Profile]
) -> ModePermResolution {
    if let profile = profiles[value] {
        return ModePermResolution(
            permMode: profile.permissionMode,
            permissionProfile: value,
            updatePermissionProfile: true
        )
    }
    return ModePermResolution(
        permMode: value,
        permissionProfile: nil,
        updatePermissionProfile: false
    )
}

/// Apply a patch to the in-memory routing config.
public func applyPatch(to config: SessionConfig, _ p: BindingPatch) -> SessionConfig {
    var c = config
    if let b = p.backend { c.backend = b }
    if let m = p.model { c.model = m }
    if let e = p.effort { c.effort = e }
    if let pm = p.permMode { c.permMode = pm }
    return c
}

/// Apply a patch to a persisted session row. `clearBackendSessionId` drops the resume id.
public func applyPatch(to session: PersistedSession, _ p: BindingPatch, now: String) -> PersistedSession {
    var s = session
    if let b = p.backend { s.backend = b }
    if let m = p.model { s.model = m }
    if let e = p.effort { s.effort = e }
    if let pm = p.permMode { s.permMode = pm }
    if p.updatePermissionProfile { s.permissionProfile = p.permissionProfile }
    if p.clearBackendSessionId { s.backendSessionId = nil }
    s.updatedAt = now
    return s
}

/// Build a routing config from a store row (resume / clear rebind).
public func sessionConfig(from session: PersistedSession) -> SessionConfig {
    SessionConfig(
        backend: session.backend,
        model: session.model,
        effort: session.effort,
        permMode: session.permMode
    )
}

/// One active-channel row for `/agent stats` (pure; no Discord).
/// `queueDepth` = waiting turns (not including the running one); mirrors TS
/// `ActiveChannelInfo.queueDepth` / `running`.
public struct StatsBindingLine: Sendable, Equatable {
    public var channelId: String
    public var backend: Backend
    public var model: String?
    public var effort: String?
    public var queueDepth: Int
    public var running: Bool

    public init(
        channelId: String,
        backend: Backend,
        model: String? = nil,
        effort: String? = nil,
        queueDepth: Int = 0,
        running: Bool = false
    ) {
        self.channelId = channelId
        self.backend = backend
        self.model = model
        self.effort = effort
        self.queueDepth = queueDepth
        self.running = running
    }
}

/// Ephemeral `/agent stats` lines from active bindings (pure formatter).
/// Includes model/effort when set (W11-g) and queue/running (G-P2-04 / TS listActive).
public func formatStatsLines(bindings: [StatsBindingLine]) -> [String] {
    if bindings.isEmpty { return ["(none)"] }
    return bindings.map { b in
        var line = "<#\(b.channelId)> · \(b.backend.rawValue)"
        if let m = b.model { line += " · `\(m)`" }
        if let e = b.effort { line += " · effort=\(e)" }
        line += " · queue \(b.queueDepth)"
        if b.running { line += " · running" }
        return line
    }
}

/// Backward-compatible overload (model/effort only; queue 0, not running).
public func formatStatsLines(
    bindings: [(channelId: String, backend: Backend, model: String?, effort: String?)]
) -> [String] {
    formatStatsLines(bindings: bindings.map {
        StatsBindingLine(
            channelId: $0.channelId,
            backend: $0.backend,
            model: $0.model,
            effort: $0.effort
        )
    })
}
