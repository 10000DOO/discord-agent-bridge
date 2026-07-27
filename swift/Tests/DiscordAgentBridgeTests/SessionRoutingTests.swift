import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("SessionRegistry")
struct SessionRegistryTests {
    @Test func bindBindingUnbindRoundtrip() async {
        let reg = SessionRegistry()
        #expect(await reg.binding(channelId: "c1") == nil)
        await reg.bind(channelId: "c1", SessionConfig(backend: .codex))
        #expect(await reg.binding(channelId: "c1")?.backend == .codex)
        await reg.unbind(channelId: "c1")
        #expect(await reg.binding(channelId: "c1") == nil)
    }

    @Test func channelIsolation() async {
        let reg = SessionRegistry()
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude))
        await reg.bind(channelId: "c2", SessionConfig(backend: .grok))
        #expect(await reg.binding(channelId: "c1")?.backend == .claude)
        #expect(await reg.binding(channelId: "c2")?.backend == .grok)
    }
}

@Suite("routeDecision")
struct RouteDecisionTests {
    @Test func prefixesWin() {
        // Prefixes can select a backend only after the channel is bound.
        #expect(routeDecision(content: "!claude hi", binding: nil) == .ignore)
        #expect(routeDecision(content: "!codex do x", binding: nil) == .ignore)
        #expect(routeDecision(content: "!grok yo", binding: nil) == .ignore)
        #expect(routeDecision(content: "!custom kimi", binding: nil) == .ignore)
        // prefix wins even when a (different) binding exists
        #expect(routeDecision(content: "!codex hi", binding: SessionConfig(backend: .claude)) == .prefixCodex("hi"))
        #expect(routeDecision(content: "!custom x", binding: SessionConfig(backend: .codex)) == .prefixCustom("x"))
    }

    @Test func emptyPromptIsUsage() {
        #expect(routeDecision(content: "!claude ", binding: nil) == .ignore)
        #expect(routeDecision(content: "!codex    ", binding: nil) == .ignore)
        #expect(routeDecision(content: "!grok ", binding: SessionConfig(backend: .codex)) == .usage("!grok"))
        #expect(routeDecision(content: "!custom ", binding: nil) == .ignore)
    }

    @Test func boundRoutesPlainText() {
        #expect(routeDecision(content: "hello there", binding: SessionConfig(backend: .grok)) == .bound(.grok, "hello there"))
        #expect(routeDecision(content: "  padded  ", binding: SessionConfig(backend: .claude)) == .bound(.claude, "padded"))
        #expect(routeDecision(content: "via custom", binding: SessionConfig(backend: .custom)) == .bound(.custom, "via custom"))
    }

    @Test func ignoreWhenNoPrefixNoBinding() {
        #expect(routeDecision(content: "hello", binding: nil) == .ignore)
        #expect(routeDecision(content: "   ", binding: SessionConfig(backend: .codex)) == .ignore) // empty after trim
    }

    // H15: TS `messageRouter.ts:144` ignores DMs unconditionally, before any prefix/binding logic
    // runs (independent of dmPolicy). isDM must win over every other branch below.
    @Test func dmIgnoresPrefixCommand() {
        #expect(routeDecision(content: "!claude hi", binding: nil, isDM: true) == .ignore)
        #expect(routeDecision(content: "!custom kimi", binding: nil, isDM: true) == .ignore)
    }

    @Test func dmIgnoresBoundChannelPlainText() {
        #expect(routeDecision(content: "hello there", binding: SessionConfig(backend: .grok), isDM: true) == .ignore)
    }

    @Test func dmIgnoresEvenEmptyPromptPrefix() {
        #expect(routeDecision(content: "!claude ", binding: nil, isDM: true) == .ignore) // would be .usage if not DM
    }
}

@Suite("boot session restore (T9)")
struct BootRestoreTests {
    // T9: store → SessionRegistry → routeDecision routes prefix-less messages to the stored backend.
    @Test func restoredBindingRoutesToStoredBackend() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-t9-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("swift-state.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: url)
        try await store.upsert(channelId: "c", PersistedSession(backend: .grok, cwd: "/x", guildId: "g", updatedAt: "t"))

        // Simulate DabMain.onReady restore into a fresh registry.
        let reg = SessionRegistry()
        await store.load()
        for (ch, ps) in await store.all() {
            await reg.bind(channelId: ch, SessionConfig(backend: ps.backend, model: ps.model, effort: ps.effort, permMode: ps.permMode))
        }
        let binding = await reg.binding(channelId: "c")
        #expect(binding?.backend == .grok)
        #expect(routeDecision(content: "hello there", binding: binding) == .bound(.grok, "hello there"))
    }
}

@Suite("agentCommandSpec")
struct AgentCommandSpecTests {
    @Test func startIsWizardOnlyNoSlashOptions() {
        // W11-b2 slice1: /agent start opens the select wizard; no free-text backend/model options.
        let spec = agentCommandSpec()
        #expect(spec.name == "agent")
        #expect(spec.subcommands.map(\.name) == ["start", "close", "resume", "stats"])
        let start = spec.subcommands.first { $0.name == "start" }
        #expect(start?.options.isEmpty == true)
    }

    @Test func closeHasNoOptions() {
        let spec = agentCommandSpec()
        let close = spec.subcommands.first { $0.name == "close" }
        #expect(close?.options.isEmpty == true)
    }
}
