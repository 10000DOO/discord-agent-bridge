import Foundation

// Pure usage/limits embed builder (TS `src/discord/renderers/usageEmbed.ts`).
// Returns a transport-agnostic spec; dab maps to DiscordBM Embed.

public struct UsageEmbedField: Sendable, Equatable {
    public var name: String
    public var value: String
    public var inline: Bool?

    public init(name: String, value: String, inline: Bool? = nil) {
        self.name = name
        self.value = value
        self.inline = inline
    }
}

public struct UsageEmbedSpec: Sendable, Equatable {
    public var title: String
    public var description: String?
    public var color: Int
    public var fields: [UsageEmbedField]
    public var footer: String?

    public init(
        title: String,
        description: String? = nil,
        color: Int,
        fields: [UsageEmbedField],
        footer: String? = nil
    ) {
        self.title = title
        self.description = description
        self.color = color
        self.fields = fields
        self.footer = footer
    }
}

public struct UsageSessionMeta: Sendable, Equatable {
    public var cwd: String?
    public var gitBranch: String?
    /// Wizard/profile model configuration, distinct from a model observed from the SDK.
    public var model: String?
    /// Explicit reasoning configuration; nil means the provider default is in effect.
    public var effort: String?
    public var permMode: String?
    /// Current backend conversation start; falls back to binding creation for old state.
    public var createdAt: String? // ISO

    public init(cwd: String? = nil, gitBranch: String? = nil, model: String? = nil, effort: String? = nil, permMode: String? = nil, createdAt: String? = nil) {
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.createdAt = createdAt
    }
}

public struct UsageEmbedExtras: Sendable, Equatable {
    public var meta: UsageSessionMeta?
    public var title: String?
    /// Only Claude/Custom SDK events carry a resolved model that may be shown as actual.
    public var observedModelIsActual: Bool
    /// Turn-local tool aggregates (W11-g slice4).
    public var tools: [TurnToolStat]
    /// Turn-local subagent runs (W11-g slice4).
    public var agents: [SubagentRun]

    public init(
        meta: UsageSessionMeta? = nil,
        title: String? = nil,
        observedModelIsActual: Bool = false,
        tools: [TurnToolStat] = [],
        agents: [SubagentRun] = []
    ) {
        self.meta = meta
        self.title = title
        self.observedModelIsActual = observedModelIsActual
        self.tools = tools
        self.agents = agents
    }
}

/// Resolve the renderer metadata from the persisted channel binding. The app layer supplies a
/// best-effort branch resolver because renderer code remains free of process execution.
public func usageSessionMeta(
    binding: PersistedSession?,
    fallbackCwd: String? = nil,
    fallbackPermMode: String? = nil,
    gitBranchForCwd: (String) -> String? = { _ in nil }
) -> UsageSessionMeta {
    let cwd = binding?.cwd.isEmpty == false ? binding?.cwd : fallbackCwd
    let branch = cwd.flatMap(gitBranchForCwd)
    return UsageSessionMeta(
        cwd: cwd,
        gitBranch: branch,
        model: binding?.model,
        effort: binding?.effort,
        permMode: binding?.permMode ?? fallbackPermMode,
        createdAt: binding?.contextGenerationStartedAt ?? binding?.createdAt
    )
}

/// Every backend posts exactly one terminal panel after answer/footer/mention. This compatibility
/// helper keeps the policy explicit for callers/tests that previously special-cased Claude.
public func postsUsageAtTurnEnd(for backend: Backend) -> Bool {
    true
}

// Discord embed hard limit for one field value.
private let fieldValueMax = 1024
// Top-N tool names shown on the tools line (claude-hud toolsMaxVisible analog).
private let toolsMaxVisible = 4
// Most recent subagent runs shown (Discord field is narrow — keep the tail short).
private let agentsMaxVisible = 5
// Per-run label budget so one long description cannot eat the whole field.
private let agentLabelMax = 100

/// "(12초)" / "(3분 12초)" duration suffix for a subagent run (TS formatRunDuration).
public func formatSubagentRunDuration(_ ms: Int) -> String {
    let totalSec = max(0, Int((Double(ms) / 1000.0).rounded()))
    if totalSec < 60 { return I18n.t("usage.duration.sec", ["s": "\(totalSec)"]) }
    return I18n.t("usage.duration.minSec", ["m": "\(totalSec / 60)", "s": "\(totalSec % 60)"])
}

/// "✅ Bash ×20 · ✅ Read ×3 · ❌ Edit ×1 · +N" — top names by count; ❌ when any failure.
public func buildToolsValue(_ tools: [TurnToolStat]) -> String? {
    let sorted = tools.filter { $0.count > 0 }.sorted { $0.count > $1.count }
    if sorted.isEmpty { return nil }
    var shown = sorted.prefix(toolsMaxVisible).map { s in
        "\(s.failed > 0 ? "❌" : "✅") \(s.name) ×\(s.count)"
    }
    if sorted.count > toolsMaxVisible {
        shown.append("+\(sorted.count - toolsMaxVisible)")
    }
    return shown.joined(separator: " · ")
}

