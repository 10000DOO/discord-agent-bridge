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
    turnTimeoutOverrideNs: UInt64? = nil,
    configSpy: LockedBox<[SessionConfig?]>? = nil,
    permGate: PermissionGate = .shared,
    onPermissionSpy: LockedBox<[AcpPermissionHandler?]>? = nil,
    store: SessionStore? = nil,
    backendIdCapture: LockedBox<[String]>? = nil,
    attachGateway: any GrokAttachGatewayProviding = NoopAttachGateway(),
    mcpServersSpy: LockedBox<[[AcpMcpServerConfig]]>? = nil
) -> (GrokSessionBridge, MadeClients<GrokAcpClient>) {
    let made = MadeClients<GrokAcpClient>()
    let bridge = GrokSessionBridge(makeClient: { cfg, onPermission, mcpServers in
        configSpy?.withLock { $0.append(cfg) }   // Grok bakes model/effort/bypass at spawn from this config
        onPermissionSpy?.withLock { $0.append(onPermission) }
        mcpServersSpy?.withLock { $0.append(mcpServers) }
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableGrokServer(transport: pair.sidecar, gate: gate, initFails: initFails, fixedChunks: fixedChunks, backendIdCapture: backendIdCapture)
        Task { await server.run() }
        // Control timeout only; turn budget is bridge turnTimeoutOverrideNs / DAB_TURN_TIMEOUT_SEC.
        return made.record(GrokAcpClient(transport: pair.host, requestTimeoutMs: reqTimeoutMs, onPermission: onPermission))
    }, turnTimeoutOverrideNs: turnTimeoutOverrideNs, gate: permGate, store: store ?? freshTempStore(), attachGateway: attachGateway)
    return (bridge, made)
}

