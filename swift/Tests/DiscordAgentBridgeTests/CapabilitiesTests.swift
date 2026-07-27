import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("defaultCapabilities / resolveCapabilities")
struct CapabilitiesResolveTests {
    @Test func backendDefaultsMatchTSModes() {
        for b in Backend.allCases {
            let c = defaultCapabilities(for: b)
            #expect(c.streaming)
            #expect(c.toolThreads)
            #expect(c.fileDiff)
            #expect(c.usagePanel)
        }
        #expect(backendSupportsUsagePanel(.codex))
        #expect(backendSupportsUsagePanel(.claude))
    }

    @Test func globalPartialOverridesDefaults() {
        let c = resolveCapabilities(
            backend: .claude,
            global: CapabilitiesPartial(toolThreads: false, usagePanel: false)
        )
        #expect(c.streaming)
        #expect(!c.toolThreads)
        #expect(c.fileDiff)
        #expect(!c.usagePanel)
    }

    @Test func serverOverridesGlobal() {
        let c = resolveCapabilities(
            backend: .grok,
            global: CapabilitiesPartial(fileDiff: false, usagePanel: false),
            server: CapabilitiesPartial(fileDiff: true)
        )
        #expect(c.fileDiff)
        #expect(!c.usagePanel)
    }

    @Test func envOverridesServer() {
        let c = resolveCapabilities(
            backend: .codex,
            global: CapabilitiesPartial(toolThreads: true),
            server: CapabilitiesPartial(streaming: true, toolThreads: true),
            envCaps: CapabilitiesPartial(streaming: false, toolThreads: false)
        )
        #expect(!c.toolThreads)
        #expect(!c.streaming)
        #expect(c.fileDiff)
        #expect(c.usagePanel)
    }

    @Test func envMapUsesDAB_CAPS() {
        let c = resolveCapabilities(
            backend: .claude,
            env: ["DAB_CAPS": "toolThreads=false,fileDiff=0,usagePanel=yes"]
        )
        #expect(!c.toolThreads)
        #expect(!c.fileDiff)
        #expect(c.usagePanel)
        #expect(c.streaming)
    }
}

@Suite("parseCapabilitiesEnv")
struct CapabilitiesEnvParseTests {
    @Test func keyValuePairs() {
        let p = parseCapabilitiesEnv("toolThreads=false, fileDiff=1, streaming=off")
        #expect(p?.toolThreads == false)
        #expect(p?.fileDiff == true)
        #expect(p?.streaming == false)
        #expect(p?.usagePanel == nil)
    }

    @Test func jsonObject() {
        let p = parseCapabilitiesEnv(#"{"usagePanel":false,"toolThreads":true}"#)
        #expect(p?.usagePanel == false)
        #expect(p?.toolThreads == true)
        #expect(p?.fileDiff == nil)
    }

    @Test func emptyAndJunk() {
        #expect(parseCapabilitiesEnv(nil) == nil)
        #expect(parseCapabilitiesEnv("") == nil)
        #expect(parseCapabilitiesEnv("   ") == nil)
        #expect(parseCapabilitiesEnv("not-a-pair") == nil)
        #expect(parseCapabilitiesEnv("toolThreads=maybe") == nil)
    }

    @Test func colonSeparatorAndCaseInsensitiveKeys() {
        let p = parseCapabilitiesEnv("UsagePanel:no,FILEDIFF=true")
        #expect(p?.usagePanel == false)
        #expect(p?.fileDiff == true)
    }
}

@Suite("ToolActivityHost capability gating")
struct ToolActivityHostCapsTests {
    @Test func toolThreadsOffSkipsThreadPosts() async {
        let posts = FakePosts()
        let host = ToolActivityHost()
        await host.setChannelFactory { _ in posts.channel() }
        await host.setCapabilities(
            channelId: "ch1",
            Capabilities(toolThreads: false, fileDiff: false)
        )
        await host.handle(
            channelId: "ch1",
            event: .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        )
        #expect(posts.createCount == 0)
        #expect(posts.posts.isEmpty)
    }

    @Test func fileDiffOnlyStillPostsDiff() async {
        let posts = FakePosts()
        let host = ToolActivityHost()
        await host.setChannelFactory { _ in posts.channel() }
        await host.setCapabilities(
            channelId: "ch1",
            Capabilities(toolThreads: false, fileDiff: true)
        )
        let input = JSONValue.object([
            "file_path": .string("/a.swift"),
            "old_string": .string("a"),
            "new_string": .string("b"),
        ])
        await host.handle(
            channelId: "ch1",
            event: .toolUse(id: "e1", name: "Edit", input: input, parentToolUseId: nil)
        )
        await host.handle(
            channelId: "ch1",
            event: .toolResult(id: "e1", ok: true, content: "ok", parentToolUseId: nil)
        )
        // Diff posts into a work thread (registry still opens a thread for the message).
        #expect(posts.createCount >= 1)
        #expect(posts.posts.contains { $0.content.contains("/a.swift") || $0.content.contains("+ b") || $0.content.contains("- a") })
    }

