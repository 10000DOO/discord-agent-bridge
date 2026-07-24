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
        case .finished: done = text.isEmpty ? "(empty result)" : text
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
        #expect(codexTurnStep(method: "turn/completed", params: nil) == .finished)
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
        // non-agentMessage item ignored
        let other = codexTurnStep(
            method: "item/completed",
            params: .object(["item": .object(["type": .string("commandExecution")])])
        )
        #expect(other == .ignore)
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
        try await Task.sleep(nanoseconds: 100_000_000)

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
        try await Task.sleep(nanoseconds: 100_000_000)

        let got = acc.withLock { $0 }
        #expect(got.failed == "kaboom")
        #expect(got.done == nil)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }
}
