import Testing
import Foundation
@testable import DiscordAgentBridge

/// Gateable fake Claude sidecar. Turn completion (a `.text` + `.result` event, or an `.error`
/// event) is released by the TurnGate; the read loop is never blocked, so a reentrancy bug shows as
/// concurrent session.send (gate.maxConcurrent > 1). Echoes "ok:<text>".
private actor GateableSidecar {
    private let transport: InMemorySidecarTransport
    private let gate: TurnGate?
    private let resultEchoesText: Bool
    private let capture: LockedBox<[String: String]>?   // records session.start params
    private let emitsPermission: Bool                   // emit a permission_request instead of finishing
    private let capturePerm: LockedBox<[String: String]>?  // records the session.permission answer
    private let emitsBackendId: String?                 // emit session.backend_id notify with this id
    private let reqCapture: LockedBox<[String]>?        // records "start" / "resume:<backendId>"
    private let resumeFails: Bool                       // session.resume → error (forces fallback)
    private var counter = 0
    private var lastText = ""

    init(transport: InMemorySidecarTransport, gate: TurnGate?, resultEchoesText: Bool = false, capture: LockedBox<[String: String]>? = nil, emitsPermission: Bool = false, capturePerm: LockedBox<[String: String]>? = nil, emitsBackendId: String? = nil, reqCapture: LockedBox<[String]>? = nil, resumeFails: Bool = false) {
        self.transport = transport
        self.gate = gate
        self.resultEchoesText = resultEchoesText
        self.capture = capture
        self.emitsPermission = emitsPermission
        self.capturePerm = capturePerm
        self.emitsBackendId = emitsBackendId
        self.reqCapture = reqCapture
        self.resumeFails = resumeFails
    }

    func run() async {
        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await transport.writeLine(line + "\n")
        }
        do { for try await line in transport.lines { await handle(line) } } catch {}
    }

    private func handle(_ line: String) async {
        guard let env = try? parseEnvelope(line), env.type == .req, let id = env.id, let method = env.method else { return }
        switch method {
        case "session.resume" where resumeFails:
            reqCapture?.withLock { $0.append("resume-fail") }
            await writeEnv(resError(id: id, method: method, error: makeError(code: "sdk_error", message: "session expired")))
        case "session.start", "session.resume":
            counter += 1
            if let m = env.params?["model"]?.stringValue { capture?.withLock { $0["model"] = m } }
            if let e = env.params?["effort"]?.stringValue { capture?.withLock { $0["effort"] = e } }
            if method == "session.resume" {
                reqCapture?.withLock { $0.append("resume:\(env.params?["backendSessionId"]?.stringValue ?? "?")") }
            } else {
                reqCapture?.withLock { $0.append("start") }
            }
            let handle = "h\(counter)"
            // resume echoes the requested backend id; start starts null (T3) unless it emits one.
            let backendField: JSONValue = method == "session.resume"
                ? .string(env.params?["backendSessionId"]?.stringValue ?? "")
                : .null
            await writeEnv(res(id: id, method: method, result: .object([
                "session": .string(handle), "backendSessionId": backendField,
            ])))
            // T1/T3: backend id arrives via a later notify (start returned null).
            if method == "session.start", let bid = emitsBackendId {
                await writeEnv(notify(method: "session.backend_id", params: ["backendSessionId": .string(bid)], session: handle))
            }
        case "session.send":
            let session = env.session ?? env.params?["session"]?.stringValue ?? ""
            let text = env.params?["text"]?.stringValue ?? ""
            lastText = text
            await writeEnv(res(id: id, method: method, result: .object(["ok": .bool(true)]), session: session))
            if emitsPermission {
                // Ask for permission; the turn finishes only after session.permission answers.
                Task { await self.emit(session: session, event: .permissionRequest(id: "perm-1", toolName: "Bash", input: .object(["command": .string("ls")]))) }
            } else {
                Task { await self.completeTurn(session: session, text: text) }   // non-blocking
            }
        case "session.permission":
            capturePerm?.withLock {
                $0["behavior"] = env.params?["behavior"]?.stringValue ?? ""
                $0["requestId"] = env.params?["requestId"]?.stringValue ?? ""
            }
            await writeEnv(res(id: id, method: method, result: .object(["ok": .bool(true)]), session: env.session))
            await completeTurn(session: env.session ?? "", text: lastText)   // tool proceeds → finish turn
        case "session.stop":
            await writeEnv(res(id: id, method: method, result: .object(["ok": .bool(true)]), session: env.session))
        default:
            await writeEnv(resError(id: id, method: method, error: makeError(code: "unsupported", message: method)))
        }
    }

    private func completeTurn(session: String, text: String) async {
        let outcome = gate == nil ? .ok : await gate!.submit()
        if case .fail(let m) = outcome {
            await emit(session: session, event: .error(message: m, retryable: false))
            return
        }
        await emit(session: session, event: .text(text: "ok:\(text)", delta: true))
        let resultText: String? = resultEchoesText ? "ok:\(text)" : nil
        await emit(session: session, event: .result(text: resultText, costUsd: nil, tokensIn: nil, tokensOut: nil, durationMs: nil))
    }

    private func emit(session: String, event: AgentEvent) async {
        if let line = try? serializeEnvelope(eventEnvelope(session: session, event: event)) {
            try? await transport.writeLine(line + "\n")
        }
    }
    private func writeEnv(_ env: Envelope) async {
        if let line = try? serializeEnvelope(env) { try? await transport.writeLine(line + "\n") }
    }
}

