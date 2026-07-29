import Foundation

// Per-guild event notifier pure core (TS `src/discord/notifier.ts`).
// formatNotification / resolveNotifications are pure; SessionNotifier posts via an injected sink.

// MARK: - Resolved config

public struct ResolvedNotificationEvents: Sendable, Equatable {
    public var result: Bool
    public var error: Bool
    public var toolUse: Bool

    public init(result: Bool = true, error: Bool = true, toolUse: Bool = false) {
        self.result = result
        self.error = error
        self.toolUse = toolUse
    }
}

public struct ResolvedNotifications: Sendable, Equatable {
    public var enabled: Bool
    public var channelId: String?
    public var events: ResolvedNotificationEvents

    public init(enabled: Bool, channelId: String?, events: ResolvedNotificationEvents) {
        self.enabled = enabled
        self.channelId = channelId
        self.events = events
    }
}

/// Resolve a guild's notifications block with defaults (enabled=true; status channel fallback;
/// events result/error on, toolUse off).
public func resolveNotifications(_ server: ServerConfig?) -> ResolvedNotifications {
    let n = server?.notifications
    let statusFallback = server?.channels?.statusChannelId
    return ResolvedNotifications(
        enabled: n?.enabled ?? true,
        channelId: n?.channelId ?? statusFallback,
        events: ResolvedNotificationEvents(
            result: n?.events?.result ?? true,
            error: n?.events?.error ?? true,
            toolUse: n?.events?.toolUse ?? false
        )
    )
}

// MARK: - Format

/// Compact one-line summary for an event, or nil when filtered off / unsupported kind.
public func formatNotification(
    _ ev: AgentEvent,
    sessionChannelId: String,
    events: ResolvedNotificationEvents,
    usage: UsageResult? = nil
) -> String? {
    switch ev {
    case .turnComplete:
        return nil
    case .result(_, let costUsd, let tokensIn, let tokensOut, let durationMs):
        guard events.result else { return nil }
        var line = I18n.t("notify.result.done", ["channel": sessionChannelId])
        if let tin = tokensIn, let tout = tokensOut {
            line += I18n.t("notify.result.tokens", ["tokensIn": "\(tin)", "tokensOut": "\(tout)"])
        }
        if let ms = durationMs { line += I18n.t("notify.result.duration", ["ms": "\(ms)"]) }
        if let cost = costUsd { line += I18n.t("notify.result.cost", ["cost": "\(cost)"]) }
        return line
    case .error(let message, _):
        guard events.error else { return nil }
        let msg = String(message.prefix(500))
        return I18n.t("notify.error", ["channel": sessionChannelId, "message": msg])
    case .rateLimit(let resetAt, let rateLimitType, let utilization):
        // Gated by events.error (TS parity — operational status).
        guard events.error else { return nil }
        if let windows = formatUsageWindows(usage) {
            return I18n.t("notify.rateLimit", ["channel": sessionChannelId, "windows": windows])
        }
        var line = I18n.t("notify.rateLimit.base", ["channel": sessionChannelId])
        if let t = rateLimitType { line += I18n.t("notify.rateLimit.type", ["label": rateLimitTypeLabel(t)]) }
        if let u = utilization { line += I18n.t("notify.rateLimit.utilization", ["util": "\(Int(u.rounded()))"]) }
        if let r = resetAt, let date = parseISODate(r) {
            let fmt = DateFormatter()
            fmt.locale = I18n.getLocale() == .ko ? Locale(identifier: "ko_KR") : Locale(identifier: "en_US")
            fmt.dateFormat = "HH:mm"
            line += I18n.t("notify.rateLimit.reset", ["time": fmt.string(from: date)])
        }
        return line
    case .toolUse(_, let name, _, _):
        guard events.toolUse else { return nil }
        return I18n.t("notify.toolUse", ["channel": sessionChannelId, "name": name])
    default:
        return nil
    }
}

// MARK: - Notifier (pure post path)

/// Status-channel sink for one-line summaries.
public struct NotificationSink: Sendable {
    public var send: @Sendable (_ content: String) async throws -> Void

    public init(send: @escaping @Sendable (_ content: String) async throws -> Void) {
        self.send = send
    }
}

/// Formats + posts notification lines. Fire-and-forget failures are swallowed by the caller.
public struct SessionNotifier: Sendable {
    public var statusChannel: NotificationSink
    public var sessionChannelId: String
    public var events: ResolvedNotificationEvents
    public var getUsage: (@Sendable () async -> UsageResult?)?

    public init(
        statusChannel: NotificationSink,
        sessionChannelId: String,
        events: ResolvedNotificationEvents,
        getUsage: (@Sendable () async -> UsageResult?)? = nil
    ) {
        self.statusChannel = statusChannel
        self.sessionChannelId = sessionChannelId
        self.events = events
        self.getUsage = getUsage
    }

    public func notify(_ ev: AgentEvent) async {
        let usage: UsageResult?
        if case .rateLimit = ev {
            usage = await getUsage?()
        } else {
            usage = nil
        }
        guard let line = formatNotification(ev, sessionChannelId: sessionChannelId, events: events, usage: usage)
        else { return }
        try? await statusChannel.send(line)
    }
}
