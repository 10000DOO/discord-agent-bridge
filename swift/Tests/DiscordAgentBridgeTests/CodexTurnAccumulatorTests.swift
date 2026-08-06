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
        var parents: [String: String] = [:]
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "id": .string("c1"),
                "command": .string("ls"),
                "aggregatedOutput": .string("a\nb"),
                "exitCode": .number(0),
            ])]),
            mintId: &seq,
            parentByThread: &parents
        )
        #expect(events == [
            .toolUse(id: "c1", name: "shell", input: .object(["command": .string("ls")]), parentToolUseId: nil),
            .toolResult(id: "c1", ok: true, content: "a\nb", parentToolUseId: nil),
        ])
    }

    @Test func toolEventsFailedCommand() {
        var seq = 0
        var parents: [String: String] = [:]
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "id": .string("c2"),
                "command": .string("false"),
                "aggregatedOutput": .string("err"),
                "exitCode": .number(1),
            ])]),
            mintId: &seq,
            parentByThread: &parents
        )
        #expect(events.contains(.toolResult(id: "c2", ok: false, content: "err", parentToolUseId: nil)))
    }

    @Test func toolEventsCommandWithoutExitCodeFails() {
        var seq = 0
        var parents: [String: String] = [:]
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "id": .string("c3"),
                "command": .string("unknown"),
                "aggregatedOutput": .string("no exit status"),
            ])]),
            mintId: &seq,
            parentByThread: &parents
        )
        #expect(events.contains(.toolResult(
            id: "c3",
            ok: false,
            content: "no exit status",
            parentToolUseId: nil
        )))
    }

    @Test func toolEventsFileChange() {
        var seq = 0
        var parents: [String: String] = [:]
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
            mintId: &seq,
            parentByThread: &parents
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
        var parents: [String: String] = [:]
        let web = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("webSearch"),
                "id": .string("w1"),
                "query": .string("cats"),
            ])]),
            mintId: &seq,
            parentByThread: &parents
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
            mintId: &seq,
            parentByThread: &parents
        )
        #expect(mcp == [
            .toolUse(id: "m1", name: "search", input: .object(["q": .string("x")]), parentToolUseId: nil),
            .toolResult(id: "m1", ok: true, content: "ok", parentToolUseId: nil),
        ])
    }

    @Test func toolEventsMintIdWhenMissing() {
        var seq = 0
        var parents: [String: String] = [:]
        let events = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "command": .string("pwd"),
            ])]),
            mintId: &seq,
            parentByThread: &parents
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
        var parents: [String: String] = [:]
        #expect(codexToolEvents(method: "item/started", params: .object([
            "item": .object(["type": .string("commandExecution"), "id": .string("c")]),
        ]), mintId: &seq, parentByThread: &parents).isEmpty)
        #expect(codexToolEvents(method: "item/agentMessage/delta", params: .object([
            "delta": .string("hi"),
        ]), mintId: &seq, parentByThread: &parents).isEmpty)
    }

    // G-P1-02: TS eventMapper item/started → progress; turn/started → "작업 중".
    @Test func progressEventsTurnStarted() {
        #expect(codexProgressEvents(method: "turn/started", params: nil) == [
            .progress(label: CodexProgressLabels.working, detail: nil),
        ])
    }

    @Test func progressEventsItemStartedCommandExecution() {
        // eventMapper.test.ts: maps item/started commandExecution to progress
        let events = codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object([
                "type": .string("commandExecution"),
                "command": .string("ls -la"),
            ])])
        )
        #expect(events == [
            .progress(label: CodexProgressLabels.commandExecution, detail: "ls -la"),
        ])
    }

    @Test func progressEventsItemStartedVariants() {
        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object([
                "type": .string("web_search"),
                "query": .string("swift actors"),
            ])])
        ) == [.progress(label: CodexProgressLabels.webSearch, detail: "swift actors")])

        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object([
                "type": .string("fileChange"),
                "changes": .array([
                    .object(["path": .string("a.ts")]),
                    .object(["path": .string("b.ts")]),
                ]),
            ])])
        ) == [.progress(label: CodexProgressLabels.fileChange, detail: "2개 파일")])

        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object([
                "type": .string("mcpToolCall"),
                "tool": .string("read_file"),
            ])])
        ) == [.progress(label: CodexProgressLabels.mcpToolCall, detail: "read_file")])

        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object(["type": .string("image")])])
        ) == [.progress(label: CodexProgressLabels.image, detail: nil)])

        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object(["type": .string("file_search")])])
        ) == [.progress(label: CodexProgressLabels.fileSearch, detail: nil)])

        // agentMessage / unknown → no progress (text path handles deltas)
        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object(["type": .string("agentMessage")])])
        ).isEmpty)
        #expect(codexProgressEvents(method: "item/completed", params: nil).isEmpty)
        #expect(codexProgressEvents(method: "item/agentMessage/delta", params: nil).isEmpty)
    }

    // A delegating codex turn also emits `subAgentActivity`, which used to fall through to nil and
    // leave the channel silent for the whole subagent stretch (measured, codex-cli 0.146.1).
    @Test func progressEventsItemStartedSubAgentActivity() {
        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object([
                "type": .string("subAgentActivity"),
                "kind": .string("started"),
                "agentThreadId": .string("019fd57f-971c-7920-b5ce-6d3ac6e87ba0"),
                "agentPath": .string("reviewer"),
            ])])
        ) == [.progress(label: CodexProgressLabels.collabAgentToolCall, detail: "reviewer")])

        // No agentPath → the line still posts, with no detail. Never `kind` ("started" would only
        // repeat the label) and never `agentThreadId` (a uuid is not a label).
        #expect(codexProgressEvents(
            method: "item/started",
            params: .object(["item": .object([
                "type": .string("sub_agent_activity"),
                "kind": .string("started"),
                "agentThreadId": .string("019fd57f-971c-7920-b5ce-6d3ac6e87ba0"),
            ])])
        ) == [.progress(label: CodexProgressLabels.collabAgentToolCall, detail: nil)])
    }

    // C1 / eventMapper.ts:171-184 — item/reasoning/delta(+3 aliases) → kind:'thinking'.
    @Test func progressEventsReasoningDeltaMapsToThinking() {
        for method in [
            "item/reasoning/delta",
            "item/agentReasoning/delta",
            "item/reasoning/textDelta",
            "item/reasoning/summaryTextDelta",
        ] {
            #expect(codexProgressEvents(method: method, params: .object(["delta": .string("pondering")])) == [
                .thinking(text: "pondering", delta: true),
            ])
        }
    }

    @Test func progressEventsReasoningDeltaEmptyIgnored() {
        // eventMapper.ts:175-178 — empty delta yields no events.
        #expect(codexProgressEvents(method: "item/reasoning/delta", params: .object(["delta": .string("")])).isEmpty)
        #expect(codexProgressEvents(method: "item/reasoning/delta", params: nil).isEmpty)
    }

    @Test func toolEventsSpawnAgentRegistersChildThread() {
        var seq = 0
        var parents: [String: String] = [:]
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
            mintId: &seq,
            parentByThread: &parents
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
        // TS MapContext.onSpawnThread(child, spawnToolId)
        #expect(parents["child-thread-9"] == "spawn-1")
    }

    @Test func toolEventsAttachesParentToolUseIdFromParentByThread() {
        // TS eventMapper.test: parentByThread child-t → spawn-1 on child-thread item.
        var seq = 0
        var parents: [String: String] = ["child-t": "spawn-1"]
        let events = codexToolEvents(
            method: "item/completed",
            params: .object([
                "threadId": .string("child-t"),
                "item": .object([
                    "type": .string("commandExecution"),
                    "id": .string("c9"),
                    "command": .string("pwd"),
                    "aggregatedOutput": .string("/"),
                    "exitCode": .number(0),
                ]),
            ]),
            mintId: &seq,
            parentByThread: &parents
        )
        #expect(events == [
            .toolUse(
                id: "c9",
                name: "shell",
                input: .object(["command": .string("pwd")]),
                parentToolUseId: "spawn-1"
            ),
            .toolResult(id: "c9", ok: true, content: "/", parentToolUseId: "spawn-1"),
        ])
    }

    @Test func toolEventsSpawnThenChildCommandRoundTrip() {
        var seq = 0
        var parents: [String: String] = [:]
        _ = codexToolEvents(
            method: "item/completed",
            params: .object(["item": .object([
                "type": .string("collabAgentToolCall"),
                "id": .string("spawn-1"),
                "tool": .string("spawnAgent"),
                "threadId": .string("child-t"),
                "status": .string("completed"),
            ])]),
            mintId: &seq,
            parentByThread: &parents
        )
        let child = codexToolEvents(
            method: "item/completed",
            params: .object([
                "threadId": .string("child-t"),
                "item": .object([
                    "type": .string("fileChange"),
                    "id": .string("f-child"),
                    "status": .string("completed"),
                    "changes": .array([.object([
                        "path": .string("x.ts"),
                        "diff": .string("+x"),
                    ])]),
                ]),
            ]),
            mintId: &seq,
            parentByThread: &parents
        )
        #expect(child.count == 2)
        guard case .toolUse(_, _, _, let parentUse)? = child.first else {
            Issue.record("expected tool_use"); return
        }
        guard case .toolResult(_, _, _, let parentResult)? = child.dropFirst().first else {
            Issue.record("expected tool_result"); return
        }
        #expect(parentUse == "spawn-1")
        #expect(parentResult == "spawn-1")
    }

    // H2: turnId extraction + stale-completion guard (TS eventMapper.ts:74 + appSession.ts:220).
    @Test func notificationTurnIdExtraction() {
        #expect(codexNotificationTurnId(params: .object(["turnId": .string("u1")])) == "u1")
        #expect(codexNotificationTurnId(params: .object([:])) == nil)
        #expect(codexNotificationTurnId(params: nil) == nil)
    }

    @Test func notificationMatchesActiveTurnGuard() {
        // No turnId on the notification → always matches (some app-server builds omit it).
        #expect(codexNotificationMatchesActiveTurn(params: .object([:]), activeTurnId: "u1"))
        #expect(codexNotificationMatchesActiveTurn(params: nil, activeTurnId: "u1"))
        // No active turn recorded yet → let it through (Swift-only race window).
        #expect(codexNotificationMatchesActiveTurn(params: .object(["turnId": .string("stale")]), activeTurnId: nil))
        // Matching turnId → matches.
        #expect(codexNotificationMatchesActiveTurn(params: .object(["turnId": .string("u1")]), activeTurnId: "u1"))
        // Mismatched turnId (stale turn/completed from an already-finished turn) → rejected (H2).
        #expect(codexNotificationMatchesActiveTurn(params: .object(["turnId": .string("stale")]), activeTurnId: "u1") == false)
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

    // C2 / eventMapper.ts:186-208 — thread/tokenUsage/updated → context-usage snapshot.
    @Test func contextUsageMapsTokenUsageUpdated() {
        let params: JSONValue = .object([
            "tokenUsage": .object([
                "total": .object(["totalTokens": .number(1_200)]),
                "modelContextWindow": .number(200_000),
            ]),
        ])
        #expect(codexContextUsage(method: "thread/tokenUsage/updated", params: params) == ContextUsageInfo(
            totalTokens: 1_200, maxTokens: 200_000, percentage: 1
        ))
    }

    @Test func contextUsageCapsAt100Percent() {
        let params: JSONValue = .object([
            "tokenUsage": .object([
                "total": .object(["totalTokens": .number(50_000)]),
                "modelContextWindow": .number(10_000)]),
        ])
        #expect(codexContextUsage(method: "thread/tokenUsage/updated", params: params) == ContextUsageInfo(
            totalTokens: 50_000, maxTokens: 10_000, percentage: 100
        ))
    }

    @Test func contextUsageUsesConfiguredModelOnly() {
        let params: JSONValue = .object([
            "tokenUsage": .object([
                "total": .object(["totalTokens": .number(1_200)]),
                "modelContextWindow": .number(200_000),
            ]),
        ])
        #expect(codexContextUsage(
            method: "thread/tokenUsage/updated", params: params, model: " gpt-5.1-codex "
        )?.model == "gpt-5.1-codex")
        #expect(codexContextUsage(
            method: "thread/tokenUsage/updated", params: params, model: "   "
        )?.model == nil)
    }

    @Test func contextUsageIgnoresOtherMethodsAndMissingFields() {
        let validUsage: JSONValue = .object([
            "tokenUsage": .object([
                "total": .object(["totalTokens": .number(1)]),
                "modelContextWindow": .number(100),
            ]),
        ])
        // Wrong method → nil (thinking/progress notifications must not be mistaken for usage).
        #expect(codexContextUsage(method: "item/reasoning/delta", params: validUsage) == nil)
        // No params / no tokenUsage / missing totalTokens / non-positive modelContextWindow → nil
        // (eventMapper.ts:190,197 EMPTY guards).
        #expect(codexContextUsage(method: "thread/tokenUsage/updated", params: nil) == nil)
        #expect(codexContextUsage(method: "thread/tokenUsage/updated", params: .object([:])) == nil)
        #expect(codexContextUsage(
            method: "thread/tokenUsage/updated",
            params: .object(["tokenUsage": .object(["modelContextWindow": .number(100)])])
        ) == nil)
        #expect(codexContextUsage(
            method: "thread/tokenUsage/updated",
            params: .object(["tokenUsage": .object([
                "total": .object(["totalTokens": .number(1)]),
                "modelContextWindow": .number(0),
            ])])
        ) == nil)
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
