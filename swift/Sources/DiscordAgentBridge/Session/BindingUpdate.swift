import Foundation

/// Field-level patch for a channel binding (W11-d). Pure — no I/O.
public struct BindingPatch: Sendable, Equatable {
    public var model: String?
    public var effort: String?
    public var permMode: String?
    public var backend: Backend?
    /// When true, wipe `backendSessionId` so the next turn starts fresh (not resume).
    public var clearBackendSessionId: Bool

    public init(
        model: String? = nil,
        effort: String? = nil,
        permMode: String? = nil,
        backend: Backend? = nil,
        clearBackendSessionId: Bool = false
    ) {
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.backend = backend
        self.clearBackendSessionId = clearBackendSessionId
    }
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

/// Ephemeral `/agent stats` lines from active bindings (pure formatter).
/// Includes model and effort when set (W11-g slice1).
public func formatStatsLines(
    bindings: [(channelId: String, backend: Backend, model: String?, effort: String?)]
) -> [String] {
    if bindings.isEmpty { return ["(none)"] }
    return bindings.map { b in
        var line = "<#\(b.channelId)> · \(b.backend.rawValue)"
        if let m = b.model { line += " · `\(m)`" }
        if let e = b.effort { line += " · effort=\(e)" }
        return line
    }
}
