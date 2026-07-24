import Testing
import Foundation
@testable import DiscordAgentBridge

/// Full-field equality round-trips (the existing AgentEventTests only checks `.kind`).
@Suite("AgentEvent full round-trip + unknown kind")
struct AgentEventFullRoundtripTests {
    private func rt(_ ev: AgentEvent) throws -> AgentEvent {
        try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(ev))
    }

    @Test func unknownKindThrows() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AgentEvent.self, from: Data(#"{"kind":"totally_unknown"}"#.utf8))
        }
    }

    @Test func contextUsageAllFields() throws {
        let ev = AgentEvent.contextUsage(
            totalTokens: 123, maxTokens: 4567, percentage: 2.75,
            model: "m", modelDisplayName: "Model X",
            clearableTokens: 12, memoryFileCount: 3, mcpServerCount: 4
        )
        #expect(try rt(ev) == ev)
    }

    @Test func contextUsageNilOptionals() throws {
        let ev = AgentEvent.contextUsage(
            totalTokens: 1, maxTokens: 2, percentage: 0.5,
            model: nil, modelDisplayName: nil,
            clearableTokens: nil, memoryFileCount: nil, mcpServerCount: nil
        )
        #expect(try rt(ev) == ev)
    }

    @Test func subagentResultAllFields() throws {
        let ev = AgentEvent.subagentResult(
            taskId: "tk", status: .failed, summary: "summary",
            toolUseId: "tu", durationMs: 99, toolUses: 5
        )
        #expect(try rt(ev) == ev)
    }

    @Test func subagentResultNilOptionals() throws {
        let ev = AgentEvent.subagentResult(
            taskId: "t", status: .stopped, summary: "", toolUseId: nil, durationMs: nil, toolUses: nil
        )
        #expect(try rt(ev) == ev)
    }

    @Test func resultAllFieldsAndNil() throws {
        let full = AgentEvent.result(text: "done", costUsd: 0.5, tokensIn: 10, tokensOut: 20, durationMs: 30)
        #expect(try rt(full) == full)
        let empty = AgentEvent.result(text: nil, costUsd: nil, tokensIn: nil, tokensOut: nil, durationMs: nil)
        #expect(try rt(empty) == empty)
    }

    @Test func toolResultWithParent() throws {
        let ev = AgentEvent.toolResult(id: "t", ok: false, content: "err", parentToolUseId: "parent")
        #expect(try rt(ev) == ev)
        let noParent = AgentEvent.toolResult(id: "t2", ok: true, content: "ok", parentToolUseId: nil)
        #expect(try rt(noParent) == noParent)
    }

    @Test func rateLimitAllFieldsAndNil() throws {
        let full = AgentEvent.rateLimit(resetAt: "2026-07-24T00:00:00Z", rateLimitType: "five_hour", utilization: 0.88)
        #expect(try rt(full) == full)
        let empty = AgentEvent.rateLimit(resetAt: nil, rateLimitType: nil, utilization: nil)
        #expect(try rt(empty) == empty)
    }
}
