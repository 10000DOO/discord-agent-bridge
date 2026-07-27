import Foundation

/// Which coding-agent backend handles a channel's session.
/// `custom` is Claude + shell-dotfile env overlay (TS `CustomMode`).
public enum Backend: String, Sendable, CaseIterable, Equatable {
    case claude
    case codex
    case grok
    case custom
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

    /// Snapshot of every bound channel (for `/stop-all` + lifecycle enumeration).
    public func list() -> [String: SessionConfig] { bindings }
}

/// Where a Discord channel message should go. Pure decision (no I/O) so it is unit-testable.
public enum RouteDecision: Sendable, Equatable {
    case prefixClaude(String)   // "!claude <prompt>"
    case prefixCodex(String)    // "!codex <prompt>"
    case prefixGrok(String)     // "!grok <prompt>"
    case prefixCustom(String)   // "!custom <prompt>" — Claude path + shell-env overlay
    case bound(Backend, String) // no prefix, channel is bound → route full text to that backend
    case usage(String)          // a known prefix with an empty prompt → show "Usage: `<label> …`"
    case ignore                 // nothing to do
}

/// Prefixes are accepted only for an already-bound channel; otherwise every message is ignored.
/// This prevents an arbitrary unbound channel from starting a backend process by typing a prefix.
/// `hasAttachments`: empty body + files still routes on a bound channel (G-P0-01).
/// `isDM`: TS `messageRouter.ts:144` mirror (H15) — DMs (no guildId) are ignored unconditionally,
/// before prefix/binding logic runs, regardless of dmPolicy (that's a separate, later gate).
public func routeDecision(content: String, binding: SessionConfig?, hasAttachments: Bool = false, isDM: Bool = false) -> RouteDecision {
    if isDM { return .ignore }
    guard let binding else { return .ignore }
    func strip(_ prefix: String) -> String? {
        guard content.hasPrefix(prefix) else { return nil }
        return String(content.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let p = strip("!claude ") { return p.isEmpty ? .usage("!claude") : .prefixClaude(p) }
    if let p = strip("!codex ")  { return p.isEmpty ? .usage("!codex")  : .prefixCodex(p) }
    if let p = strip("!grok ")   { return p.isEmpty ? .usage("!grok")   : .prefixGrok(p) }
    if let p = strip("!custom ") { return p.isEmpty ? .usage("!custom") : .prefixCustom(p) }
    let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty || hasAttachments { return .bound(binding.backend, text) }
    return .ignore
}