private func makeDabBridge(
    gate: TurnGate? = nil,
    resultEchoesText: Bool = false,
    timeoutNs: UInt64? = nil,
    capture: LockedBox<[String: String]>? = nil,
    permGate: PermissionGate = .shared,
    emitsPermission: Bool = false,
    capturePerm: LockedBox<[String: String]>? = nil,
    store: SessionStore? = nil,
    emitsBackendId: String? = nil,
    reqCapture: LockedBox<[String]>? = nil,
    resumeFails: Bool = false
) -> (DabSessionBridge, MadeClients<ClaudeSidecarClient>) {
    let made = MadeClients<ClaudeSidecarClient>()
    let bridge = DabSessionBridge(makeClient: {
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableSidecar(transport: pair.sidecar, gate: gate, resultEchoesText: resultEchoesText, capture: capture, emitsPermission: emitsPermission, capturePerm: capturePerm, emitsBackendId: emitsBackendId, reqCapture: reqCapture, resumeFails: resumeFails)
        Task { await server.run() }
        return made.record(ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000))
    }, turnTimeoutOverrideNs: timeoutNs, gate: permGate, store: store ?? freshTempStore())
    return (bridge, made)
}

private func run(_ b: DabSessionBridge, _ text: String, channel: String = "c") async throws -> String {
    try await b.runTurn(channelId: channel, guildId: "g", ownerId: nil, text: text)
}

@Suite("DabSessionBridge")
struct DabSessionBridgeTests {
    @Test func happyPath() async throws {
        let (bridge, _) = makeDabBridge()
        #expect(try await run(bridge, "hi") == "ok:hi")
    }

    @Test func resultTextDedup() async throws {
        // .text streams "ok:hi"; .result carries the same text → must NOT double-append.
        let (bridge, _) = makeDabBridge(resultEchoesText: true)
        #expect(try await run(bridge, "hi") == "ok:hi")
    }

    @Test func serializationReentrancyIsolation() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeDabBridge(gate: gate)

        let tA = Task { try await run(bridge, "A") }
        await gate.waitReceived(1)
        let tB = Task { try await run(bridge, "B") }
        let tC = Task { try await run(bridge, "C") }

        await gate.release()
        let ra = try await tA.value
        await gate.waitReceived(2); await gate.release()
        await gate.waitReceived(3); await gate.release()
        let rb = try await tB.value
        let rc = try await tC.value

