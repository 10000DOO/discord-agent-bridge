import Foundation

// Pure usage/status formatters (TS `src/discord/format.ts` + `renderers/resultLine.ts`).
// No I/O — unit-testable. W11-g slice1.

/// Embed colors (TS `format.ts` COLORS). Used by status/usage embeds (slice2+).
public enum DiscordColors {
    public static let streaming = 0xfee75c // yellow
    public static let thinking = 0x9b59b6 // purple
    public static let permission = 0xe67e22 // orange
    public static let idle = 0x57f287 // green
    public static let error = 0xed4245 // red
    public static let stopped = 0xed4245 // red
}

/// Per-turn cost/token/duration metrics (from `result` event or backend turn usage).
public struct TurnUsage: Sendable, Equatable {
    public var costUsd: Double?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var durationMs: Int?

    public init(
        costUsd: Double? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.costUsd = costUsd
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.durationMs = durationMs
    }

    /// True when at least one metric field is present (resultLine is non-nil).
    public var hasMetrics: Bool {
        costUsd != nil || tokensIn != nil || tokensOut != nil || durationMs != nil
    }
}

/// Latest `context_usage` AgentEvent fields captured on a turn (W11-g slice2).
public struct ContextUsageInfo: Sendable, Equatable {
    public var totalTokens: Int
    public var maxTokens: Int
    public var percentage: Double
    public var model: String?
    public var modelDisplayName: String?
    public var clearableTokens: Int?
    public var memoryFileCount: Int?
    public var mcpServerCount: Int?

    public init(
        totalTokens: Int,
        maxTokens: Int,
        percentage: Double,
        model: String? = nil,
        modelDisplayName: String? = nil,
        clearableTokens: Int? = nil,
        memoryFileCount: Int? = nil,
        mcpServerCount: Int? = nil
    ) {
        self.totalTokens = totalTokens
        self.maxTokens = maxTokens
        self.percentage = percentage
        self.model = model
        self.modelDisplayName = modelDisplayName
        self.clearableTokens = clearableTokens
        self.memoryFileCount = memoryFileCount
        self.mcpServerCount = mcpServerCount
    }

    public static func from(event: AgentEvent) -> ContextUsageInfo? {
        guard case .contextUsage(
            let total, let max, let pct, let model, let display,
            let clearable, let mem, let mcp
        ) = event else { return nil }
        return ContextUsageInfo(
            totalTokens: total,
            maxTokens: max,
            percentage: pct,
            model: model,
            modelDisplayName: display,
            clearableTokens: clearable,
            memoryFileCount: mem,
            mcpServerCount: mcp
        )
    }
}

/// Latest `rate_limit` AgentEvent fields captured on a turn (W11-g slice2).
public struct RateLimitInfo: Sendable, Equatable {
    public var resetAt: String?
    public var rateLimitType: String?
    public var utilization: Double?

    public init(resetAt: String? = nil, rateLimitType: String? = nil, utilization: Double? = nil) {
        self.resetAt = resetAt
        self.rateLimitType = rateLimitType
        self.utilization = utilization
    }
}

// MARK: - Turn tools / subagent HUD (W11-g slice4, TS usageEmbed + renderers/index)

/// One tool name's turn-local aggregate: ×count with failed > 0 → ❌.
public struct TurnToolStat: Sendable, Equatable {
    public var name: String
    public var count: Int
    public var failed: Int

    public init(name: String, count: Int, failed: Int = 0) {
        self.name = name
        self.count = count
        self.failed = failed
    }
}

/// One completed subagent run (subagent_result paired with Task/Agent tool_use input).
public struct SubagentRun: Sendable, Equatable {
    public var status: AgentEvent.SubagentStatus
    public var summary: String
    public var type: String?
    public var description: String?
    public var durationMs: Int?

