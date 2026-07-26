import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("buildStatusEmbed")
struct StatusEmbedTests {
    @Test func rendersModePermCwdSession() {
        let embed = buildStatusEmbed(SessionStatus(
            mode: "claude",
            cwd: "/ws",
            sessionId: "sess-1",
            permMode: "default",
            usagePanel: true
        ))
        let values = embed.fields.map(\.value)
        #expect(values.contains("claude"))
        #expect(values.contains("`/ws`"))
        #expect(values.contains("`sess-1`"))
        #expect(embed.footer == nil)
        #expect(embed.title == "세션 상태")
        #expect(embed.color == DiscordColors.idle)
    }

    @Test func usagePanelFalseFooterAndNullSession() {
        let embed = buildStatusEmbed(SessionStatus(
            mode: "codex",
            cwd: "/ws",
            sessionId: nil,
            permMode: "plan",
            usagePanel: false
        ))
        #expect(embed.footer == "사용량/한도 정보 없음 (Codex CLI 제한)")
        #expect(embed.fields.contains { $0.value == "`—`" })
        // TS mode defaults: all backends expose usagePanel (context % / tools HUD).
        #expect(backendSupportsUsagePanel(.codex))
        #expect(backendSupportsUsagePanel(.claude))
        #expect(backendSupportsUsagePanel(.grok))
    }
}

@Suite("resolveNotifications / formatNotification")
struct NotifierPureTests {
    @Test func defaultsForAbsentBlock() {
        let server = ServerConfig(guildId: "g1")
        let r = resolveNotifications(server)
        #expect(r.enabled == true)
        #expect(r.channelId == nil)
        #expect(r.events == ResolvedNotificationEvents(result: true, error: true, toolUse: false))
    }

    @Test func fallsBackToStatusChannel() {
        let server = ServerConfig(
            guildId: "g1",
            channels: ServerChannels(
                categoryId: "a", controlChannelId: "b", sessionsCategoryId: "c", statusChannelId: "status-1"
            )
        )
        #expect(resolveNotifications(server).channelId == "status-1")
    }

    @Test func explicitChannelIdWins() {
        let server = ServerConfig(
            guildId: "g1",
            channels: ServerChannels(
                categoryId: "a", controlChannelId: "b", sessionsCategoryId: "c", statusChannelId: "status-1"
            ),
            notifications: NotificationsSection(channelId: "override-2")
        )
        #expect(resolveNotifications(server).channelId == "override-2")
    }

    @Test func honorsEnabledFalseAndFlags() {
        let server = ServerConfig(
            guildId: "g1",
            notifications: NotificationsSection(
                enabled: false,
                events: NotificationEvents(result: nil, error: false, toolUse: true)
            )
        )
        let r = resolveNotifications(server)
        #expect(r.enabled == false)
        #expect(r.events == ResolvedNotificationEvents(result: true, error: false, toolUse: true))
    }

    @Test func nullServerDefaults() {
        let r = resolveNotifications(nil)
        #expect(r.enabled == true)
        #expect(r.channelId == nil)
        #expect(r.events.toolUse == false)
    }

    private let allOn = ResolvedNotificationEvents(result: true, error: true, toolUse: true)

    @Test func formatResultBareAndWithMetrics() {
        #expect(
            formatNotification(.result(text: nil, costUsd: nil, tokensIn: nil, tokensOut: nil, durationMs: nil), sessionChannelId: "sess-1", events: allOn)
                == "✅ <#sess-1> 완료"
        )
        #expect(
            formatNotification(
                .result(text: nil, costUsd: 0.03, tokensIn: 10, tokensOut: 20, durationMs: 1500),
                sessionChannelId: "sess-1",
                events: allOn
            ) == "✅ <#sess-1> 완료 · 10/20 tok · 1500ms · $0.03"
        )
        // Only one of in/out → omit token segment.
        #expect(
            formatNotification(
                .result(text: nil, costUsd: nil, tokensIn: 10, tokensOut: nil, durationMs: 500),
                sessionChannelId: "sess-1",
                events: allOn
            ) == "✅ <#sess-1> 완료 · 500ms"
        )
    }

    @Test func formatErrorAndCap() {
        #expect(
            formatNotification(.error(message: "boom", retryable: true), sessionChannelId: "sess-1", events: allOn)
                == "❌ <#sess-1> 에러: boom"
        )
        let line = formatNotification(
            .error(message: String(repeating: "x", count: 3000), retryable: true),
            sessionChannelId: "sess-1",
            events: allOn
        )!
        #expect(line.count < 2000)
        #expect(line.hasPrefix("❌ <#sess-1> 에러: "))
        #expect(line.hasSuffix(String(repeating: "x", count: 500)))
    }

    @Test func formatToolUseFiltered() {
        #expect(
            formatNotification(
                .toolUse(id: "1", name: "Bash", input: .null, parentToolUseId: nil),
                sessionChannelId: "sess-1",
                events: allOn
            ) == "🔧 <#sess-1> Bash"
        )
        let off = ResolvedNotificationEvents(result: true, error: true, toolUse: false)
        #expect(
            formatNotification(
                .toolUse(id: "1", name: "Bash", input: .null, parentToolUseId: nil),
                sessionChannelId: "sess-1",
                events: off
            ) == nil
        )
    }

    @Test func formatRateLimitEventFallback() {
        let line = formatNotification(
            .rateLimit(resetAt: nil, rateLimitType: "five_hour", utilization: 87),
            sessionChannelId: "sess-1",
            events: allOn
        )
        #expect(line == "📊 <#sess-1> 사용량 한도 · 5시간 한도 · 사용량 87%")
    }

    @Test func sessionNotifierPosts() async {
        let sent = LockedBox<[String]>([])
        let sink = NotificationSink { content in
            sent.withLock { $0.append(content) }
        }
        let n = SessionNotifier(
            statusChannel: sink,
            sessionChannelId: "ch-1",
            events: allOn
        )
        await n.notify(.result(text: "ok", costUsd: nil, tokensIn: nil, tokensOut: nil, durationMs: nil))
        await n.notify(.error(message: "e", retryable: false))
        // filtered off
        let n2 = SessionNotifier(
            statusChannel: sink,
            sessionChannelId: "ch-1",
            events: ResolvedNotificationEvents(result: false, error: false, toolUse: false)
        )
        await n2.notify(.result(text: nil, costUsd: nil, tokensIn: nil, tokensOut: nil, durationMs: nil))
        let copy = sent.withLock { $0 }
        #expect(copy.count == 2)
        #expect(copy[0].contains("완료"))
        #expect(copy[1].contains("에러"))
    }
}
