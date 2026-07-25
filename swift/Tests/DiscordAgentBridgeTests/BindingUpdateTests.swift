import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("BindingUpdate pure helpers")
struct BindingUpdateTests {
    @Test func applyPatchToConfigSetsOnlyProvidedFields() {
        let base = SessionConfig(backend: .claude, model: "m1", effort: "low", permMode: "default")
        let onlyModel = applyPatch(to: base, BindingPatch(model: "m2"))
        #expect(onlyModel.model == "m2")
        #expect(onlyModel.effort == "low")
        #expect(onlyModel.permMode == "default")
        #expect(onlyModel.backend == .claude)

        let backend = applyPatch(to: base, BindingPatch(backend: .codex))
        #expect(backend.backend == .codex)
        #expect(backend.model == "m1")
    }

    @Test func applyPatchToSessionClearsBackendSessionIdWhenRequested() {
        let s = PersistedSession(
            backend: .claude, backendSessionId: "B-1", cwd: "/x", guildId: "g",
            model: "m1", effort: "high", permMode: "plan", updatedAt: "t0"
        )
        let cleared = applyPatch(to: s, BindingPatch(clearBackendSessionId: true), now: "t1")
        #expect(cleared.backendSessionId == nil)
        #expect(cleared.model == "m1")
        #expect(cleared.effort == "high")
        #expect(cleared.permMode == "plan")
        #expect(cleared.updatedAt == "t1")

        let modelOnly = applyPatch(to: s, BindingPatch(model: "m2"), now: "t2")
        #expect(modelOnly.backendSessionId == "B-1")
        #expect(modelOnly.model == "m2")
        #expect(modelOnly.updatedAt == "t2")
    }

    @Test func sessionConfigFromPersistedMapsFields() {
        let s = PersistedSession(
            backend: .grok, backendSessionId: "s", cwd: "/c", guildId: "g",
            model: "g1", effort: "high", permMode: "bypassPermissions", updatedAt: "t"
        )
        let c = sessionConfig(from: s)
        #expect(c == SessionConfig(backend: .grok, model: "g1", effort: "high", permMode: "bypassPermissions"))
    }

    @Test func formatStatsLinesEmptyAndFilled() {
        #expect(formatStatsLines(bindings: []) == ["(none)"])
        let lines = formatStatsLines(bindings: [
            (channelId: "c1", backend: .claude, model: "sonnet", effort: "high"),
            (channelId: "c2", backend: .codex, model: nil, effort: nil),
        ])
        #expect(lines.count == 2)
        #expect(lines[0].contains("c1"))
        #expect(lines[0].contains("claude"))
        #expect(lines[0].contains("sonnet"))
        #expect(lines[0].contains("effort=high"))
        #expect(lines[1].contains("c2"))
        #expect(lines[1].contains("codex"))
        #expect(!lines[1].contains("`"))
        #expect(!lines[1].contains("effort="))
    }
}