    @Test func toolThreadsOnlySkipsDiffBody() async {
        let posts = FakePosts()
        let host = ToolActivityHost()
        await host.setChannelFactory { _ in posts.channel() }
        await host.setCapabilities(
            channelId: "ch1",
            Capabilities(toolThreads: true, fileDiff: false)
        )
        let input = JSONValue.object([
            "file_path": .string("/a.swift"),
            "old_string": .string("old"),
            "new_string": .string("new"),
        ])
        await host.handle(
            channelId: "ch1",
            event: .toolUse(id: "e1", name: "Edit", input: input, parentToolUseId: nil)
        )
        await host.handle(
            channelId: "ch1",
            event: .toolResult(id: "e1", ok: true, content: "ok", parentToolUseId: nil)
        )
        // Tool thread posts tool name activity; diff body (--- path / ± lines) should be absent.
        #expect(posts.createCount >= 1)
        let joined = posts.posts.map(\.content).joined(separator: "\n")
        #expect(!joined.contains("--- /a.swift"))
    }
}

@Suite("ToolActivityHost C15 tool_use notifier")
struct ToolActivityHostNotifierTests {
    @Test func toolUseFiresNotifierIndependentOfCaps() async {
        let posts = FakePosts()
        let recorder = NotifierRecorder()
        let host = ToolActivityHost()
        await host.setChannelFactory { _ in posts.channel() }
        // Both render caps off — the notifier must still fire (TS SessionNotifier is a
        // separate subscription from RendererDispatcher, not gated by toolThreads/fileDiff).
        await host.setCapabilities(channelId: "ch1", Capabilities(toolThreads: false, fileDiff: false))
        await host.setNotifyContext(channelId: "ch1", guildId: "g1", backend: .codex)
        await host.setNotifier { channelId, guildId, backend, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, event: event)
        }
        await host.handle(
            channelId: "ch1",
            event: .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        )
        #expect(await waitUntil { recorder.calls.count == 1 })
        #expect(recorder.calls.first?.channelId == "ch1")
        #expect(recorder.calls.first?.guildId == "g1")
        #expect(recorder.calls.first?.backend == .codex)
        // Render caps still off → no thread posts (the two concerns stay independent).
        #expect(posts.createCount == 0)
    }

    @Test func toolResultDoesNotFireNotifier() async {
        let recorder = NotifierRecorder()
        let host = ToolActivityHost()
        await host.setNotifyContext(channelId: "ch1", guildId: "g1", backend: .claude)
        await host.setNotifier { channelId, guildId, backend, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, event: event)
        }
        await host.handle(
            channelId: "ch1",
            event: .toolResult(id: "t1", ok: true, content: "ok", parentToolUseId: nil)
        )
        // Give the (absent) fire-and-forget Task a chance to run before asserting it never did.
        _ = await waitUntil(timeoutNs: 100_000_000, pollNs: 5_000_000) { recorder.calls.count > 0 }
        #expect(recorder.calls.isEmpty)
    }

    @Test func missingNotifyContextSkipsNotifier() async {
        let recorder = NotifierRecorder()
        let host = ToolActivityHost()
        // No setNotifyContext call for "ch1" — notifier must not fire (no guildId to notify with).
        await host.setNotifier { channelId, guildId, backend, event in
            recorder.record(channelId: channelId, guildId: guildId, backend: backend, event: event)
        }
        await host.handle(
            channelId: "ch1",
            event: .toolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        )
        _ = await waitUntil(timeoutNs: 100_000_000, pollNs: 5_000_000) { recorder.calls.count > 0 }
        #expect(recorder.calls.isEmpty)
    }
}

private final class NotifierRecorder: @unchecked Sendable {
    struct Call {
        var channelId: String
        var guildId: String
        var backend: Backend
        var event: AgentEvent
    }
    private let box = LockedBox<[Call]>([])

    var calls: [Call] { box.withLock { $0 } }

    func record(channelId: String, guildId: String, backend: Backend, event: AgentEvent) {
        box.withLock { $0.append(Call(channelId: channelId, guildId: guildId, backend: backend, event: event)) }
    }
}

// MARK: - Local fake (mirrors ToolThreadAndDiffTests)

private final class FakePosts: @unchecked Sendable {
    private struct State {
        var posts: [(threadName: String, content: String)] = []
        var names: [String] = []
        var creates = 0
    }
    private let box = LockedBox(State())

    var posts: [(threadName: String, content: String)] {
        box.withLock { $0.posts }
    }
    var createCount: Int {
        box.withLock { $0.creates }
    }

    func channel() -> TurnThreadChannel {
        TurnThreadChannel { [self] name in
            let n: Int = self.box.withLock { s in
                s.creates += 1
                s.names.append(name)
                return s.creates
            }
            let threadName = name
            return TurnThreadMessage(id: "t\(n)") { content in
                self.box.withLock { $0.posts.append((threadName, content)) }
            }
        }
    }
}