@Suite("GrokSessionBridge")
struct GrokSessionBridgeTests {
    @Test func happyPath() async throws {
        let (bridge, _) = makeGrokBridge()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.text == "ok:hi")
    }

    @Test func multiChunkSyncFold() async throws {
        let (bridge, _) = makeGrokBridge(fixedChunks: ["Hel", "lo"])
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.text == "Hello")   // session/update chunks folded before sessionPrompt returns
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

        #expect(ra.text == "ok:A")
        #expect(rb.text == "ok:B")
        #expect(rc.text == "ok:C")
        #expect(await gate.maxConcurrent == 1)
    }

    @Test func respawnAfterClose() async throws {
        let (bridge, made) = makeGrokBridge()
        let r1 = try await bridge.runTurn(channelId: "c", text: "one")
        #expect(r1.text == "ok:one")
        await made.last()?.close()
        let r2 = try await bridge.runTurn(channelId: "c", text: "two")
        #expect(r2.text == "ok:two")
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
        // Bridge turn budget 200ms (client control timeout stays long; session/prompt has none).
        let (bridge, _) = makeGrokBridge(gate: gate, turnTimeoutOverrideNs: 200_000_000)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "x") }
        await gate.waitReceived(1)                  // held, never released → bridge turn times out
        do {
            _ = try await t.value
            Issue.record("expected turn timeout")
        } catch let e as AcpClientError {
            #expect(e.message.contains("timed out"))
        }
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

    // W14: stop closes + drops live map; interrupt dropClient but store keeps resume id for reload.
    @Test func stopClosesAndDropsChannel() async throws {
        let (bridge, made) = makeGrokBridge()
        #expect(try await bridge.runTurn(channelId: "c", text: "hi").text == "ok:hi")
        #expect(await bridge.isLive(channelId: "c") == true)
        await bridge.stop(channelId: "c")
        #expect(await bridge.isLive(channelId: "c") == false)
        #expect(made.last()?.isClosed == true)
    }

    @Test func interruptDropsClientKeepsResumeCapability() async throws {
        let store = freshTempStore()
        let (bridge, made) = makeGrokBridge(store: store)
        #expect(try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok)).text == "ok:hi")
        #expect(await store.binding(channelId: "c")?.backendSessionId == "s1")
        #expect(await bridge.interrupt(channelId: "c") == true)
        #expect(await bridge.isLive(channelId: "c") == false)
        #expect(made.last()?.isClosed == true)
        // Store still has resume id (lifecycle did not remove it) → next turn session/loads.
        #expect(await store.binding(channelId: "c")?.backendSessionId == "s1")

        let ids = LockedBox<[String]>([])
        let (b2, _) = makeGrokBridge(store: store, backendIdCapture: ids)
        _ = try await b2.runTurn(channelId: "c", text: "again", config: SessionConfig(backend: .grok))
        #expect(ids.withLock { $0 }.contains("load:s1"))
    }

    @Test func interruptWhenIdleReturnsFalse() async throws {
        let (bridge, _) = makeGrokBridge()
        #expect(await bridge.interrupt(channelId: "c") == false)
    }

    // C5: every (re)spawn hands the client a "discord" attach_file/share_document MCP server
    // (TS acpSession.ts buildMcpServers), and the per-channel token it registers with the gateway
    // is only valid while that channel stays live.
    @Test func mcpServersCarryDiscordAttachServer() async throws {
        let spy = LockedBox<[[AcpMcpServerConfig]]>([])
        let (bridge, _) = makeGrokBridge(mcpServersSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", text: "hi")

        let servers = spy.withLock { $0 }.first ?? []
        #expect(servers.count == 1)
        #expect(servers.first?.name == "discord")
        #expect(servers.first?.args == ["attach-mcp"])
        let envNames = Set(servers.first?.env?.map { $0.name } ?? [])
        #expect(envNames == ["DAB_ATTACH_URL", "DAB_ATTACH_TOKEN", "DAB_WORKSPACE"])
    }

    @Test func stopUnregistersAttachTokenFromGateway() async throws {
        let gateway = GrokAttachGateway()
        let spy = LockedBox<[[AcpMcpServerConfig]]>([])
        let (bridge, _) = makeGrokBridge(attachGateway: gateway, mcpServersSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", text: "hi")

        let servers = spy.withLock { $0 }.first ?? []
        let token = servers.first?.env?.first(where: { $0.name == "DAB_ATTACH_TOKEN" })?.value
        #expect(token != nil)

        let base = await gateway.baseURL
        let (statusBefore, _) = try await postAttachGatewayJSON(
            base + "/attach", body: ["token": .string(token ?? ""), "path": .string(".")]
        )
        #expect(statusBefore != 401)   // token still registered while the channel is live

        await bridge.stop(channelId: "c")

        let (statusAfter, bodyAfter) = try await postAttachGatewayJSON(
            base + "/attach", body: ["token": .string(token ?? ""), "path": .string(".")]
        )
        #expect(statusAfter == 401)
        #expect(bodyAfter["ok"]?.boolValue == false)
    }

    @Test func respawnAfterInterruptRotatesAttachToken() async throws {
        let gateway = GrokAttachGateway()
        let spy = LockedBox<[[AcpMcpServerConfig]]>([])
        let store = freshTempStore()
        let (bridge, _) = makeGrokBridge(store: store, attachGateway: gateway, mcpServersSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok))
        _ = await bridge.interrupt(channelId: "c")
        _ = try await bridge.runTurn(channelId: "c", text: "again", config: SessionConfig(backend: .grok))

        let captured = spy.withLock { $0 }
        #expect(captured.count == 2)
        let tokenBefore = captured[0].first?.env?.first(where: { $0.name == "DAB_ATTACH_TOKEN" })?.value
        let tokenAfter = captured[1].first?.env?.first(where: { $0.name == "DAB_ATTACH_TOKEN" })?.value
        #expect(tokenBefore != nil && tokenAfter != nil)
        #expect(tokenBefore != tokenAfter)   // fresh token per respawn (TS buildMcpServers)

        // The stale token is dropped once the fresh one is registered (unregisterAttach() runs
        // at the top of buildMcpServers before the new register()) — only one live per channel.
        let base = await gateway.baseURL
        let (statusOld, _) = try await postAttachGatewayJSON(
            base + "/attach", body: ["token": .string(tokenBefore ?? ""), "path": .string(".")]
        )
        #expect(statusOld == 401)
    }

    @Test func buildGrokPromptBlocksSendsImageAsBase64BlockAndKeepsNonImageAsHint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dab-grok-blocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let imgPath = dir.appendingPathComponent("pic.png").path
        let imgBytes = Data([9, 9, 9])
        try imgBytes.write(to: URL(fileURLWithPath: imgPath))
        let docPath = dir.appendingPathComponent("note.txt").path

        let blocks = try buildGrokPromptBlocks(
            text: "hi",
            files: [TurnFile(path: imgPath, mime: nil), TurnFile(path: docPath, mime: "text/plain")]
        )
        #expect(blocks == [
            .text("hi\n\nAttached file: \(docPath)"),
            .image(data: imgBytes.base64EncodedString(), mimeType: "image/png"),
        ])
    }

    @Test func buildGrokPromptBlocksNonImageOnlyStaysSingleTextBlock() throws {
        let blocks = try buildGrokPromptBlocks(text: "hi", files: [TurnFile(path: "/x/note.txt", mime: "text/plain")])
        #expect(blocks == [.text("hi\n\nAttached file: /x/note.txt")])
    }
}