        #expect(ra == "ok:A")
        #expect(rb == "ok:B")
        #expect(rc == "ok:C")
        #expect(await gate.maxConcurrent == 1)
    }

    @Test func respawnAfterClose() async throws {
        let (bridge, made) = makeDabBridge()
        #expect(try await run(bridge, "one") == "ok:one")
        await made.last()?.close()                  // sidecar dies → next turn respawns + clears stale session
        #expect(try await run(bridge, "two") == "ok:two")
        #expect(made.count == 2)
    }

    @Test func factoryFailurePropagatesAndRetries() async throws {
        // Dab's connect() never throws with an injected transport, so the connect-close path is
        // defensive; the fake-triggerable init failure is a factory throw. It must propagate and
        // NOT be cached (next turn re-invokes makeClient).
        let calls = LockedBox(0)
        let made = MadeClients<ClaudeSidecarClient>()
        let bridge = DabSessionBridge(makeClient: {
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { throw SidecarRpcError(code: "internal", message: "spawn failed") }
            let pair = InMemorySidecarTransport.makePair()
            let server = GateableSidecar(transport: pair.sidecar, gate: nil)
            Task { await server.run() }
            return made.record(ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000))
        })
        await #expect(throws: (any Error).self) { try await run(bridge, "x") }
        #expect(try await run(bridge, "y") == "ok:y")   // not cached → retried successfully
    }

    @Test func backendErrorThrows() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeDabBridge(gate: gate)
        let t = Task { try await run(bridge, "x") }
        await gate.waitReceived(1)
        await gate.release(.fail("boom"))
        do {
            _ = try await t.value
            Issue.record("expected backend error")
        } catch let e as SidecarRpcError {
            #expect(e.message == "boom")
        }
    }

    @Test func turnTimeoutThrows() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeDabBridge(gate: gate, timeoutNs: 100_000_000)   // 100ms
        let t = Task { try await run(bridge, "x") }
        await gate.waitReceived(1)                  // held, no events → TurnBox timeout (no text) → throw
        await #expect(throws: (any Error).self) { _ = try await t.value }
    }

    // W11-c: permission_request event → Discord gate → session.permission with the owner's decision.
    @Test func permissionRequestAnsweredWithGateDecision() async throws {
        let gate = PermissionGate()
        let prompts = LockedBox<[PermissionPrompt]>([])
        await gate.setPresenter { p in prompts.withLock { $0.append(p) } }
        let capturePerm = LockedBox<[String: String]>([:])
        let (bridge, _) = makeDabBridge(permGate: gate, emitsPermission: true, capturePerm: capturePerm)

        let t = Task { try await bridge.runTurn(channelId: "c", guildId: "g", ownerId: "owner-1", text: "hi",
                                                config: SessionConfig(backend: .claude, permMode: "plan")) }
        while prompts.withLock({ $0.isEmpty }) { await Task.yield() }
        let prompt = prompts.withLock { $0[0] }
        #expect(prompt.toolName == "Bash")
        #expect(prompt.approverId == "owner-1")
        #expect(prompt.detail == "ls")
        // Owner approves → sidecar receives behavior "allow" → turn completes.
        #expect(await gate.resolve(reqKey: prompt.reqKey, action: .allow, byUserId: "owner-1") == true)
        let reply = try await t.value
        #expect(reply == "ok:hi")
        #expect(capturePerm.withLock { $0["behavior"] } == "allow")
    }

    // W11-c security: a non-owner cannot answer; only the session owner's click resolves.
    @Test func bystanderCannotApprove() async throws {
        let gate = PermissionGate()
        let prompts = LockedBox<[PermissionPrompt]>([])
        await gate.setPresenter { p in prompts.withLock { $0.append(p) } }
        let capturePerm = LockedBox<[String: String]>([:])
        let (bridge, _) = makeDabBridge(permGate: gate, emitsPermission: true, capturePerm: capturePerm)

        let t = Task { try await bridge.runTurn(channelId: "c", guildId: "g", ownerId: "owner-1", text: "hi",
                                                config: SessionConfig(backend: .claude, permMode: "plan")) }
        while prompts.withLock({ $0.isEmpty }) { await Task.yield() }
        let key = prompts.withLock { $0[0].reqKey }
        #expect(await gate.resolve(reqKey: key, action: .allow, byUserId: "intruder") == false)   // ignored
        #expect(capturePerm.withLock { $0["behavior"] } == nil)                                   // not answered yet
        #expect(await gate.resolve(reqKey: key, action: .deny, byUserId: "owner-1") == true)       // owner decides
        let reply = try await t.value
        #expect(reply == "ok:hi")
        #expect(capturePerm.withLock { $0["behavior"] } == "deny")
    }

    // T1 (core): backend id captured on notify → persisted → a fresh bridge sharing the store RESUMES
    // that exact session (session.resume, not session.start).
    @Test func t1_reconnectResumesSameSession() async throws {
        let store = freshTempStore()
        let (b1, _) = makeDabBridge(store: store, emitsBackendId: "B-123")
        _ = try await b1.runTurn(channelId: "c", guildId: "g", ownerId: "o", text: "hi", config: SessionConfig(backend: .claude))
        while await store.binding(channelId: "c")?.backendSessionId == nil { await Task.yield() }
        #expect(await store.binding(channelId: "c")?.backendSessionId == "B-123")

        let reqs = LockedBox<[String]>([])
        let (b2, _) = makeDabBridge(store: store, reqCapture: reqs)   // restart
        _ = try await b2.runTurn(channelId: "c", guildId: "g", ownerId: "o", text: "again", config: SessionConfig(backend: .claude))
        #expect(reqs.withLock { $0 }.contains("resume:B-123"))
        #expect(!reqs.withLock { $0 }.contains("start"))
    }

    // T3: start returns null → nothing persisted until the backend_id notify fires (no notify → no record).
    @Test func t3_noRecordWithoutBackendId() async throws {
        let store = freshTempStore()
        let (b, _) = makeDabBridge(store: store)   // emitsBackendId nil → no notify
        _ = try await b.runTurn(channelId: "c", guildId: "g", ownerId: "o", text: "hi", config: SessionConfig(backend: .claude))
        #expect(await store.binding(channelId: "c") == nil)
    }

    // T4: a stored session that fails to resume → fall back to a fresh start + one-time notice.
    @Test func t4_resumeFailureFallsBackWithNotice() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "c", PersistedSession(backend: .claude, backendSessionId: "STALE", cwd: "/x", guildId: "g", updatedAt: "t"))
        let reqs = LockedBox<[String]>([])
        let (b, _) = makeDabBridge(store: store, reqCapture: reqs, resumeFails: true)
        let reply = try await b.runTurn(channelId: "c", guildId: "g", ownerId: "o", text: "hi", config: SessionConfig(backend: .claude))
        #expect(reply.contains("이전 세션 복구 실패"))
        #expect(reply.hasSuffix("ok:hi"))
        #expect(reqs.withLock { $0 }.contains("resume-fail"))
        #expect(reqs.withLock { $0 }.contains("start"))   // fell back to a fresh start
    }

    // T6: stored model/effort are re-applied as the resume params (not lost across restart).
    @Test func t6_storedModelEffortReappliedOnResume() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "c", PersistedSession(backend: .claude, backendSessionId: "B-7", cwd: "/x", guildId: "g", model: "claude-x", effort: "high", updatedAt: "t"))
        let cap = LockedBox<[String: String]>([:])
        let (b, _) = makeDabBridge(capture: cap, store: store)
        _ = try await b.runTurn(channelId: "c", guildId: "g", ownerId: "o", text: "hi")   // no live config
        #expect(cap.withLock { $0["model"] } == "claude-x")
        #expect(cap.withLock { $0["effort"] } == "high")
    }

    // W11-b1: model/effort from the bound config reach session.start params (permMode stays env).
    @Test func configReachesSessionStartParams() async throws {
        let capture = LockedBox<[String: String]>([:])
        let (bridge, _) = makeDabBridge(capture: capture)
        let reply = try await bridge.runTurn(channelId: "c", guildId: "g", ownerId: nil, text: "hi",
                                             config: SessionConfig(backend: .claude, model: "claude-x", effort: "high"))
        #expect(reply == "ok:hi")
        let got = capture.withLock { $0 }
        #expect(got["model"] == "claude-x")
        #expect(got["effort"] == "high")
    }
}
