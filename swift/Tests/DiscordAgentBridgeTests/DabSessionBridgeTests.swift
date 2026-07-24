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
    private var counter = 0

    init(transport: InMemorySidecarTransport, gate: TurnGate?, resultEchoesText: Bool = false) {
        self.transport = transport
        self.gate = gate
        self.resultEchoesText = resultEchoesText
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
        case "session.start":
            counter += 1
            await writeEnv(res(id: id, method: method, result: .object([
                "session": .string("h\(counter)"), "backendSessionId": .null,
            ])))
        case "session.send":
            let session = env.session ?? env.params?["session"]?.stringValue ?? ""
            let text = env.params?["text"]?.stringValue ?? ""
            await writeEnv(res(id: id, method: method, result: .object(["ok": .bool(true)]), session: session))
            Task { await self.completeTurn(session: session, text: text) }   // non-blocking
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
    timeoutNs: UInt64? = nil
) -> (DabSessionBridge, MadeClients<ClaudeSidecarClient>) {
    let made = MadeClients<ClaudeSidecarClient>()
    let bridge = DabSessionBridge(makeClient: {
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableSidecar(transport: pair.sidecar, gate: gate, resultEchoesText: resultEchoesText)
        Task { await server.run() }
        return made.record(ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000))
    }, turnTimeoutOverrideNs: timeoutNs)
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
}