    public init(
        status: AgentEvent.SubagentStatus,
        summary: String,
        type: String? = nil,
        description: String? = nil,
        durationMs: Int? = nil
    ) {
        self.status = status
        self.summary = summary
        self.type = type
        self.description = description
        self.durationMs = durationMs
    }
}

/// Turn-local tool_use / tool_result / subagent_result aggregator (TS renderers/index noteToolEvent).
/// Snapshot at turn end so the next turn never sees stale counts (fresh TurnBox per turn).
public struct TurnToolStatsAggregator: Sendable {
    private var toolCounts: [String: (count: Int, failed: Int)] = [:]
    private var toolNamesById: [String: String] = [:]
    private var taskInputsById: [String: (type: String?, description: String?)] = [:]
    private var agentRuns: [SubagentRun] = []

    public init() {}

    public mutating func note(_ event: AgentEvent) {
        switch event {
        case .toolUse(let id, let name, let input, _):
            toolNamesById[id] = name
            var stat = toolCounts[name] ?? (count: 0, failed: 0)
            stat.count += 1
            toolCounts[name] = stat
            // Claude Task/Agent spawn — pair type/description with later subagent_result.
            if name == "Task" || name == "Agent" {
                taskInputsById[id] = (
                    type: input["subagent_type"]?.stringValue,
                    description: input["description"]?.stringValue
                )
            }
        case .toolResult(let id, let ok, _, _):
            guard !ok, let name = toolNamesById[id], var stat = toolCounts[name] else { return }
            stat.failed += 1
            toolCounts[name] = stat
        case .subagentResult(_, let status, let summary, let toolUseId, let durationMs, _):
            let started = toolUseId.flatMap { taskInputsById[$0] }
            agentRuns.append(SubagentRun(
                status: status,
                summary: summary,
                type: started?.type,
                description: started?.description,
                durationMs: durationMs
            ))
        default:
            break
        }
    }

    public func toolsSnapshot() -> [TurnToolStat] {
        toolCounts.map { TurnToolStat(name: $0.key, count: $0.value.count, failed: $0.value.failed) }
    }

    public func agentsSnapshot() -> [SubagentRun] { agentRuns }

    /// Total tool_use count this turn (for "응답 완료 · 🛠️ N").
    public var totalToolCount: Int {
        toolCounts.values.reduce(0) { $0 + $1.count }
    }

    public mutating func reset() {
        toolCounts.removeAll()
        toolNamesById.removeAll()
        taskInputsById.removeAll()
        agentRuns.removeAll()
    }
}

/// Bridge `runTurn` return: reply text + optional usage / context / rate-limit / tools HUD (W11-g).
public struct TurnResult: Sendable, Equatable {
    public var text: String
    public var usage: TurnUsage?
    public var contextUsage: ContextUsageInfo?
    public var rateLimit: RateLimitInfo?
    /// Turn-local tool aggregates for the usage embed (empty when no tools fired).
    public var tools: [TurnToolStat]
    /// Turn-local subagent runs for the usage embed (empty when none completed).
    public var agents: [SubagentRun]

    public init(
        text: String,
        usage: TurnUsage? = nil,
        contextUsage: ContextUsageInfo? = nil,
        rateLimit: RateLimitInfo? = nil,
        tools: [TurnToolStat] = [],
        agents: [SubagentRun] = []
    ) {
        self.text = text
        self.usage = usage
        self.contextUsage = contextUsage
        self.rateLimit = rateLimit
        self.tools = tools
        self.agents = agents
    }
}

// MARK: - mentionOnComplete (TS mentionOnComplete.ts)

/// Content for the post-turn owner ping. Nil when ownerId is empty (skip broken `<@>`).
public func mentionOnCompleteContent(ownerId: String) -> String? {
    guard !ownerId.isEmpty else { return nil }
    return "<@\(ownerId)>"
}

// MARK: - context_usage line

