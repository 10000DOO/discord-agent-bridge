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
