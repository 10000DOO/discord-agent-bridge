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
        #expect(routeDecision(content: "!claude hi", binding: nil) == .prefixClaude("hi"))
        #expect(routeDecision(content: "!codex do x", binding: nil) == .prefixCodex("do x"))
        #expect(routeDecision(content: "!grok yo", binding: nil) == .prefixGrok("yo"))
        // prefix wins even when a (different) binding exists
        #expect(routeDecision(content: "!codex hi", binding: SessionConfig(backend: .claude)) == .prefixCodex("hi"))
    }

    @Test func emptyPromptIsUsage() {
        #expect(routeDecision(content: "!claude ", binding: nil) == .usage("!claude"))
        #expect(routeDecision(content: "!codex    ", binding: nil) == .usage("!codex"))
        #expect(routeDecision(content: "!grok ", binding: SessionConfig(backend: .codex)) == .usage("!grok"))
    }

    @Test func boundRoutesPlainText() {
        #expect(routeDecision(content: "hello there", binding: SessionConfig(backend: .grok)) == .bound(.grok, "hello there"))
        #expect(routeDecision(content: "  padded  ", binding: SessionConfig(backend: .claude)) == .bound(.claude, "padded"))
    }

    @Test func ignoreWhenNoPrefixNoBinding() {
        #expect(routeDecision(content: "hello", binding: nil) == .ignore)
        #expect(routeDecision(content: "   ", binding: SessionConfig(backend: .codex)) == .ignore) // empty after trim
    }
}

@Suite("agentCommandSpec")
struct AgentCommandSpecTests {
    @Test func startHasRequiredBackendWithAllChoices() {
        let spec = agentCommandSpec()
        #expect(spec.name == "agent")
        #expect(spec.subcommands.map(\.name) == ["start", "close"])

        let start = spec.subcommands.first { $0.name == "start" }
        let backend = start?.options.first { $0.name == "backend" }
        #expect(backend?.required == true)
        #expect(backend?.choices.map(\.value) == Backend.allCases.map(\.rawValue))
        #expect(backend?.choices.map(\.value) == ["claude", "codex", "grok"])
    }

    @Test func closeHasNoOptions() {
        let spec = agentCommandSpec()
        let close = spec.subcommands.first { $0.name == "close" }
        #expect(close?.options.isEmpty == true)
    }
}
