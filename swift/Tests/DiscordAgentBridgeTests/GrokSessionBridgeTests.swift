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
    private let promptResultMeta: JSONValue?             // C7: session/prompt response `_meta`
    private let cwdCapture: LockedBox<[String]>?          // WO-1: records the cwd sent on session/new + session/load
    // WO-2 regression: push `activityCount` non-terminal `agent_thought_chunk` updates,
    // `activityIntervalNs` apart, before completing the turn — simulates a slow-but-alive turn.
    private let activityIntervalNs: UInt64?
    private let activityCount: Int

    init(transport: InMemorySidecarTransport, gate: TurnGate?, initFails: Bool = false, fixedChunks: [String]? = nil, backendIdCapture: LockedBox<[String]>? = nil, promptResultMeta: JSONValue? = nil, cwdCapture: LockedBox<[String]>? = nil, activityIntervalNs: UInt64? = nil, activityCount: Int = 0) {
        self.transport = transport
        self.gate = gate
        self.initFails = initFails
        self.fixedChunks = fixedChunks
        self.backendIdCapture = backendIdCapture
        self.promptResultMeta = promptResultMeta
        self.cwdCapture = cwdCapture
        self.activityIntervalNs = activityIntervalNs
        self.activityCount = activityCount
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
            if let c = msg["params"]?["cwd"]?.stringValue { cwdCapture?.withLock { $0.append(c) } }
            await writeResult(id, .object(["sessionId": .string("s1")]))
        case "session/load":
            let sid = msg["params"]?["sessionId"]?.stringValue ?? "?"
            backendIdCapture?.withLock { $0.append("load:\(sid)") }
            if let c = msg["params"]?["cwd"]?.stringValue { cwdCapture?.withLock { $0.append(c) } }
            await writeResult(id, .object([:]))
        case "session/prompt":
            let text = msg["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            Task {   // non-blocking
                if let activityIntervalNs, activityCount > 0 {
                    for _ in 0..<activityCount {
                        try? await Task.sleep(nanoseconds: activityIntervalNs)
                        await self.pushThought("tick")
                    }
                }
                await self.completeTurn(id: id, text: text)
            }
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
        var result: [String: JSONValue] = ["stopReason": .string("end_turn")]
        if let promptResultMeta { result["_meta"] = promptResultMeta }
        await writeResult(id, .object(result))
    }

    private func pushUpdate(_ text: String) async {
        await write(["method": .string("session/update"), "params": .object(["update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ])])])
    }
    /// WO-2 activity marker: `agent_thought_chunk` maps to `.thinking`, not the reply buffer, so it
    /// exercises the timeout-reset path without perturbing the expected `ok:<text>` result.
    private func pushThought(_ text: String) async {
        await write(["method": .string("session/update"), "params": .object(["update": .object([
            "sessionUpdate": .string("agent_thought_chunk"),
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
    configStore: ConfigStore? = nil,
    backendIdCapture: LockedBox<[String]>? = nil,
    cwdCapture: LockedBox<[String]>? = nil,
    attachGateway: any GrokAttachGatewayProviding = NoopAttachGateway(),
    mcpServersSpy: LockedBox<[[AcpMcpServerConfig]]>? = nil,
    promptResultMeta: JSONValue? = nil,
    configSource: GrokConfigSource? = nil,
    activityIntervalNs: UInt64? = nil,
    activityCount: Int = 0
) -> (GrokSessionBridge, MadeClients<GrokAcpClient>) {
    let made = MadeClients<GrokAcpClient>()
    let bridge = GrokSessionBridge(makeClient: { cfg, onPermission, mcpServers in
        configSpy?.withLock { $0.append(cfg) }   // Grok bakes model/effort/bypass at spawn from this config
        onPermissionSpy?.withLock { $0.append(onPermission) }
        mcpServersSpy?.withLock { $0.append(mcpServers) }
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableGrokServer(transport: pair.sidecar, gate: gate, initFails: initFails, fixedChunks: fixedChunks, backendIdCapture: backendIdCapture, promptResultMeta: promptResultMeta, cwdCapture: cwdCapture, activityIntervalNs: activityIntervalNs, activityCount: activityCount)
        Task { await server.run() }
        // Control timeout only; turn budget is bridge turnTimeoutOverrideNs / DAB_TURN_TIMEOUT_SEC.
        return made.record(GrokAcpClient(transport: pair.host, requestTimeoutMs: reqTimeoutMs, onPermission: onPermission))
    }, turnTimeoutOverrideNs: turnTimeoutOverrideNs, gate: permGate, store: store ?? freshTempStore(),
       // Isolate from the real ~/.discord-agent-bridge/config.json (DabSessionBridgeTests convention):
       // a shared-config autoAllowClaudeTools entry would short-circuit onPermission before it ever
       // reaches gate.await, starving tests that wait on the presenter.
       configStore: configStore ?? ConfigStore(baseDir: FileManager.default.temporaryDirectory
           .appendingPathComponent("grok-cfg-missing-\(UUID().uuidString)", isDirectory: true)),
       attachGateway: attachGateway,
       // C7: isolate from the real ~/.grok/models_cache.json (same reasoning as configStore above) —
       // a nonexistent grokHome makes contextWindow/defaultModel fall back to static values, never
       // reading this machine's actual Grok install.
       configSource: configSource ?? GrokConfigSource(grokHome: FileManager.default.temporaryDirectory
           .appendingPathComponent("grok-home-missing-\(UUID().uuidString)", isDirectory: true).path))
    return (bridge, made)
}

// .serialized: `productionSpawnEnvironmentIncludesWellKnownPathDirs` below mutates the process-wide
// `GROK_CMD` env var, which `configReachesSpawnFactory`'s bare `resolveGrokSpawn(...)` call (no
// explicit `env:`) also reads — without serialization the two race (WO-13).
@Suite("GrokSessionBridge", .serialized)
struct GrokSessionBridgeTests {
    @Test func happyPath() async throws {
        let (bridge, _) = makeGrokBridge()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.text == "ok:hi")
    }

    // WO-1: a channel-bound cwd must reach session/new instead of the global cwd fallback.
    @Test func persistedCwdReachesSessionNew() async throws {
        let store = freshTempStore()
        try await store.upsert(channelId: "c", PersistedSession(
            backend: .grok, cwd: "/persisted/project", guildId: "g", updatedAt: "t"
        ))
        let cwdCapture = LockedBox<[String]>([])
        let (bridge, _) = makeGrokBridge(store: store, cwdCapture: cwdCapture)
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.text == "ok:hi")
        #expect(cwdCapture.withLock { $0 } == ["/persisted/project"])
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

    // WO-2 regression: activity (any notification — here `agent_thought_chunk`) pushes the
    // hang-timeout window back out on every event, so a turn whose total wall-clock time is many
    // multiples of a short override still completes normally as long as SOME notification keeps
    // arriving before each window elapses. Complements `turnTimeoutThrows` above (zero activity →
    // times out exactly).
    @Test func activityResetsTimeoutWindow() async throws {
        // Wide margin between the per-tick interval and the timeout window (20ms vs. 400ms):
        // short fixed sleeps flake under a CPU-saturated parallel `swift test` run — a single
        // delayed tick must not eat the whole window.
        let (bridge, _) = makeGrokBridge(turnTimeoutOverrideNs: 400_000_000, activityIntervalNs: 20_000_000, activityCount: 30)
        let start = Date()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        let elapsedNs = UInt64(max(0, -start.timeIntervalSinceNow) * 1_000_000_000)
        #expect(reply.text == "ok:hi")
        #expect(elapsedNs > 500_000_000)   // outlived the 400ms window
    }

    // M7 (security regression): no bound permMode is a safe default (approval required), not
    // auto-approve — TS `sessionOrchestrator.ts:817` defaults an unbound session to `'default'`.
    @Test func grokBypassPermModeNilDefaultsToSafe() {
        #expect(grokBypassPermMode(nil) == false)
        #expect(grokBypassPermMode("") == false)
        #expect(grokBypassPermMode("default") == false)
        #expect(grokBypassPermMode("bypassPermissions") == true)
        #expect(grokBypassPermMode("danger-full-access") == true)
    }

    // M7: an unbound channel (no config → nil permMode) routes through the Discord permission
    // gate instead of spawning with `--always-approve`.
    @Test func nilConfigInstallsPermissionHandlerNotBypass() async throws {
        let spy = LockedBox<[AcpPermissionHandler?]>([])
        let (bridge, _) = makeGrokBridge(onPermissionSpy: spy)
        _ = try await bridge.runTurn(channelId: "c", text: "hi")   // no config → nil permMode
        #expect(spy.withLock { $0.first ?? nil } != nil)
    }

    // H8: a persisted profile name is re-resolved from the LIVE config at session start — a stale
    // stored permMode does not win once a profile is bound (TS permissionResolver.resolve()).
    @Test func profilePermissionModeReresolvedFromLiveConfigAtSessionStart() async throws {
        let cfg = ConfigStore(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-h8-cfg-\(UUID().uuidString)", isDirectory: true))
        try await cfg.save(AppConfig(
            discord: DiscordSecrets(token: "t", clientId: "c"),
            profiles: ["yolo": Profile(permissionMode: "bypassPermissions", allowedTools: [], policyTier: "relaxed")]
        ))
        let store = freshTempStore()
        // Stale stored permMode ("default", approval-required) predates a later profile edit.
        try await store.upsert(channelId: "c", PersistedSession(
            backend: .grok, cwd: "/x", guildId: "g", permMode: "default", permissionProfile: "yolo", updatedAt: "t"
        ))
        let spy = LockedBox<[AcpPermissionHandler?]>([])
        let (bridge, _) = makeGrokBridge(onPermissionSpy: spy, store: store, configStore: cfg)
        _ = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok, permMode: "default"))

        // Bypass (no handler) — the profile's permissionMode won, not the stale "default".
        #expect(spy.withLock { $0.first ?? nil } == nil)
        // The re-resolved mode is what gets persisted going forward.
        #expect(await store.binding(channelId: "c")?.permMode == "bypassPermissions")
    }

    // M2 (WO-15): a bound profile name that no longer exists in config blocks the session start
    // (TS permissionResolver.ts:66-70) instead of silently falling back to the stale persisted
    // permMode — mirrors CodexSessionBridgeTests.unknownBoundProfileBlocksSessionStart /
    // DabSessionBridgeTests.deletedProfileReferenceThrows.
    @Test func unknownBoundProfileBlocksSessionStart() async throws {
        let cfg = ConfigStore(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-m2-cfg-\(UUID().uuidString)", isDirectory: true))
        try await cfg.save(AppConfig(discord: DiscordSecrets(token: "t", clientId: "c")))   // no profiles
        let store = freshTempStore()
        try await store.upsert(channelId: "c", PersistedSession(
            backend: .grok, cwd: "/x", guildId: "g", permissionProfile: "ghost", updatedAt: "t"
        ))
        let (bridge, _) = makeGrokBridge(store: store, configStore: cfg)
        do {
            _ = try await bridge.runTurn(channelId: "c", text: "hi")
            Issue.record("expected unknown profile error")
        } catch let e as AcpClientError {
            #expect(e.message == "Unknown permission profile 'ghost'.")
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

    // C7: session/prompt response `_meta.totalTokens`/`modelId` + the bound session model reach
    // TurnResult.contextUsage (TS acpSession.ts:385-398 emitResult).
    @Test func contextUsageReachesTurnResult() async throws {
        let configSource = fakeGrokConfigSource(contextWindows: ["grok-4": 128_000])
        let (bridge, _) = makeGrokBridge(
            promptResultMeta: .object(["totalTokens": .number(64_000), "modelId": .string("grok-4")]),
            configSource: configSource
        )
        let reply = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok, model: "grok-4"))
        #expect(reply.contextUsage?.totalTokens == 64_000)
        #expect(reply.contextUsage?.maxTokens == 128_000)
        #expect(reply.contextUsage?.percentage == 50)
        #expect(reply.contextUsage?.model == "grok-4")
    }

    // No model bound on the session → falls to the response's own modelId (TS
    // `this.model.length > 0 ? this.model : result?.modelId ?? grokConfigSource.defaultModel()`).
    @Test func contextUsageFallsBackToResponseModelIdWhenSessionModelUnset() async throws {
        let configSource = fakeGrokConfigSource(contextWindows: ["grok-9": 200_000])
        let (bridge, _) = makeGrokBridge(
            promptResultMeta: .object(["totalTokens": .number(100_000), "modelId": .string("grok-9")]),
            configSource: configSource
        )
        let reply = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok))
        #expect(reply.contextUsage?.model == "grok-9")
        #expect(reply.contextUsage?.maxTokens == 200_000)
    }

    // No `_meta` at all on the prompt response (the default fake server behavior) → no panel.
    @Test func contextUsageNilWhenNoMeta() async throws {
        let (bridge, _) = makeGrokBridge()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.contextUsage == nil)
    }

    // totalTokens present but the model's context window is unknown → skip the panel rather than
    // a 0-denominator gauge (TS parity comment, acpSession.ts:389).
    @Test func contextUsageNilWhenModelContextWindowUnknown() async throws {
        let configSource = fakeGrokConfigSource(contextWindows: [:])
        let (bridge, _) = makeGrokBridge(
            promptResultMeta: .object(["totalTokens": .number(500)]),
            configSource: configSource
        )
        let reply = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .grok, model: "grok-unknown"))
        #expect(reply.contextUsage == nil)
    }

    // MARK: - WO-13: production spawn wiring (grokChildEnvironment reaches the real child process)

    /// Every other test above injects `makeClient`, bypassing the PRODUCTION closure entirely. This
    /// one deliberately leaves `makeClient` at its default so the real `resolveGrokSpawn` →
    /// `grokChildEnvironment()` → `GrokAcpClient(environment:)` wiring runs end to end. `GROK_CMD` is
    /// redirected (env var, not a fake `makeClient`) to a throwaway script that dumps its inherited
    /// `$PATH` to a file and exits — no real `grok` binary or ACP handshake required; the bridge's
    /// `initialize()` call fails right after (child already gone), which the test ignores via `try?`.
    /// Lives in this `.serialized` suite (not its own) so it can't race `configReachesSpawnFactory`'s
    /// bare `resolveGrokSpawn(...)` call over the shared `GROK_CMD` env var.
    @Test func productionSpawnEnvironmentIncludesWellKnownPathDirs() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-spawn-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let outFile = tmpDir.appendingPathComponent("captured-path.txt")
        let scriptPath = tmpDir.appendingPathComponent("fake-grok").path
        let script = "#!/bin/sh\necho \"$PATH\" > \"\(outFile.path)\"\nexit 1\n"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        setenv("GROK_CMD", scriptPath, 1)
        defer { unsetenv("GROK_CMD") }

        // Omitting `makeClient:` runs the production default closure this WO wired up; store/
        // configStore/attachGateway/configSource stay isolated per the `makeGrokBridge` convention.
        let bridge = GrokSessionBridge(
            store: freshTempStore(),
            configStore: ConfigStore(baseDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("grok-cfg-\(UUID().uuidString)", isDirectory: true)),
            attachGateway: NoopAttachGateway(),
            configSource: GrokConfigSource(grokHome: FileManager.default.temporaryDirectory
                .appendingPathComponent("grok-home-\(UUID().uuidString)", isDirectory: true).path)
        )
        _ = try? await bridge.runTurn(channelId: "c", text: "hi")

        let sawFile = await waitUntil { FileManager.default.fileExists(atPath: outFile.path) }
        #expect(sawFile)
        let captured = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        let dirs = captured.split(separator: ":").map(String.init)
        #expect(dirs.contains { $0.hasSuffix("/.local/bin") })
    }
}

/// Fake `GrokConfigSource` serving an in-memory `models_cache.json` (id → context_window), isolated
/// from the real filesystem (C7 — mirrors the `configStore` isolation convention above).
private func fakeGrokConfigSource(contextWindows: [String: Int]) -> GrokConfigSource {
    let entries = contextWindows.map { id, window in
        "\"\(id)\":{\"info\":{\"id\":\"\(id)\",\"context_window\":\(window)}}"
    }.joined(separator: ",")
    let raw = "{\"models\":{\(entries)}}"
    return GrokConfigSource(
        readFile: { path in
            guard path.hasSuffix("models_cache.json") else { throw CocoaError(.fileReadNoSuchFile) }
            return raw
        },
        statMtime: { path in
            guard path.hasSuffix("models_cache.json") else { throw CocoaError(.fileReadNoSuchFile) }
            return Date(timeIntervalSince1970: 1)
        },
        grokHome: "/nonexistent-grok-home-for-test"
    )
}
