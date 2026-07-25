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
    public var permMode: String?
    public var createdAt: String? // ISO

    public init(cwd: String? = nil, gitBranch: String? = nil, permMode: String? = nil, createdAt: String? = nil) {
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.permMode = permMode
        self.createdAt = createdAt
    }
}

public struct UsageEmbedExtras: Sendable, Equatable {
    public var meta: UsageSessionMeta?
    public var title: String?

    public init(meta: UsageSessionMeta? = nil, title: String? = nil) {
        self.meta = meta
        self.title = title
    }
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
    return "\n초기화 <t:\(unix):R>"
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
    if totalMin < 60 { return "\(totalMin)분" }
    let totalHours = totalMin / 60
    if totalHours < 24 { return "\(totalHours)시간 \(totalMin % 60)분" }
    return "\(totalHours / 24)일 \(totalHours % 24)시간"
}

private func permLabel(_ mode: String) -> String {
    switch mode {
    case "default": return "기본"
    case "acceptEdits": return "편집 자동 승인"
    case "bypassPermissions": return "전체 자동 승인 (⚠️ 위험)"
    case "plan": return "플랜"
    case "dontAsk": return "묻지 않음"
    case "auto": return "자동"
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

/// Build the usage embed. Nil when nothing should be shown (unavailable AND no context).
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
    if !haveUsage && ctxUsage == nil { return nil }

    let meta = extras?.meta
    var fields: [UsageEmbedField] = []
    var maxUtil: Double = 0

    if let snap {
        if let five = snap.fiveHour {
            fields.append(limitField(label: "5시간", limit: five))
            maxUtil = max(maxUtil, five.utilization)
        }
        if let week = snap.sevenDay {
            fields.append(limitField(label: "주간", limit: week))
            maxUtil = max(maxUtil, week.utilization)
        }
        if let opus = snap.sevenDayOpus {
            fields.append(limitField(label: "주간 (Opus)", limit: opus, inline: true))
            maxUtil = max(maxUtil, opus.utilization)
        }
        if let sonnet = snap.sevenDaySonnet {
            fields.append(limitField(label: "주간 (Sonnet)", limit: sonnet, inline: true))
            maxUtil = max(maxUtil, sonnet.utilization)
        }
    }

    if let ctx = ctxUsage {
        var clearHint = ""
        if let c = ctx.clearableTokens, c > 0 {
            clearHint = " · /clear 시 ~\(formatTokens(c)) 토큰 절약"
        }
        fields.append(UsageEmbedField(
            name: "\(utilizationEmoji(ctx.percentage)) 컨텍스트",
            value: "\(progressBar(ctx.percentage)) **\(Int(ctx.percentage.rounded()))%**\(clearHint)"
        ))
        maxUtil = max(maxUtil, ctx.percentage)

        var composition: [String] = []
        if let m = ctx.memoryFileCount { composition.append("CLAUDE.md \(m)") }
        if let m = ctx.mcpServerCount { composition.append("MCP \(m)") }
        if !composition.isEmpty {
            fields.append(UsageEmbedField(name: "⚙️ 세션 구성", value: composition.joined(separator: " · "), inline: true))
        }
    }

    if fields.isEmpty { return nil }

    var footerParts: [String] = []
    if let perm = meta?.permMode {
        footerParts.append("권한: \(permLabel(perm))")
    }
    if let model = ctxUsage?.model {
        footerParts.append(model)
    }

    let isGrokWeeklyOnly =
        haveUsage
        && snap?.sevenDay != nil
        && snap?.fiveHour == nil
        && snap?.sevenDayOpus == nil
        && snap?.sevenDaySonnet == nil
    let title = extras?.title ?? (isGrokWeeklyOnly ? "Grok 사용량" : "Claude 사용량")
    let description = buildDescription(ctx: ctxUsage, meta: meta, now: now)

    return UsageEmbedSpec(
        title: title,
        description: description,
        color: utilizationColor(maxUtil),
        fields: fields,
        footer: footerParts.isEmpty ? nil : footerParts.joined(separator: " · ")
    )
}
