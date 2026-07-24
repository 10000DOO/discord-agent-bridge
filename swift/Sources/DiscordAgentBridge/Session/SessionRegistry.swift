import Foundation

/// Which coding-agent backend handles a channel's session.
public enum Backend: String, Sendable, CaseIterable, Equatable {
    case claude
    case codex
    case grok
}

/// Per-channel session settings. W11-a binds `backend` only; model/effort/permMode are the seam
/// the wizard (W11-b) will fill — bridges do NOT consume them yet.
public struct SessionConfig: Sendable, Equatable {
    public var backend: Backend
    public var model: String?
    public var effort: String?
    public var permMode: String?

    public init(backend: Backend, model: String? = nil, effort: String? = nil, permMode: String? = nil) {
        self.backend = backend
        self.model = model
        self.effort = effort
        self.permMode = permMode
    }
}

/// channelId → bound session config. One process-wide store (Discord event handlers are recreated
/// per event, so binding state cannot live there).
public actor SessionRegistry {
    public static let shared = SessionRegistry()

    private var bindings: [String: SessionConfig] = [:]

    public init() {}

    public func bind(channelId: String, _ config: SessionConfig) {
        bindings[channelId] = config
    }

    public func binding(channelId: String) -> SessionConfig? {
        bindings[channelId]
    }

    public func unbind(channelId: String) {
        bindings[channelId] = nil
    }
}

/// Where a Discord channel message should go. Pure decision (no I/O) so it is unit-testable.
public enum RouteDecision: Sendable, Equatable {
    case prefixClaude(String)   // "!claude <prompt>"
    case prefixCodex(String)    // "!codex <prompt>"
    case prefixGrok(String)     // "!grok <prompt>"
    case bound(Backend, String) // no prefix, channel is bound → route full text to that backend
    case usage(String)          // a known prefix with an empty prompt → show "Usage: `<label> …`"
    case ignore                 // nothing to do
}

/// Explicit prefixes win (one-off override); otherwise a bound channel routes plain text; else ignore.
public func routeDecision(content: String, binding: SessionConfig?) -> RouteDecision {
    func strip(_ prefix: String) -> String? {
        guard content.hasPrefix(prefix) else { return nil }
        return String(content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let p = strip("!claude ") { return p.isEmpty ? .usage("!claude") : .prefixClaude(p) }
    if let p = strip("!codex ")  { return p.isEmpty ? .usage("!codex")  : .prefixCodex(p) }
    if let p = strip("!grok ")   { return p.isEmpty ? .usage("!grok")   : .prefixGrok(p) }
    if let binding {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return .bound(binding.backend, text) }
    }
    return .ignore
}