/// One-line context summary after a turn (surface TurnResult.contextUsage).
public func formatContextUsageLine(_ ctx: ContextUsageInfo) -> String {
    var parts: [String] = ["📊 컨텍스트 \(Int(ctx.percentage.rounded()))%"]
    parts.append("\(formatTokens(ctx.totalTokens))/\(formatTokens(ctx.maxTokens))")
    if let name = ctx.modelDisplayName ?? ctx.model, !name.isEmpty {
        parts.append(name)
    }
    return parts.joined(separator: " · ")
}

// MARK: - rate_limit line (TS renderers/index.ts formatRateLimitLine)

/// Human-readable label for SDK rateLimitType codes. Unknown types pass through verbatim.
public func rateLimitTypeLabel(_ type: String) -> String {
    switch type {
    case "five_hour": return "5시간 한도"
    case "seven_day": return "주간 한도"
    case "seven_day_opus": return "주간 한도 (Opus)"
    case "seven_day_sonnet": return "주간 한도 (Sonnet)"
    case "overage": return "추가 사용량"
    default: return type
    }
}

/// Format a window's reset time: HH:mm when today, else M/d HH:mm (ko-KR 24h).
public func formatResetTime(_ resetsAt: String?, now: Date = Date()) -> String? {
    guard let resetsAt, let date = parseISODate(resetsAt) else { return nil }
    let cal = Calendar.current
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "ko_KR")
    if cal.isDate(date, inSameDayAs: now) {
        fmt.dateFormat = "HH:mm"
    } else {
        fmt.dateFormat = "M/d HH:mm"
    }
    return fmt.string(from: date)
}

/// Render every present usage window as `라벨 {util}% (리셋 …)` segments, or nil.
public func formatUsageWindows(_ usage: UsageResult?) -> String? {
    guard let usage, case .snapshot(let snap) = usage else { return nil }
    return formatUsageWindows(snapshot: snap)
}

public func formatUsageWindows(snapshot: UsageSnapshot) -> String? {
    var segments: [String] = []
    func add(_ limit: UsageLimit?, _ label: String) {
        guard let limit else { return }
        let reset = formatResetTime(limit.resetsAt)
        segments.append("\(label) \(Int(limit.utilization.rounded()))%\(reset.map { " (리셋 \($0))" } ?? "")")
    }
    add(snapshot.fiveHour, "5시간")
    add(snapshot.sevenDay, "주간")
    add(snapshot.sevenDayOpus, "주간(Opus)")
    add(snapshot.sevenDaySonnet, "주간(Sonnet)")
    return segments.isEmpty ? nil : segments.joined(separator: " · ")
}

/// One-line rate_limit summary. Snapshot windows win over event fields (TS parity).
public func formatRateLimitLine(_ ev: RateLimitInfo, usage: UsageResult? = nil) -> String {
    if let windows = formatUsageWindows(usage) {
        return "📊 사용량 한도 알림 · \(windows)"
    }

    var line = "📊 사용량 한도 알림"
    if let t = ev.rateLimitType { line += " · \(rateLimitTypeLabel(t))" }
    if let u = ev.utilization { line += " · 사용량 \(Int(u.rounded()))%" }
    if let r = ev.resetAt, let date = parseISODate(r) {
        // Event path: HH:mm only (TS toLocaleTimeString hour/minute, 24h).
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.dateFormat = "HH:mm"
        line += " · 리셋 \(fmt.string(from: date))"
    }
    return line
}

func parseISODate(_ s: String) -> Date? {
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

/// Compact token count (1234 → "1.2K", 2_000_000 → "2.0M"). TS `formatTokens`.
public func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    }
    if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000.0)
    }
    return String(count)
}

/// Human duration: >=60s → "1.5m", else "12.3s". TS `formatDuration`.
public func formatDuration(_ ms: Int) -> String {
    if ms >= 60_000 {
        return String(format: "%.1fm", Double(ms) / 60_000.0)
    }
    return String(format: "%.1fs", Double(ms) / 1000.0)
}

