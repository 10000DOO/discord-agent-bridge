import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("mentionOnComplete / rateLimit / context pure formatters")
struct MentionAndRateLimitFormatTests {
    @Test func mentionOnCompleteSkipsEmptyOwner() {
        #expect(mentionOnCompleteContent(ownerId: "owner-9") == "<@owner-9>")
        #expect(mentionOnCompleteContent(ownerId: "") == nil)
    }

    @Test func rateLimitTypeLabelMapsKnownAndUnknown() {
        #expect(rateLimitTypeLabel("five_hour") == "5시간 한도")
        #expect(rateLimitTypeLabel("seven_day") == "주간 한도")
        #expect(rateLimitTypeLabel("seven_day_opus") == "주간 한도 (Opus)")
        #expect(rateLimitTypeLabel("seven_day_sonnet") == "주간 한도 (Sonnet)")
        #expect(rateLimitTypeLabel("overage") == "추가 사용량")
        #expect(rateLimitTypeLabel("moon_phase") == "moon_phase")
    }

    @Test func formatUsageWindowsNullAndEmpty() {
        #expect(formatUsageWindows(nil) == nil)
        #expect(formatUsageWindows(.unavailable(UsageUnavailable(reason: .noCredentials))) == nil)
        #expect(formatUsageWindows(snapshot: UsageSnapshot(fetchedAt: 0)) == nil)
    }

    @Test func formatUsageWindowsRendersWindows() {
        let snap = UsageSnapshot(
            fiveHour: UsageLimit(utilization: 26),
            sevenDayOpus: UsageLimit(utilization: 12.6),
            sevenDaySonnet: UsageLimit(utilization: 0),
            fetchedAt: 0
        )
        #expect(formatUsageWindows(snapshot: snap) == "5시간 26% · 주간(Opus) 13% · 주간(Sonnet) 0%")
    }

    @Test func formatRateLimitLineUsesSnapshotWhenPresent() {
        let snap = UsageSnapshot(sevenDay: UsageLimit(utilization: 41), fetchedAt: 0)
        let line = formatRateLimitLine(
            RateLimitInfo(rateLimitType: "seven_day"),
            usage: .snapshot(snap)
        )
        #expect(line == "📊 사용량 한도 알림 · 주간 41%")
        #expect(!line.contains("한도 ·")) // event label ignored on snapshot path
    }

    @Test func formatRateLimitLineEventFallback() {
        #expect(
            formatRateLimitLine(RateLimitInfo(rateLimitType: "five_hour"), usage: nil)
                == "📊 사용량 한도 알림 · 5시간 한도"
        )
        #expect(
            formatRateLimitLine(
                RateLimitInfo(rateLimitType: "five_hour"),
                usage: .unavailable(UsageUnavailable(reason: .noCredentials))
            ) == "📊 사용량 한도 알림 · 5시간 한도"
        )
        let withUtil = formatRateLimitLine(RateLimitInfo(utilization: 42.7))
        #expect(withUtil.contains("사용량 43%"))
    }

    @Test func formatContextUsageLine() {
        let ctx = ContextUsageInfo(
            totalTokens: 1500,
            maxTokens: 100_000,
            percentage: 30.4,
            model: "claude-x",
            modelDisplayName: "Claude X"
        )
        #expect(DiscordAgentBridge.formatContextUsageLine(ctx) == "📊 컨텍스트 30% · 1.5K/100.0K · Claude X")
    }
}

@Suite("buildUsageEmbed pure")
struct UsageEmbedTests {
    let ctx = ContextUsageInfo(totalTokens: 30, maxTokens: 100, percentage: 30)

    @Test func rendersNothingWhenUnavailableAndNoContext() {
        #expect(buildUsageEmbed(usage: .unavailable(UsageUnavailable(reason: .noCredentials)), ctxUsage: nil) == nil)
        #expect(buildUsageEmbed(usage: nil, ctxUsage: nil) == nil)
        #expect(buildUsageEmbed(usage: codexUsageUnavailable(), ctxUsage: nil) == nil)
    }

