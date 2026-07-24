import Testing
import Foundation
@testable import DiscordAgentBridge

/// Gateable fake `codex app-server`. Turn completion (delta + turn/completed, or turn/failed) is
/// released by the TurnGate; the read loop is never blocked, so a reentrancy bug shows up as
/// concurrent turn/start (gate.maxConcurrent > 1). The turn echoes its own prompt text ("ok:<text>")
/// so a cross-contaminated buffer fails the equality check.
private actor GateableCodexServer {
    enum Completion { case delta; case fullText }
    private let transport: InMemorySidecarTransport
    private let gate: TurnGate?
    private let initFails: Bool
    private let completion: Completion
    private let capture: LockedBox<[String: String]>?   // records thread/start + turn/start params

    init(transport: InMemorySidecarTransport, gate: TurnGate?, initFails: Bool = false, completion: Completion = .delta, capture: LockedBox<[String: String]>? = nil) {
        self.transport = transport
        self.gate = gate
        self.initFails = initFails
        self.completion = completion
        self.capture = capture
    }

    func run() async {
        do { for try await line in transport.lines { await handle(line) } } catch {}
    }

    private func handle(_ line: String) async {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let msg) = v, let method = msg["method"]?.stringValue, let id = msg["id"]
        else { return }

        switch method {
        case "initialize":
            if initFails {
                await writeError(id, "initialize refused")
            } else {
                await writeResult(id, .object(["userAgent": .string("fake-codex")]))
            }
        case "thread/start":
            if let m = msg["params"]?["model"]?.stringValue { capture?.withLock { $0["threadModel"] = m } }
            if let a = msg["params"]?["approvalPolicy"]?.stringValue { capture?.withLock { $0["approvalPolicy"] = a } }
            if let s = msg["params"]?["sandbox"]?.stringValue { capture?.withLock { $0["sandbox"] = s } }
            await writeResult(id, .object(["thread": .object(["id": .string("t1")])]))
        case "turn/start":
            let text = msg["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            if let e = msg["params"]?["effort"]?.stringValue { capture?.withLock { $0["turnEffort"] = e } }
            if let m = msg["params"]?["model"]?.stringValue { capture?.withLock { $0["turnModel"] = m } }
            await writeResult(id, .object(["turn": .object(["id": .string("u1")])]))
            Task { await self.completeTurn(text: text) }   // non-blocking: read loop keeps counting
        case "turn/interrupt":
            await writeResult(id, .object([:]))
        default:
            await writeError(id, "method not found: \(method)")
        }
    }

    private func completeTurn(text: String) async {
        let outcome = gate == nil ? .ok : await gate!.submit()
        if case .fail(let m) = outcome {
            await pushNotification("turn/failed", .object(["error": .object(["message": .string(m)])]))
            return
        }
        switch completion {
        case .delta:
            await pushNotification("item/agentMessage/delta", .object(["delta": .string("ok:\(text)")]))
        case .fullText:
            await pushNotification("item/completed", .object(["item": .object([
                "type": .string("agentMessage"), "text": .string("ok:\(text)"),
            ])]))
        }
        await pushNotification("turn/completed", .object([:]))
    }

    private func writeResult(_ id: JSONValue, _ result: JSONValue) async {
        await write(["id": id, "result": result])
    }
    private func writeError(_ id: JSONValue, _ message: String) async {
        await write(["id": id, "error": .object(["code": .number(-32000), "message": .string(message)])])
    }
    private func pushNotification(_ method: String, _ params: JSONValue) async {
        await write(["method": .string(method), "params": params])
    }
    private func write(_ obj: [String: JSONValue]) async {
        guard let d = try? JSONEncoder().encode(JSONValue.object(obj)), let s = String(data: d, encoding: .utf8) else { return }
        try? await transport.writeLine(s + "\n")
    }
}

private func makeCodexBridge(
    gate: TurnGate? = nil,
    initFails: Bool = false,
    completion: GateableCodexServer.Completion = .delta,
    timeoutNs: UInt64? = nil,
    capture: LockedBox<[String: String]>? = nil,
    permGate: PermissionGate = .shared,
    onApprovalSpy: LockedBox<[AppServerApprovalHandler?]>? = nil
) -> (CodexSessionBridge, MadeClients<CodexAppServerClient>) {
    let made = MadeClients<CodexAppServerClient>()
    let bridge = CodexSessionBridge(makeClient: { onApproval in
        onApprovalSpy?.withLock { $0.append(onApproval) }
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableCodexServer(transport: pair.sidecar, gate: gate, initFails: initFails, completion: completion, capture: capture)
        Task { await server.run() }
        return made.record(CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000, onApproval: onApproval))
    }, turnTimeoutOverrideNs: timeoutNs, gate: permGate)
    return (bridge, made)
}

