import Testing
import Foundation
@testable import DiscordAgentBridge

/// Gateable fake `grok agent stdio`. Completion is the session/prompt RESPONSE (released by the
/// gate); session/update text chunks are streamed BEFORE the response. Read loop never blocks, so a
/// reentrancy bug shows as concurrent session/prompt (gate.maxConcurrent > 1). Echoes "ok:<text>".
private actor GateableGrokServer {
    private let transport: InMemorySidecarTransport
    private let gate: TurnGate?
    private let initFails: Bool
    private let fixedChunks: [String]?
    private let backendIdCapture: LockedBox<[String]>?   // records "new" / "load:<sessionId>"

    init(transport: InMemorySidecarTransport, gate: TurnGate?, initFails: Bool = false, fixedChunks: [String]? = nil, backendIdCapture: LockedBox<[String]>? = nil) {
        self.transport = transport
        self.gate = gate
        self.initFails = initFails
        self.fixedChunks = fixedChunks
        self.backendIdCapture = backendIdCapture
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
                await writeResult(id, .object(["protocolVersion": .number(1), "serverInfo": .object(["name": .string("fake-grok")])]))
            }
        case "session/new":
            backendIdCapture?.withLock { $0.append("new") }
            await writeResult(id, .object(["sessionId": .string("s1")]))
        case "session/load":
            let sid = msg["params"]?["sessionId"]?.stringValue ?? "?"
            backendIdCapture?.withLock { $0.append("load:\(sid)") }
            await writeResult(id, .object([:]))
        case "session/prompt":
            let text = msg["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            Task { await self.completeTurn(id: id, text: text) }   // non-blocking
        default:
            await writeError(id, "method not found: \(method)")
        }
    }

    private func completeTurn(id: JSONValue, text: String) async {
        let outcome = gate == nil ? .ok : await gate!.submit()
        if case .fail(let m) = outcome {
            await writeError(id, m)                 // prompt response error = turn failure
            return
        }
        for chunk in fixedChunks ?? ["ok:\(text)"] {
            await pushUpdate(chunk)
        }
        await writeResult(id, .object(["stopReason": .string("end_turn")]))
    }

    private func pushUpdate(_ text: String) async {
        await write(["method": .string("session/update"), "params": .object(["update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ])])])
    }
    private func writeResult(_ id: JSONValue, _ result: JSONValue) async {
        await write(["id": id, "result": result])
    }
    private func writeError(_ id: JSONValue, _ message: String) async {
        await write(["id": id, "error": .object(["code": .number(-32000), "message": .string(message)])])
    }
    private func write(_ obj: [String: JSONValue]) async {
        guard let d = try? JSONEncoder().encode(JSONValue.object(obj)), let s = String(data: d, encoding: .utf8) else { return }
        try? await transport.writeLine(s + "\n")
    }
}

private func makeGrokBridge(
    gate: TurnGate? = nil,
    initFails: Bool = false,
    fixedChunks: [String]? = nil,
    reqTimeoutMs: Int = 5_000,
    configSpy: LockedBox<[SessionConfig?]>? = nil,
    permGate: PermissionGate = .shared,
    onPermissionSpy: LockedBox<[AcpPermissionHandler?]>? = nil,
    store: SessionStore? = nil,
    backendIdCapture: LockedBox<[String]>? = nil
) -> (GrokSessionBridge, MadeClients<GrokAcpClient>) {
    let made = MadeClients<GrokAcpClient>()
    let bridge = GrokSessionBridge(makeClient: { cfg, onPermission in
        configSpy?.withLock { $0.append(cfg) }   // Grok bakes model/effort/bypass at spawn from this config
        onPermissionSpy?.withLock { $0.append(onPermission) }
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableGrokServer(transport: pair.sidecar, gate: gate, initFails: initFails, fixedChunks: fixedChunks, backendIdCapture: backendIdCapture)
        Task { await server.run() }
        return made.record(GrokAcpClient(transport: pair.host, requestTimeoutMs: reqTimeoutMs, onPermission: onPermission))
    }, gate: permGate, store: store ?? freshTempStore())
    return (bridge, made)
}

@Suite("GrokSessionBridge")
struct GrokSessionBridgeTests {
    @Test func happyPath() async throws {
        let (bridge, _) = makeGrokBridge()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply == "ok:hi")
    }

    @Test func multiChunkSyncFold() async throws {
        let (bridge, _) = makeGrokBridge(fixedChunks: ["Hel", "lo"])
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply == "Hello")   // session/update chunks folded before sessionPrompt returns
    }

    @Test func serializationReentrancyIsolation() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeGrokBridge(gate: gate)

        let tA = Task { try await bridge.runTurn(channelId: "c", text: "A") }
        await gate.waitReceived(1)
        let tB = Task { try await bridge.runTurn(channelId: "c", text: "B") }
        let tC = Task { try await bridge.runTurn(channelId: "c", text: "C") }

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
        let (bridge, made) = makeGrokBridge()
        let r1 = try await bridge.runTurn(channelId: "c", text: "one")
        #expect(r1 == "ok:one")
        await made.last()?.close()
        let r2 = try await bridge.runTurn(channelId: "c", text: "two")
        #expect(r2 == "ok:two")
        #expect(made.count == 2)
    }

    @Test func initFailureClosesClient() async throws {
        let (bridge, made) = makeGrokBridge(initFails: true)
        await #expect(throws: (any Error).self) { try await bridge.runTurn(channelId: "c", text: "x") }
        #expect(made.last()?.isClosed == true)
    }

    @Test func backendErrorThrows() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeGrokBridge(gate: gate)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "x") }
        await gate.waitReceived(1)
        await gate.release(.fail("boom"))
        do {
            _ = try await t.value
            Issue.record("expected backend error")
        } catch let e as AcpClientError {
            #expect(e.message.contains("boom"))
        }
    }

    @Test func turnTimeoutThrows() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeGrokBridge(gate: gate, reqTimeoutMs: 200)   // client request timeout
        let t = Task { try await bridge.runTurn(channelId: "c", text: "x") }
        await gate.waitReceived(1)                  // held, never released → client times out
        await #expect(throws: (any Error).self) { _ = try await t.value }
    }

    // W11-c: bypass permMode → no permission handler; non-bypass → handler routes allow→allow.
    @Test func bypassPermModeInstallsNoHandler() async throws {
        let spy = LockedBox<[AcpPermissionHandler?]>([])
        let (bridge, _) = makeGrokBridge(onPermissionSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok, permMode: "bypassPermissions"))
        #expect(spy.withLock { $0.first ?? nil } == nil)
    }

    @Test func nonBypassPermModeHandlerAllowMapsToAllow() async throws {
        let gate = PermissionGate()
        let prompts = LockedBox<[PermissionPrompt]>([])
        await gate.setPresenter { p in prompts.withLock { $0.append(p) } }
        let spy = LockedBox<[AcpPermissionHandler?]>([])
        let (bridge, _) = makeGrokBridge(permGate: gate, onPermissionSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", ownerId: "owner-1", text: "hi", config: SessionConfig(backend: .grok, permMode: "plan"))

        let handler = spy.withLock { $0.first ?? nil }
        #expect(handler != nil)
        let decision = LockedBox<AcpPermissionDecision?>(nil)
        let t = Task {
            let d = await handler!(AcpPermissionRequest(requestId: .number(1), toolName: "Bash"))
            decision.withLock { $0 = d }
        }
        while prompts.withLock({ $0.isEmpty }) { await Task.yield() }
        #expect(prompts.withLock { $0[0].approverId } == "owner-1")
        #expect(await gate.resolve(reqKey: prompts.withLock { $0[0].reqKey }, action: .allow, byUserId: "owner-1") == true)
        _ = await t.value
        #expect(decision.withLock { $0 } == .allow)
    }

    // T2 (Grok): first turn persists sessionId; a fresh bridge sharing the store session/load-s it.
    @Test func t2_reconnectLoadsSession() async throws {
        let store = freshTempStore()
        let (b1, _) = makeGrokBridge(store: store)
        _ = try await b1.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok))
        #expect(await store.binding(channelId: "c")?.backendSessionId == "s1")

        let ids = LockedBox<[String]>([])
        let (b2, _) = makeGrokBridge(store: store, backendIdCapture: ids)   // restart
        _ = try await b2.runTurn(channelId: "c", text: "again", config: SessionConfig(backend: .grok))
        #expect(ids.withLock { $0 }.contains("load:s1"))
        #expect(!ids.withLock { $0 }.contains("new"))
    }

    // W11-b1: the bound config reaches the spawn factory (Grok bakes model/effort at spawn).
    @Test func configReachesSpawnFactory() async throws {
        let spy = LockedBox<[SessionConfig?]>([])
        let (bridge, _) = makeGrokBridge(configSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok, model: "grok-4", effort: "high"))
        let got = spy.withLock { $0 }
        #expect(got.count == 1)
        #expect(got.first??.model == "grok-4")
        #expect(got.first??.effort == "high")
        // And the pure spawn builder turns those into CLI flags:
        let spawn = resolveGrokSpawn(model: "grok-4", effort: "high", bypassPermissions: true)
        #expect(spawn.args.contains("-m") && spawn.args.contains("grok-4"))
        #expect(spawn.args.contains("--reasoning-effort") && spawn.args.contains("high"))
    }
}
