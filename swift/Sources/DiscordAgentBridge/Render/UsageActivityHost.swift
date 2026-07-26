import Foundation

// Per-channel real-time usage/rate-limit notifier (H10). TS's generic renderer posts a fresh
// usage embed / rate-limit line the instant a context_usage / rate_limit AgentEvent arrives
// (renderers/index.ts:323-365) — it never waits for the turn to finish. Investigation confirmed
// this cardinality-per-turn issue is Claude/Dab-only: Codex emits context_usage exactly once at
// turn completion by design (appSession.ts:211-219, "Emit mapped events first ... then one
// context_usage at turn end") and has no rate_limit at all; Grok computes context_usage once,
// synchronously, when the turn's single blocking prompt call returns (acpSession.ts:383-394) and
// also has no rate_limit. Only DabSessionBridge (Claude sidecar) streams these mid-turn, so it is
// the only caller of this host.
//
// Kept separate from ToolActivityHost (same "actor + setNotifier + setNotifyContext" shape as
// that host / StreamStatusHost / IdleWatchdog / DocumentShareHost / FileAttachHost) — a distinct
// concern (usage/limits vs tool activity threads/diffs) that would muddy ToolActivityHost's single
// responsibility if bolted on there.

/// One mid-turn usage-related AgentEvent, carrying what the bridge alone knows (the turn-local
/// tools/agents snapshot) so dab need not recompute it.
public enum UsageActivityEvent: Sendable {
    /// TS `usage(ev)` — capability-gated by `caps.usagePanel` (renderers/index.ts:105).
    case contextUsage(ContextUsageInfo, tools: [TurnToolStat], agents: [SubagentRun])
    /// TS `rateLimit(ev)` — always fires, never capability-gated (renderers/index.ts:112-113).
    case rateLimit(RateLimitInfo)
}

public typealias UsageActivityNotifier = @Sendable (
    _ channelId: String, _ guildId: String, _ backend: Backend, _ permMode: String?,
    _ event: UsageActivityEvent
) async -> Void

/// Mid-turn context_usage / rate_limit → immediate Discord post (H10 parity with TS's
/// renderers/index.ts usage(ev)/rateLimit(ev), which never wait for turn end).
public actor UsageActivityHost {
    public static let shared = UsageActivityHost()

    private var notifier: UsageActivityNotifier?
    /// Per-channel render caps (set by dab each turn, alongside ToolActivityHost.setCapabilities).
    private var capsByChannel: [String: Capabilities] = [:]
    /// Per-channel guildId/backend/permMode for the notifier (set by dab each turn).
    private var notifyContextByChannel: [String: (guildId: String, backend: Backend, permMode: String?)] = [:]

    public init() {}

    /// Wire the real-time notifier once at startup (dab). Absent → events no-op.
    public func setNotifier(_ notifier: UsageActivityNotifier?) {
        self.notifier = notifier
    }

    /// Bind render capabilities for a session channel (contextUsage's usagePanel gate).
    public func setCapabilities(channelId: String, _ caps: Capabilities) {
        capsByChannel[channelId] = caps
    }

    /// Bind guildId/backend/permMode for a session channel (dab, each turn).
    public func setNotifyContext(channelId: String, guildId: String, backend: Backend, permMode: String?) {
        notifyContextByChannel[channelId] = (guildId: guildId, backend: backend, permMode: permMode)
    }

    /// Fire the notifier for a mid-turn context_usage/rate_limit event.
    public func notify(channelId: String, _ event: UsageActivityEvent) {
        guard let notifier, let ctx = notifyContextByChannel[channelId] else { return }
        if case .contextUsage = event, !(capsByChannel[channelId] ?? .allEnabled).usagePanel { return }
        Task { await notifier(channelId, ctx.guildId, ctx.backend, ctx.permMode, event) }
    }

    /// Drop all state for a channel (session stop / detach).
    public func dispose(channelId: String) {
        capsByChannel.removeValue(forKey: channelId)
        notifyContextByChannel.removeValue(forKey: channelId)
    }
}