@Suite("CodexSessionBridge")
struct CodexSessionBridgeTests {
    @Test func happyPath() async throws {
        let (bridge, _) = makeCodexBridge()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply == "ok:hi")
    }

    @Test func fullTextFallbackAccumulation() async throws {
        let (bridge, _) = makeCodexBridge(completion: .fullText)
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply == "ok:hi")
    }

    @Test func serializationReentrancyIsolation() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeCodexBridge(gate: gate)

        let tA = Task { try await bridge.runTurn(channelId: "c", text: "A") }
        await gate.waitReceived(1)                 // A in flight (held)
        let tB = Task { try await bridge.runTurn(channelId: "c", text: "B") }
        let tC = Task { try await bridge.runTurn(channelId: "c", text: "C") }

        await gate.release()                        // complete A
        let ra = try await tA.value
        await gate.waitReceived(2); await gate.release()
        await gate.waitReceived(3); await gate.release()
        let rb = try await tB.value
        let rc = try await tC.value

        #expect(ra == "ok:A")
        #expect(rb == "ok:B")   // each turn returns its OWN text → no buffer cross-talk
        #expect(rc == "ok:C")
        #expect(await gate.maxConcurrent == 1)      // never two turn/start on one session
    }

    @Test func respawnAfterClose() async throws {
        let (bridge, made) = makeCodexBridge()
        let r1 = try await bridge.runTurn(channelId: "c", text: "one")
        #expect(r1 == "ok:one")
        await made.last()?.close()                  // client dies
        let r2 = try await bridge.runTurn(channelId: "c", text: "two")
        #expect(r2 == "ok:two")
        #expect(made.count == 2)                    // makeClient re-invoked
    }

    @Test func initFailureClosesClient() async throws {
        let (bridge, made) = makeCodexBridge(initFails: true)
        await #expect(throws: (any Error).self) { try await bridge.runTurn(channelId: "c", text: "x") }
        #expect(made.last()?.isClosed == true)      // no orphan
    }

    @Test func backendErrorThrows() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeCodexBridge(gate: gate)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "x") }
        await gate.waitReceived(1)
        await gate.release(.fail("boom"))
        do {
            _ = try await t.value
            Issue.record("expected backend error")
        } catch let e as AppServerError {
            #expect(e.message == "boom")
        }
    }

    @Test func turnTimeoutThrows() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeCodexBridge(gate: gate, timeoutNs: 100_000_000)   // 100ms
        let t = Task { try await bridge.runTurn(channelId: "c", text: "x") }
        await gate.waitReceived(1)                  // held, never released → TurnBox timeout fires
        await #expect(throws: (any Error).self) { _ = try await t.value }
    }

    // W11-c: bypass permMode → auto policy (never/danger) + NO approval handler.
    @Test func autoPolicyInstallsNoApprovalHandler() async throws {
        let capture = LockedBox<[String: String]>([:])
        let handlers = LockedBox<[AppServerApprovalHandler?]>([])
        let (bridge, _) = makeCodexBridge(capture: capture, onApprovalSpy: handlers)
        _ = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .codex, permMode: "bypassPermissions"))
        #expect(capture.withLock { $0["approvalPolicy"] } == "never")
        #expect(capture.withLock { $0["sandbox"] } == "danger-full-access")
        #expect(handlers.withLock { $0.first ?? nil } == nil)   // no gate handler when auto
    }

    // W11-c: non-auto permMode → on-request policy + approval handler that routes allow→accept.
    @Test func nonAutoPolicyHandlerAllowMapsToAccept() async throws {
        let gate = PermissionGate()
        let prompts = LockedBox<[PermissionPrompt]>([])
        await gate.setPresenter { p in prompts.withLock { $0.append(p) } }
        let capture = LockedBox<[String: String]>([:])
        let handlers = LockedBox<[AppServerApprovalHandler?]>([])
        let (bridge, _) = makeCodexBridge(capture: capture, permGate: gate, onApprovalSpy: handlers)
        _ = try await bridge.runTurn(channelId: "c", ownerId: "owner-1", text: "hi", config: SessionConfig(backend: .codex, permMode: "plan"))
        #expect(capture.withLock { $0["approvalPolicy"] } == "on-request")
        #expect(capture.withLock { $0["sandbox"] } == "read-only")

        let handler = handlers.withLock { $0.first ?? nil }
        #expect(handler != nil)
        // Exercise the real handler: allow → accept (deny would map to decline).
        let decision = LockedBox<AppServerApprovalDecision?>(nil)
        let t = Task {
            let d = await handler!(AppServerApprovalRequest(requestId: .number(1), method: "item/commandExecution/requestApproval", params: .object(["command": .string("ls")])))
            decision.withLock { $0 = d }
        }
        while prompts.withLock({ $0.isEmpty }) { await Task.yield() }
        #expect(prompts.withLock { $0[0].toolName } == "shell")     // derived from command param
        #expect(prompts.withLock { $0[0].approverId } == "owner-1")  // approver = session owner
        #expect(await gate.resolve(reqKey: prompts.withLock { $0[0].reqKey }, action: .allow, byUserId: "owner-1") == true)
        _ = await t.value
        #expect(decision.withLock { $0 } == .accept)
    }

    // W11-b1: model → thread/start params, effort/model → turn/start params.
    @Test func configReachesThreadAndTurnParams() async throws {
        let capture = LockedBox<[String: String]>([:])
        let (bridge, _) = makeCodexBridge(capture: capture)
        let reply = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .codex, model: "gpt-5-codex", effort: "high"))
        #expect(reply == "ok:hi")
        let got = capture.withLock { $0 }
        #expect(got["threadModel"] == "gpt-5-codex")
        #expect(got["turnEffort"] == "high")
        #expect(got["turnModel"] == "gpt-5-codex")
    }
}
