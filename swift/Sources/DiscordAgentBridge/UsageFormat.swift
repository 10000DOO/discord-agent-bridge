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

/// Bridge `runTurn` return: reply text + optional usage for the done-line footer.
public struct TurnResult: Sendable, Equatable {
    public var text: String
    public var usage: TurnUsage?

    public init(text: String, usage: TurnUsage? = nil) {
        self.text = text
        self.usage = usage
    }
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