    @Test func rendersSnapshotAndContextFields() {
        let snap = UsageSnapshot(
            fiveHour: UsageLimit(utilization: 42, resetsAt: "2026-07-01T12:00:00Z"),
            sevenDay: UsageLimit(utilization: 10),
            sevenDayOpus: UsageLimit(utilization: 80),
            sevenDaySonnet: UsageLimit(utilization: 5),
            fetchedAt: 1000
        )
        let embed = buildUsageEmbed(usage: .snapshot(snap), ctxUsage: ctx)
        let names = embed?.fields.map(\.name) ?? []
        #expect(names.contains("🟢 5시간"))
        #expect(names.contains("🟢 주간"))
        #expect(names.contains("🟡 주간 (Opus)"))
        #expect(names.contains("🟢 컨텍스트"))
        // Highest util 80 → yellow band
        #expect(embed?.color == DiscordColors.streaming)
    }

    @Test func progressBarEmojiByUtilization() {
        let snap = UsageSnapshot(
            fiveHour: UsageLimit(utilization: 30),
            sevenDay: UsageLimit(utilization: 72),
            fetchedAt: 1000
        )
        let embed = buildUsageEmbed(
            usage: .snapshot(snap),
            ctxUsage: ContextUsageInfo(totalTokens: 1, maxTokens: 1, percentage: 95)
        )
        let five = embed?.fields.first { $0.name == "🟢 5시간" }
        #expect(five?.value.contains("🟩") == true)
        #expect(five?.value.contains("⬜") == true)
        let weekly = embed?.fields.first { $0.name == "🟡 주간" }
        #expect(weekly?.value.contains("🟨") == true)
        let context = embed?.fields.first { $0.name == "🔴 컨텍스트" }
        #expect(context?.value.contains("🟥") == true)
    }

    @Test func contextOnlyPanel() {
        let embed = buildUsageEmbed(
            usage: .unavailable(UsageUnavailable(reason: .noCredentials)),
            ctxUsage: ctx
        )
        #expect(embed != nil)
        #expect(embed?.fields.map(\.name) == ["🟢 컨텍스트"])
    }

    @Test func footerAbsorbsModelAndPerm() {
        let withModel = ContextUsageInfo(
            totalTokens: 30, maxTokens: 100, percentage: 30, model: "claude-fable-5"
        )
        let embed = buildUsageEmbed(
            usage: nil,
            ctxUsage: withModel,
            extras: UsageEmbedExtras(meta: UsageSessionMeta(permMode: "bypassPermissions"))
        )
        #expect(embed?.footer == "권한: 전체 자동 승인 (⚠️ 위험) · claude-fable-5")
    }

    @Test func descriptionFromDisplayNameAndCwd() {
        let withName = ContextUsageInfo(
            totalTokens: 30, maxTokens: 100, percentage: 30, modelDisplayName: "Claude Fable 5"
        )
        let embed = buildUsageEmbed(
            usage: nil,
            ctxUsage: withName,
            extras: UsageEmbedExtras(
                meta: UsageSessionMeta(cwd: "/Volumes/src/discord-agent-bridge", gitBranch: "master")
            )
        )
        #expect(embed?.description == "Claude Fable 5 · 📁 discord-agent-bridge git:(master)")
    }

    @Test func customTitleWins() {
        let snap = UsageSnapshot(sevenDay: UsageLimit(utilization: 10), fetchedAt: 1)
        let embed = buildUsageEmbed(
            usage: .snapshot(snap),
            ctxUsage: nil,
            extras: UsageEmbedExtras(title: "Codex 사용량")
        )
        #expect(embed?.title == "Codex 사용량")
    }

    @Test func weeklyOnlyDefaultsToGrokTitle() {
        let snap = UsageSnapshot(sevenDay: UsageLimit(utilization: 10), fetchedAt: 1)
        let embed = buildUsageEmbed(usage: .snapshot(snap), ctxUsage: nil)
        #expect(embed?.title == "Grok 사용량")
    }
}
