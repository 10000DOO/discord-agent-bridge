import Testing
import Foundation
@testable import DiscordAgentBridge

// Fold codexTurnStep the same way CodexSessionBridge.onNotification does, so the test exercises
// the exact accumulation the `!codex` reply path relies on.
private struct TurnAccumulator {
    var text = ""
    var done: String?
    var failed: String?

    mutating func apply(method: String, params: JSONValue?) {
        if done != nil || failed != nil { return }
        switch codexTurnStep(method: method, params: params) {
        case .appendText(let d): text += d
        case .fullText(let t): if text.isEmpty { text = t }
        case .finished: done = text.isEmpty ? "(empty result)" : text  // usage unused in text fold
        case .failed(let m): failed = m
        case .ignore: break
        }
    }
}

@Suite("codexTurnStep")
struct CodexTurnStepTests {
    @Test func deltaMappings() {
        #expect(codexTurnStep(method: "item/agentMessage/delta", params: .object(["delta": .string("hi")])) == .appendText("hi"))
        // empty delta ignored (eventMapper.ts:80)
        #expect(codexTurnStep(method: "item/agentMessage/delta", params: .object(["delta": .string("")])) == .ignore)
        #expect(codexTurnStep(method: "turn/completed", params: nil) == .finished(nil))
        // unknown / non-text notifications ignored
        #expect(codexTurnStep(method: "turn/started", params: nil) == .ignore)
    }

    @Test func itemCompletedAgentMessageFallback() {
        let step = codexTurnStep(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("agentMessage"),
                "text": .string("full answer"),
            ])])
        )
        #expect(step == .fullText("full answer"))
        // snake_case tolerated (eventMapper.ts:271)
        let snake = codexTurnStep(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("agent_message"),
                "text": .string("x"),
            ])])
        )
        #expect(snake == .fullText("x"))
        // non-agentMessage item ignored by text path (tools → codexToolEvents)
        let other = codexTurnStep(
            method: "item/completed",
            params: .object(["item": .object(["type": .string("commandExecution")])])
        )
        #expect(other == .ignore)
    }

    @Test func toolEventsCommandExecution() {
        var seq = 0
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "id": .string("c1"),
                "command": .string("ls"),
                "aggregatedOutput": .string("a\nb"),
                "exitCode": .number(0),
            ])]),
            mintId: &seq
        )
        #expect(events == [
            .toolUse(id: "c1", name: "shell", input: .object(["command": .string("ls")]), parentToolUseId: nil),
            .toolResult(id: "c1", ok: true, content: "a\nb", parentToolUseId: nil),
        ])
    }

    @Test func toolEventsFailedCommand() {
        var seq = 0
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "id": .string("c2"),
                "command": .string("false"),
                "aggregatedOutput": .string("err"),
                "exitCode": .number(1),
            ])]),
            mintId: &seq
        )
        #expect(events.contains(.toolResult(id: "c2", ok: false, content: "err", parentToolUseId: nil)))
    }

    @Test func toolEventsFileChange() {
        var seq = 0
        let changes: JSONValue = .array([.object([
            "path": .string("a.ts"),
            "kind": .object(["type": .string("add")]),
            "diff": .string("+ line"),
        ])])
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("fileChange"),
                "id": .string("f1"),
                "status": .string("completed"),
                "changes": changes,
            ])]),
            mintId: &seq
        )
        #expect(events.count == 2)
        #expect(events[0] == .toolUse(
            id: "f1",
            name: "apply_patch",
            input: .object(["changes": changes]),
            parentToolUseId: nil
        ))
        #expect(events[1] == .toolResult(id: "f1", ok: true, content: "--- a.ts\n+ line", parentToolUseId: nil))
    }

    @Test func toolEventsWebAndMcp() {
        var seq = 0
        let web = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("webSearch"),
                "id": .string("w1"),
                "query": .string("cats"),
            ])]),
            mintId: &seq
        )
        #expect(web == [
            .toolUse(id: "w1", name: "web_search", input: .object(["query": .string("cats")]), parentToolUseId: nil),
        ])

        let mcp = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("mcpToolCall"),
                "id": .string("m1"),
                "tool": .string("search"),
                "arguments": .object(["q": .string("x")]),
                "result": .string("ok"),
                "status": .string("completed"),
            ])]),
            mintId: &seq
        )
        #expect(mcp == [
            .toolUse(id: "m1", name: "search", input: .object(["q": .string("x")]), parentToolUseId: nil),
            .toolResult(id: "m1", ok: true, content: "ok", parentToolUseId: nil),
        ])
    }

    @Test func toolEventsMintIdWhenMissing() {
        var seq = 0
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "command": .string("pwd"),
            ])]),
            mintId: &seq
        )
        #expect(seq == 1)
        #expect(events.first == .toolUse(
            id: "codex-tool-1",
            name: "shell",
            input: .object(["command": .string("pwd")]),
            parentToolUseId: nil
        ))
    }

    @Test func toolEventsIgnoresNonCompletedMethods() {
        var seq = 0
        #expect(codexToolEvents(method: "item/started", params: .object([
            "item": .object(["type": .string("commandExecution"), "id": .string("c")]),
        ]), mintId: &seq).isEmpty)
        #expect(codexToolEvents(method: "item/agentMessage/delta", params: .object([
            "delta": .string("hi"),
        ]), mintId: &seq).isEmpty)
    }

    @Test func toolEventsSpawnAgent() {
        var seq = 0
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("collabAgentToolCall"),
                "id": .string("spawn-1"),
                "tool": .string("spawnAgent"),
                "agentRole": .string("explorer"),
                "agentNickname": .string("Scout"),
                "threadId": .string("child-thread-9"),
                "status": .string("completed"),
            ])]),
            mintId: &seq
        )
        guard case .toolUse(let id, let name, let input, _)? = events.first else {
            Issue.record("expected tool_use"); return
        }
        #expect(id == "spawn-1")
        #expect(name == "spawnAgent")
        #expect(input["subagent_type"]?.stringValue == "explorer")
        #expect(input["agentNickname"]?.stringValue == "Scout")
        #expect(input["threadId"]?.stringValue == "child-thread-9")
        #expect(events.count == 2) // + tool_result on completed spawn
    }

    @Test func failurePaths() {
        for method in ["turn/failed", "thread/failed", "error"] {
            let step = codexTurnStep(method: method, params: .object(["error": .object(["message": .string("boom")])]))
            #expect(step == .failed("boom"))
        }
        // top-level message fallback + default text
        #expect(codexTurnStep(method: "error", params: .object(["message": .string("m")])) == .failed("m"))
        #expect(codexTurnStep(method: "error", params: nil) == .failed("Codex turn failed."))
    }
}

