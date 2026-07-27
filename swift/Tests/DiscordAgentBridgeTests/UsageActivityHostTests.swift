import Testing
@testable import DiscordAgentBridge

// H10: mid-turn context_usage/rate_limit → immediate notify. Mirrors
// ToolActivityHostNotifierTests (CapabilitiesTests.swift) — fresh (non-shared) host instances so
// tests never touch UsageActivityHost.shared / pollute other suites.
@Suite("UsageActivityHost H10 mid-turn notifier")
struct UsageActivityHostTests {
    @Test func contextUsageFiresWhenUsagePanelOn() async {
        let recorder = UsageNotifierRecorder()
        let host = UsageActivityHost()
        await host.setCapabilities(channelId: "ch1", Capabilities(usagePanel: true))
        await host.setNotifyContext(channelId: "ch1", guildId: "g1", backend: .claude, permMode: "bypassPermissions")
        await host.setNotifier { channelId, guildId, backend, permMode, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, permMode: permMode, event: event)
        }
        let ctx = ContextUsageInfo(totalTokens: 10, maxTokens: 100, percentage: 10)
        await host.notify(channelId: "ch1", .contextUsage(ctx, tools: [TurnToolStat(name: "Bash", count: 1)], agents: []))
        #expect(await waitUntil { recorder.calls.count == 1 })
        let call = recorder.calls[0]
        #expect(call.channelId == "ch1")
        #expect(call.guildId == "g1")
        #expect(call.backend == .claude)
        #expect(call.permMode == "bypassPermissions")
        if case .contextUsage(let info, let tools, let agents) = call.event {
            #expect(info.totalTokens == 10)
            #expect(tools.first?.name == "Bash")
            #expect(agents.isEmpty)
        } else {
            Issue.record("expected .contextUsage")
        }
    }

    @Test func contextUsageSkippedWhenUsagePanelOff() async {
        let recorder = UsageNotifierRecorder()
        let host = UsageActivityHost()
        await host.setCapabilities(channelId: "ch1", Capabilities(usagePanel: false))
        await host.setNotifyContext(channelId: "ch1", guildId: "g1", backend: .claude, permMode: nil)
        await host.setNotifier { channelId, guildId, backend, permMode, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, permMode: permMode, event: event)
        }
        let ctx = ContextUsageInfo(totalTokens: 10, maxTokens: 100, percentage: 10)
        await host.notify(channelId: "ch1", .contextUsage(ctx, tools: [], agents: []))
        _ = await waitUntil(timeoutNs: 100_000_000, pollNs: 5_000_000) { recorder.calls.count > 0 }
        #expect(recorder.calls.isEmpty)
    }

    @Test func rateLimitFiresRegardlessOfUsagePanelCap() async {
        // TS RendererDispatcher.rateLimit is never capability-gated (renderers/index.ts:112-113) —
        // usagePanel:false must not suppress it.
        let recorder = UsageNotifierRecorder()
        let host = UsageActivityHost()
        await host.setCapabilities(channelId: "ch1", Capabilities(usagePanel: false))
        await host.setNotifyContext(channelId: "ch1", guildId: "g1", backend: .claude, permMode: nil)
        await host.setNotifier { channelId, guildId, backend, permMode, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, permMode: permMode, event: event)
        }
        await host.notify(channelId: "ch1", .rateLimit(RateLimitInfo(rateLimitType: "five_hour", utilization: 50)))
        #expect(await waitUntil { recorder.calls.count == 1 })
        if case .rateLimit(let info) = recorder.calls[0].event {
            #expect(info.utilization == 50)
        } else {
            Issue.record("expected .rateLimit")
        }
    }

    @Test func missingNotifyContextSkipsNotifier() async {
        let recorder = UsageNotifierRecorder()
        let host = UsageActivityHost()
        // No setNotifyContext call for "ch1" — notifier must not fire (no guildId to notify with).
        await host.setNotifier { channelId, guildId, backend, permMode, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, permMode: permMode, event: event)
        }
        await host.notify(channelId: "ch1", .rateLimit(RateLimitInfo(utilization: 10)))
        _ = await waitUntil(timeoutNs: 100_000_000, pollNs: 5_000_000) { recorder.calls.count > 0 }
        #expect(recorder.calls.isEmpty)
    }

    @Test func disposeClearsContextAndCaps() async {
        let recorder = UsageNotifierRecorder()
        let host = UsageActivityHost()
        await host.setCapabilities(channelId: "ch1", Capabilities(usagePanel: true))
        await host.setNotifyContext(channelId: "ch1", guildId: "g1", backend: .claude, permMode: nil)
        await host.setNotifier { channelId, guildId, backend, permMode, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, permMode: permMode, event: event)
        }
        await host.dispose(channelId: "ch1")
        await host.notify(channelId: "ch1", .rateLimit(RateLimitInfo(utilization: 10)))
        _ = await waitUntil(timeoutNs: 100_000_000, pollNs: 5_000_000) { recorder.calls.count > 0 }
        #expect(recorder.calls.isEmpty)
    }
}

private final class UsageNotifierRecorder: @unchecked Sendable {
    struct Call {
        var channelId: String
        var guildId: String
        var backend: Backend
        var permMode: String?
        var event: UsageActivityEvent
    }
    private let box = LockedBox<[Call]>([])

    var calls: [Call] { box.withLock { $0 } }

    func record(channelId: String, guildId: String, backend: Backend, permMode: String?, event: UsageActivityEvent) {
        box.withLock { $0.append(Call(channelId: channelId, guildId: guildId, backend: backend, permMode: permMode, event: event)) }
    }
}