/// "✅ developer: Fix model list (12초)" lines for the most recent runs, capped to field limit.
public func buildAgentsValue(_ agents: [SubagentRun]) -> String? {
    if agents.isEmpty { return nil }
    let tail = agents.suffix(agentsMaxVisible)
    let lines = tail.map { run -> String in
        let icon: String
        switch run.status {
        case .completed: icon = "✅"
        case .failed: icon = "❌"
        case .stopped: icon = "⏹️"
        }
        let text: String
        if run.type != nil || run.description != nil {
            text = [run.type, run.description].compactMap { $0 }.joined(separator: ": ")
        } else {
            text = run.summary
        }
        let clipped = text.count > agentLabelMax
            ? String(text.prefix(agentLabelMax - 1)) + "…"
            : text
        let duration = run.durationMs.map { " (\(formatSubagentRunDuration($0)))" } ?? ""
        return "\(icon) \(clipped)\(duration)"
    }
    let value = lines.joined(separator: "\n")
    if value.count > fieldValueMax {
        return String(value.prefix(fieldValueMax - 1)) + "…"
    }
    return value
}

private let barLen = 10
private let barEmpty = "⬜"

private func utilizationColor(_ maxUtil: Double) -> Int {
    if maxUtil >= 90 { return DiscordColors.stopped }
    if maxUtil >= 70 { return DiscordColors.streaming }
    return DiscordColors.idle
}

private func utilizationEmoji(_ utilization: Double) -> String {
    if utilization >= 90 { return "🔴" }
    if utilization >= 70 { return "🟡" }
    return "🟢"
}

private func barFilledEmoji(_ utilization: Double) -> String {
    if utilization >= 90 { return "🟥" }
    if utilization >= 70 { return "🟨" }
    return "🟩"
}

private func progressBar(_ utilization: Double) -> String {
    let clamped = max(0, min(100, utilization))
    let filled = Int((clamped / 100 * Double(barLen)).rounded())
    return String(repeating: barFilledEmoji(clamped), count: filled)
        + String(repeating: barEmpty, count: barLen - filled)
}

private func resetLine(_ limit: UsageLimit) -> String {
    guard let resetsAt = limit.resetsAt, let date = parseISODate(resetsAt) else { return "" }
    let unix = Int(date.timeIntervalSince1970)
    return "\n" + I18n.t("usage.resets", ["reset": "<t:\(unix):R>"])
}

private func limitField(label: String, limit: UsageLimit, inline: Bool? = nil) -> UsageEmbedField {
    UsageEmbedField(
        name: "\(utilizationEmoji(limit.utilization)) \(label)",
        value: "\(progressBar(limit.utilization)) **\(Int(limit.utilization.rounded()))%**\(resetLine(limit))",
        inline: inline
    )
}

private func formatElapsed(createdAt: String?, now: Date) -> String? {
    guard let createdAt, let started = parseISODate(createdAt) else { return nil }
    let nowMs = now.timeIntervalSince1970 * 1000
    let startMs = started.timeIntervalSince1970 * 1000
    guard startMs <= nowMs else { return nil }
    let totalMin = Int((nowMs - startMs) / 60_000)
    if totalMin < 60 { return I18n.t("usage.elapsed.min", ["m": "\(totalMin)"]) }
    let totalHours = totalMin / 60
    if totalHours < 24 { return I18n.t("usage.elapsed.hourMin", ["h": "\(totalHours)", "m": "\(totalMin % 60)"]) }
    return I18n.t("usage.elapsed.dayHour", ["d": "\(totalHours / 24)", "h": "\(totalHours % 24)"])
}

private func permLabel(_ mode: String) -> String {
    switch mode {
    case "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto":
        return I18n.t("perm.\(mode)")
    default: return mode
    }
}

private func buildDescription(
    ctx: ContextUsageInfo?,
    meta: UsageSessionMeta?,
    now: Date
) -> String? {
    var segments: [String] = []
    if let name = ctx?.modelDisplayName, !name.isEmpty { segments.append(name) }
    if let cwd = meta?.cwd, !cwd.isEmpty {
        let base = (cwd as NSString).lastPathComponent
        let branch = meta?.gitBranch.map { " git:(\($0))" } ?? ""
        segments.append("📁 \(base)\(branch)")
    }
    if let elapsed = formatElapsed(createdAt: meta?.createdAt, now: now) {
        segments.append("⏱️ \(elapsed)")
    }
    return segments.isEmpty ? nil : segments.joined(separator: " · ")
}