@Suite("CodexSessionBridge turn accumulation (fake transport)")
struct CodexTurnAccumulationTests {
    // Drive a real CodexAppServerClient over an in-memory transport: subscribe like the bridge,
    // push deltas + turn/completed, assert the accumulated completion string.
    @Test func deltasThenCompletedAccumulate() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)

        let acc = LockedBox(TurnAccumulator())
        _ = client.onNotification { method, params in
            acc.withLock { $0.apply(method: method, params: params) }
        }

        await fake.pushNotification(method: "item/agentMessage/delta", params: .object(["delta": .string("Hello")]))
        await fake.pushNotification(method: "item/agentMessage/delta", params: .object(["delta": .string(", world")]))
        await fake.pushNotification(method: "turn/completed", params: .object([:]))
        #expect(await waitUntil { acc.withLock { $0.done } != nil })

        let got = acc.withLock { $0 }
        #expect(got.done == "Hello, world")
        #expect(got.failed == nil)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func failureNotificationSurfaces() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)

        let acc = LockedBox(TurnAccumulator())
        _ = client.onNotification { method, params in
            acc.withLock { $0.apply(method: method, params: params) }
        }

        await fake.pushNotification(method: "item/agentMessage/delta", params: .object(["delta": .string("partial")]))
        await fake.pushNotification(method: "turn/failed", params: .object(["error": .object(["message": .string("kaboom")])]))
        #expect(await waitUntil { acc.withLock { $0.failed } != nil })

        let got = acc.withLock { $0 }
        #expect(got.failed == "kaboom")
        #expect(got.done == nil)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }
}
