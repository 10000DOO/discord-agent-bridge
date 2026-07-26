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

    @Test func toolsFieldTop4WithFailureAndOverflow() {
        let tools = [
            TurnToolStat(name: "Bash", count: 20, failed: 0),
            TurnToolStat(name: "Read", count: 3, failed: 0),
            TurnToolStat(name: "Edit", count: 1, failed: 1),
            TurnToolStat(name: "Grep", count: 2, failed: 0),
            TurnToolStat(name: "Glob", count: 1, failed: 0),
        ]
        let embed = buildUsageEmbed(
            usage: nil,
            ctxUsage: ctx,
            extras: UsageEmbedExtras(tools: tools)
        )
        let field = embed?.fields.first { $0.name == "🛠️ 이번 턴 도구" }
        #expect(field?.value == "✅ Bash ×20 · ✅ Read ×3 · ✅ Grep ×2 · ❌ Edit ×1 · +1")
        #expect(
            (buildUsageEmbed(usage: nil, ctxUsage: ctx, extras: UsageEmbedExtras(tools: []))?.fields.map(\.name) ?? [])
                .contains("🛠️ 이번 턴 도구") == false
        )
    }

    @Test func agentsFieldWithStatusIconTypeAndDuration() {
        let agents = [
            SubagentRun(
                status: .completed,
                summary: "long summary",
                type: "developer",
                description: "Fix model list",
                durationMs: 12_000
            ),
            SubagentRun(status: .failed, summary: "it broke"),
        ]
        let embed = buildUsageEmbed(
            usage: nil,
            ctxUsage: ctx,
            extras: UsageEmbedExtras(agents: agents)
        )
        let field = embed?.fields.first { $0.name == "🤖 서브에이전트" }
        #expect(field?.value == "✅ developer: Fix model list (12초)\n❌ it broke")
    }

    @Test func agentsFieldCapsAt1024() {
        let agents = (0..<5).map { i in
            SubagentRun(status: .completed, summary: "run-\(i) " + String(repeating: "x", count: 400))
        }
        let embed = buildUsageEmbed(
            usage: nil,
            ctxUsage: ctx,
            extras: UsageEmbedExtras(agents: agents)
        )
        let field = embed?.fields.first { $0.name == "🤖 서브에이전트" }
        #expect(field != nil)
        #expect((field?.value.count ?? 0) <= 1024)
    }

    @Test func toolsOnlyPanelWithoutUsageOrContext() {
        let tools = [TurnToolStat(name: "Read", count: 1)]
        let embed = buildUsageEmbed(
            usage: nil,
            ctxUsage: nil,
            extras: UsageEmbedExtras(tools: tools)
        )
        #expect(embed != nil)
        #expect(embed?.fields.map(\.name) == ["🛠️ 이번 턴 도구"])
        #expect(embed?.fields.first?.value == "✅ Read ×1")
    }
}

@Suite("TurnToolStatsAggregator pure")
struct TurnToolStatsAggregatorTests {
    @Test func countsToolsFailuresAndSubagentPairing() {
        var agg = TurnToolStatsAggregator()
        agg.note(.toolUse(id: "t1", name: "Bash", input: .object([:]), parentToolUseId: nil))
        agg.note(.toolUse(id: "t2", name: "Bash", input: .object([:]), parentToolUseId: nil))
        agg.note(.toolResult(id: "t2", ok: false, content: "boom", parentToolUseId: nil))
        agg.note(.toolUse(
            id: "t3",
            name: "Task",
            input: .object([
                "subagent_type": .string("developer"),
                "description": .string("Fix bug"),
            ]),
            parentToolUseId: nil
        ))
        agg.note(.subagentResult(
            taskId: "task-1",
            status: .completed,
            summary: "ok",
            toolUseId: "t3",
            durationMs: 12_000,
            toolUses: nil
        ))
        let tools = Dictionary(uniqueKeysWithValues: agg.toolsSnapshot().map { ($0.name, $0) })
        #expect(tools["Bash"]?.count == 2)
        #expect(tools["Bash"]?.failed == 1)
        #expect(tools["Task"]?.count == 1)
        #expect(agg.totalToolCount == 3)
        #expect(agg.agentsSnapshot().count == 1)
        #expect(agg.agentsSnapshot()[0].type == "developer")
        #expect(agg.agentsSnapshot()[0].description == "Fix bug")
        #expect(buildToolsValue(agg.toolsSnapshot()) == "❌ Bash ×2 · ✅ Task ×1")
        #expect(buildAgentsValue(agg.agentsSnapshot()) == "✅ developer: Fix bug (12초)")

        agg.reset()
        #expect(agg.toolsSnapshot().isEmpty)
        #expect(agg.agentsSnapshot().isEmpty)
        #expect(agg.totalToolCount == 0)
    }

    @Test func subagentRunDurationFormatting() {
        #expect(DiscordAgentBridge.formatSubagentRunDuration(0) == "0초")
        #expect(DiscordAgentBridge.formatSubagentRunDuration(12_000) == "12초")
        #expect(DiscordAgentBridge.formatSubagentRunDuration(72_000) == "1분 12초")
    }
}