/// Build the usage embed. Nil when both usage and context are unavailable (TS parity); tools and
/// agents enrich an existing panel but never open one on their own.
public func buildUsageEmbed(
    usage: UsageResult?,
    ctxUsage: ContextUsageInfo?,
    extras: UsageEmbedExtras? = nil,
    now: Date = Date()
) -> UsageEmbedSpec? {
    let snap: UsageSnapshot? = {
        if case .snapshot(let s) = usage { return s }
        return nil
    }()
    let haveUsage = snap != nil
    let tools = extras?.tools ?? []
    let agents = extras?.agents ?? []
    // Grok may legitimately have neither account usage nor a known context window.
    // A bound session still needs its actual configuration shown.
    if !haveUsage && ctxUsage == nil && extras?.meta == nil { return nil }

    let meta = extras?.meta
    var fields: [UsageEmbedField] = []
    var maxUtil: Double = 0

    if let snap {
        if let five = snap.fiveHour {
            fields.append(limitField(label: I18n.t("usage.fiveHour"), limit: five))
            maxUtil = max(maxUtil, five.utilization)
        }
        if let week = snap.sevenDay {
            fields.append(limitField(label: I18n.t("usage.weekly"), limit: week))
            maxUtil = max(maxUtil, week.utilization)
        }
        if let opus = snap.sevenDayOpus {
            fields.append(limitField(label: I18n.t("usage.weeklyOpus"), limit: opus, inline: true))
            maxUtil = max(maxUtil, opus.utilization)
        }
        if let sonnet = snap.sevenDaySonnet {
            fields.append(limitField(label: I18n.t("usage.weeklySonnet"), limit: sonnet, inline: true))
            maxUtil = max(maxUtil, sonnet.utilization)
        }
    }

    if let ctx = ctxUsage {
        var clearHint = ""
        if let c = ctx.clearableTokens, c > 0 {
            clearHint = " · " + I18n.t("usage.clearHint", ["tokens": formatTokens(c)])
        }
        fields.append(UsageEmbedField(
            name: "\(utilizationEmoji(ctx.percentage)) \(I18n.t("usage.context"))",
            value: "\(progressBar(ctx.percentage)) **\(Int(ctx.percentage.rounded()))%**\(clearHint)"
        ))
        maxUtil = max(maxUtil, ctx.percentage)

        var composition: [String] = []
        if let m = ctx.memoryFileCount { composition.append("CLAUDE.md \(m)") }
        if let m = ctx.mcpServerCount { composition.append("MCP \(m)") }
        if !composition.isEmpty {
            fields.append(UsageEmbedField(name: "⚙️ \(I18n.t("usage.session"))", value: composition.joined(separator: " · "), inline: true))
        }
    }

    if let meta {
        // The binding stores an alias; name the concrete wire id it currently points at.
        let configuredModel = meta.model?.isEmpty == false
            ? modelDisplayText(meta.model!)
            : I18n.t("usage.model.auto")
        let effort = meta.effort?.isEmpty == false ? meta.effort! : I18n.t("usage.effort.default")
        let permission = permLabel(meta.permMode ?? "auto")
        fields.append(UsageEmbedField(
            name: "⚙️ \(I18n.t("usage.sessionConfig"))",
            value: "\(I18n.t("usage.model", ["model": configuredModel]))\n\(I18n.t("usage.effort", ["effort": effort]))\n\(I18n.t("usage.perm", ["perm": permission]))"
        ))
    }

    if let toolsValue = buildToolsValue(tools) {
        fields.append(UsageEmbedField(name: "🛠️ \(I18n.t("usage.tools"))", value: toolsValue, inline: true))
    }
    if let agentsValue = buildAgentsValue(agents) {
        fields.append(UsageEmbedField(name: "🤖 \(I18n.t("usage.agents"))", value: agentsValue))
    }

    if fields.isEmpty { return nil }

    var footerParts: [String] = []
    if extras?.observedModelIsActual == true, let model = ctxUsage?.model {
        footerParts.append(I18n.t("usage.actualModel", ["model": model]))
    }

    let isGrokWeeklyOnly =
        haveUsage
        && snap?.sevenDay != nil
        && snap?.fiveHour == nil
        && snap?.sevenDayOpus == nil
        && snap?.sevenDaySonnet == nil
    let title = extras?.title
        ?? (isGrokWeeklyOnly ? I18n.t("usage.title.grok") : I18n.t("usage.title"))
    let description = buildDescription(ctx: ctxUsage, meta: meta, now: now)

    return UsageEmbedSpec(
        title: title,
        description: description,
        color: utilizationColor(maxUtil),
        fields: fields,
        footer: footerParts.isEmpty ? nil : footerParts.joined(separator: " · ")
    )
}