/// Done-line (TS `buildResultLine`). Korean labels match `i18n.ts` result.* keys.
/// Returns nil when no metric fields are present.
public func buildResultLine(_ usage: TurnUsage) -> String? {
    var parts: [String] = []
    if let cost = usage.costUsd {
        parts.append(String(format: "비용 $%.4f", cost))
    }
    if usage.tokensIn != nil || usage.tokensOut != nil {
        var tok: [String] = []
        if let tin = usage.tokensIn { tok.append("\(formatTokens(tin))↓") }
        if let tout = usage.tokensOut { tok.append("\(formatTokens(tout))↑") }
        parts.append("토큰 \(tok.joined(separator: " "))")
    }
    if let ms = usage.durationMs {
        parts.append("소요 \(formatDuration(ms))")
    }
    if parts.isEmpty { return nil }
    return "완료 · \(parts.joined(separator: " · "))"
}

/// Build TurnUsage from an AgentEvent.result payload (Claude sidecar).
public func turnUsage(fromResult costUsd: Double?, tokensIn: Int?, tokensOut: Int?, durationMs: Int?) -> TurnUsage? {
    let u = TurnUsage(costUsd: costUsd, tokensIn: tokensIn, tokensOut: tokensOut, durationMs: durationMs)
    return u.hasMetrics ? u : nil
}

/// Extract tokens from Codex `turn/completed` params (eventMapper.ts:109-128).
public func turnUsage(fromCodexCompleted params: JSONValue?) -> TurnUsage? {
    func tokens(from usage: JSONValue?) -> (Int?, Int?) {
        guard let usage else { return (nil, nil) }
        let tin = intField(usage, "inputTokens") ?? intField(usage, "input_tokens")
        let tout = intField(usage, "outputTokens") ?? intField(usage, "output_tokens")
        return (tin, tout)
    }
    var (tin, tout) = tokens(from: params?["usage"])
    if tin == nil && tout == nil {
        (tin, tout) = tokens(from: params?["turn"]?["usage"])
    }
    let u = TurnUsage(tokensIn: tin, tokensOut: tout)
    return u.hasMetrics ? u : nil
}

/// Extract cost/tokens from Grok `session/prompt` response (acpClient extractPromptResult).
public func turnUsage(fromGrokPromptResult result: JSONValue?) -> TurnUsage? {
    guard let result else { return nil }
    // Preferred: result._meta.usage.{costUsdTicks,inputTokens,outputTokens} (1 USD = 1e10 ticks).
    let meta = result["_meta"]
    let metaUsage = meta?["usage"]
    var costUsd: Double?
    var tin: Int?
    var tout: Int?
    if let ticks = metaUsage?["costUsdTicks"]?.numberValue, ticks.isFinite {
        costUsd = ticks / 1e10
    }
    tin = intField(metaUsage, "inputTokens")
    tout = intField(metaUsage, "outputTokens")
    // Legacy top-level usage {input_tokens,output_tokens,total_cost_usd}.
    let raw = result["usage"]
    if tin == nil { tin = intField(raw, "input_tokens") }
    if tout == nil { tout = intField(raw, "output_tokens") }
    if costUsd == nil,
       let c = raw?["total_cost_usd"]?.numberValue,
       raw?["cost_is_partial"]?.boolValue != true,
       raw?["usage_is_incomplete"]?.boolValue != true {
        costUsd = c
    }
    // Also accept already-lifted top-level fields if present.
    if costUsd == nil { costUsd = result["costUsd"]?.numberValue }
    if tin == nil { tin = intField(result, "tokensIn") }
    if tout == nil { tout = intField(result, "tokensOut") }
    let u = TurnUsage(costUsd: costUsd, tokensIn: tin, tokensOut: tout)
    return u.hasMetrics ? u : nil
}

private func intField(_ obj: JSONValue?, _ key: String) -> Int? {
    guard let n = obj?[key]?.numberValue else { return nil }
    return Int(n)
}
