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
    private let backendIdCapture: LockedBox<[String]>?  // records "start" / "resume:<threadId>"
    private let responseCapture: LockedBox<[JSONValue]>?  // C3: client's responses (id+result/error, no method)

    init(transport: InMemorySidecarTransport, gate: TurnGate?, initFails: Bool = false, completion: Completion = .delta, capture: LockedBox<[String: String]>? = nil, backendIdCapture: LockedBox<[String]>? = nil, responseCapture: LockedBox<[JSONValue]>? = nil) {
        self.transport = transport
        self.gate = gate
        self.initFails = initFails
        self.completion = completion
        self.capture = capture
        self.backendIdCapture = backendIdCapture
        self.responseCapture = responseCapture
    }

    func run() async {
        do { for try await line in transport.lines { await handle(line) } } catch {}
    }

    private func handle(_ line: String) async {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let msg) = v
        else { return }

        // C3: client's response to a server-initiated request (item/tool/call) — id + result/error, no method.
        if msg["method"] == nil, msg["id"] != nil, msg["result"] != nil || msg["error"] != nil {
            responseCapture?.withLock { $0.append(v) }
            return
        }
        guard let method = msg["method"]?.stringValue, let id = msg["id"] else { return }

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
            if let names = msg["params"]?["dynamicTools"]?.arrayValue?.compactMap({ $0["name"]?.stringValue }) {
                capture?.withLock { $0["dynamicTools"] = names.joined(separator: ",") }
            }
            backendIdCapture?.withLock { $0.append("start") }
            await writeResult(id, .object(["thread": .object(["id": .string("t1")])]))
        case "thread/resume":
            let tid = msg["params"]?["threadId"]?.stringValue ?? "?"
            backendIdCapture?.withLock { $0.append("resume:\(tid)") }
            await writeResult(id, .object([:]))
        case "turn/start":
            let text = msg["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            if let e = msg["params"]?["effort"]?.stringValue { capture?.withLock { $0["turnEffort"] = e } }
            if let m = msg["params"]?["model"]?.stringValue { capture?.withLock { $0["turnModel"] = m } }
            await writeResult(id, .object(["turn": .object(["id": .string("u1")])]))
            Task { await self.completeTurn(text: text) }   // non-blocking: read loop keeps counting
        case "turn/interrupt":
            if let tid = msg["params"]?["threadId"]?.stringValue { capture?.withLock { $0["interruptThread"] = tid } }
            if let uid = msg["params"]?["turnId"]?.stringValue { capture?.withLock { $0["interruptTurn"] = uid } }
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
    /// H2 test seam: push an arbitrary notification straight through (bypassing the
    /// gate/completion path) — used to simulate a stale `turn/completed` from an already-finished
    /// turn racing a still-in-flight one.
    func pushRawNotification(method: String, params: JSONValue) async {
        await pushNotification(method, params)
    }

    /// C3 test seam: push a server-initiated `item/tool/call` request to the client.
    func pushToolCall(id: Int, tool: String, arguments: JSONValue, callId: String, threadId: String, turnId: String) async {
        await write([
            "id": .number(Double(id)),
            "method": .string("item/tool/call"),
            "params": .object([
                "tool": .string(tool),
                "arguments": arguments,
                "callId": .string(callId),
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ]),
        ])
    }
    private func write(_ obj: [String: JSONValue]) async {
        guard let d = try? JSONEncoder().encode(JSONValue.object(obj)), let s = String(data: d, encoding: .utf8) else { return }
        try? await transport.writeLine(s + "\n")
    }
}

/// A `ConfigStore` backed by a unique temp dir (no config.json) — isolates each bridge test from
/// the shared store and the real config file (mirrors `freshTempStore` for `SessionStore`).
private func freshTempConfigStore() -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-bridge-config-\(UUID().uuidString)", isDirectory: true)
    return ConfigStore(baseDir: dir)
}

private func makeCodexBridge(
    gate: TurnGate? = nil,
    initFails: Bool = false,
    completion: GateableCodexServer.Completion = .delta,
    timeoutNs: UInt64? = nil,
    codexTimeoutMs: Int? = nil,
    capture: LockedBox<[String: String]>? = nil,
    permGate: PermissionGate = .shared,
    onApprovalSpy: LockedBox<[AppServerApprovalHandler?]>? = nil,
    store: SessionStore? = nil,
    configStore: ConfigStore? = nil,
    backendIdCapture: LockedBox<[String]>? = nil,
    responseCapture: LockedBox<[JSONValue]>? = nil,
    fileAttachHost: FileAttachHost = FileAttachHost(),
    documentShareHost: DocumentShareHost = DocumentShareHost(),
    serverBox: LockedBox<GateableCodexServer?>? = nil
) -> (CodexSessionBridge, MadeClients<CodexAppServerClient>) {
    let made = MadeClients<CodexAppServerClient>()
    let bridge = CodexSessionBridge(makeClient: { onApproval in
        onApprovalSpy?.withLock { $0.append(onApproval) }
        let pair = InMemorySidecarTransport.makePair()
        let server = GateableCodexServer(transport: pair.sidecar, gate: gate, initFails: initFails, completion: completion, capture: capture, backendIdCapture: backendIdCapture, responseCapture: responseCapture)
        serverBox?.withLock { $0 = server }
        Task { await server.run() }
        return made.record(CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000, onApproval: onApproval))
    }, turnTimeoutOverrideNs: timeoutNs, codexTimeoutMs: codexTimeoutMs, gate: permGate, store: store ?? freshTempStore(), configStore: configStore ?? freshTempConfigStore(), fileAttachHost: fileAttachHost, documentShareHost: documentShareHost)
    return (bridge, made)
}

@Suite("CodexSessionBridge")
struct CodexSessionBridgeTests {
    @Test func happyPath() async throws {
        let (bridge, _) = makeCodexBridge()
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.text == "ok:hi")
    }

    @Test func fullTextFallbackAccumulation() async throws {
        let (bridge, _) = makeCodexBridge(completion: .fullText)
        let reply = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(reply.text == "ok:hi")
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

        #expect(ra.text == "ok:A")
        #expect(rb.text == "ok:B")   // each turn returns its OWN text → no buffer cross-talk
        #expect(rc.text == "ok:C")
        #expect(await gate.maxConcurrent == 1)      // never two turn/start on one session
    }

    @Test func respawnAfterClose() async throws {
        let (bridge, made) = makeCodexBridge()
        let r1 = try await bridge.runTurn(channelId: "c", text: "one")
        #expect(r1.text == "ok:one")
        await made.last()?.close()                  // client dies
        let r2 = try await bridge.runTurn(channelId: "c", text: "two")
        #expect(r2.text == "ok:two")
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

    // T2 (Codex): first turn persists threadId; a fresh bridge sharing the store thread/resume-s it.
    @Test func t2_reconnectResumesThread() async throws {
        let store = freshTempStore()
        let (b1, _) = makeCodexBridge(store: store)
        _ = try await b1.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .codex))
        #expect(await store.binding(channelId: "c")?.backendSessionId == "t1")

        let ids = LockedBox<[String]>([])
        let (b2, _) = makeCodexBridge(store: store, backendIdCapture: ids)   // restart
        _ = try await b2.runTurn(channelId: "c", text: "again", config: SessionConfig(backend: .codex))
        #expect(ids.withLock { $0 }.contains("resume:t1"))
        #expect(!ids.withLock { $0 }.contains("start"))
    }

    // T7: two concurrent turns on a freshly-persisted channel resume exactly once (serial gate).
    @Test func t7_concurrentTurnsResumeOnce() async throws {
        let store = freshTempStore()
        let (b1, _) = makeCodexBridge(store: store)
        _ = try await b1.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .codex))

        let ids = LockedBox<[String]>([])
        let (b2, _) = makeCodexBridge(store: store, backendIdCapture: ids)
        async let r1 = b2.runTurn(channelId: "c", text: "a", config: SessionConfig(backend: .codex))
        async let r2 = b2.runTurn(channelId: "c", text: "b", config: SessionConfig(backend: .codex))
        _ = try await [r1, r2]
        #expect(ids.withLock { $0.filter { $0.hasPrefix("resume:") } }.count == 1)
    }

    // W11-b1: model → thread/start params, effort/model → turn/start params.
    @Test func configReachesThreadAndTurnParams() async throws {
        let capture = LockedBox<[String: String]>([:])
        let (bridge, _) = makeCodexBridge(capture: capture)
        let reply = try await bridge.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .codex, model: "gpt-5-codex", effort: "high"))
        #expect(reply.text == "ok:hi")
        let got = capture.withLock { $0 }
        #expect(got["threadModel"] == "gpt-5-codex")
        #expect(got["turnEffort"] == "high")
        #expect(got["turnModel"] == "gpt-5-codex")
    }

    @Test func configuredModelReachesTurnResultAndUsagePanel() async throws {
        let gate = TurnGate()
        let serverBox = LockedBox<GateableCodexServer?>(nil)
        let (bridge, _) = makeCodexBridge(gate: gate, serverBox: serverBox)
        let turn = Task {
            try await bridge.runTurn(
                channelId: "c",
                text: "usage",
                config: SessionConfig(backend: .codex, model: "gpt-5-codex")
            )
        }
        await gate.waitReceived(1)
        guard let server = serverBox.withLock({ $0 }) else {
            Issue.record("server not captured")
            await gate.release()
            _ = try await turn.value
            return
        }
        await server.pushRawNotification(method: "thread/tokenUsage/updated", params: .object([
            "tokenUsage": .object([
                "total": .object(["totalTokens": .number(1_200)]),
                "modelContextWindow": .number(200_000),
            ]),
        ]))
        for _ in 0..<200 { await Task.yield() }
        await gate.release()

        let reply = try await turn.value
        #expect(reply.contextUsage?.model == "gpt-5-codex")
        #expect(buildUsageEmbed(usage: nil, ctxUsage: reply.contextUsage)?.footer == nil)
    }

    @Test func eachTurnKeepsItsModelSnapshotWhenConfigChanges() async throws {
        let gate = TurnGate()
        let serverBox = LockedBox<GateableCodexServer?>(nil)
        let (bridge, _) = makeCodexBridge(gate: gate, serverBox: serverBox)
        let usage: JSONValue = .object([
            "tokenUsage": .object([
                "total": .object(["totalTokens": .number(1_200)]),
                "modelContextWindow": .number(200_000),
            ]),
        ])

        let firstTurn = Task {
            try await bridge.runTurn(
                channelId: "c", text: "first", config: SessionConfig(backend: .codex, model: "gpt-5-old")
            )
        }
        await gate.waitReceived(1)
        guard let server = serverBox.withLock({ $0 }) else {
            Issue.record("server not captured")
            await gate.release()
            _ = try await firstTurn.value
            return
        }
        await server.pushRawNotification(method: "thread/tokenUsage/updated", params: usage)
        for _ in 0..<200 { await Task.yield() }
        await gate.release()
        let firstReply = try await firstTurn.value

        let secondTurn = Task {
            try await bridge.runTurn(
                channelId: "c", text: "second", config: SessionConfig(backend: .codex, model: "gpt-5-new")
            )
        }
        await gate.waitReceived(2)
        await server.pushRawNotification(method: "thread/tokenUsage/updated", params: usage)
        for _ in 0..<200 { await Task.yield() }
        await gate.release()
        let secondReply = try await secondTurn.value

        #expect(firstReply.contextUsage?.model == "gpt-5-old")
        #expect(buildUsageEmbed(usage: nil, ctxUsage: firstReply.contextUsage)?.footer == nil)
        #expect(secondReply.contextUsage?.model == "gpt-5-new")
        #expect(buildUsageEmbed(usage: nil, ctxUsage: secondReply.contextUsage)?.footer == nil)
    }

    // W14: stop closes client + drops channel map; interrupt keeps map and sends turn/interrupt.
    @Test func stopClosesAndDropsChannel() async throws {
        let (bridge, made) = makeCodexBridge()
        #expect(try await bridge.runTurn(channelId: "c", text: "hi").text == "ok:hi")
        #expect(await bridge.isLive(channelId: "c") == true)
        await bridge.stop(channelId: "c")
        #expect(await bridge.isLive(channelId: "c") == false)
        #expect(made.last()?.isClosed == true)
    }

    @Test func interruptKeepsChannelAndCallsTurnInterrupt() async throws {
        let gate = TurnGate()
        let capture = LockedBox<[String: String]>([:])
        let (bridge, made) = makeCodexBridge(gate: gate, capture: capture)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "long") }
        await gate.waitReceived(1)
        // turn/start response may still be hopping onto the actor after the fake parks on the gate.
        for _ in 0..<200 where await bridge.activeTurnId(channelId: "c") == nil {
            await Task.yield()
        }
        #expect(await bridge.activeTurnId(channelId: "c") == "u1")
        #expect(await bridge.interrupt(channelId: "c") == true)
        #expect(await bridge.isLive(channelId: "c") == true)
        #expect(made.last()?.isClosed == false)
        let got = capture.withLock { $0 }
        #expect(got["interruptThread"] == "t1")
        #expect(got["interruptTurn"] == "u1")
        let reply = try await t.value
        #expect(reply.text == "(interrupted)")
    }

    @Test func interruptIdleIsTrueWhenLive() async throws {
        let (bridge, _) = makeCodexBridge()
        #expect(try await bridge.runTurn(channelId: "c", text: "hi").text == "ok:hi")
        #expect(await bridge.interrupt(channelId: "c") == true)
        #expect(await bridge.isLive(channelId: "c") == true)
        #expect(await bridge.interrupt(channelId: "missing") == false)
    }

    /// W14 RV: interrupt before/around turnId must not leave a zombie activeTurnId; late
    /// turn/start results either interrupt the backend turn or are ignored after gen bump.
    @Test func interruptBeforeTurnIdNoZombieActiveTurnId() async throws {
        let gate = TurnGate()
        let capture = LockedBox<[String: String]>([:])
        let (bridge, _) = makeCodexBridge(gate: gate, capture: capture)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "long") }
        await gate.waitReceived(1)
        // Interrupt immediately — may race with activeTurnIds assignment.
        #expect(await bridge.interrupt(channelId: "c") == true)
        #expect(await bridge.activeTurnId(channelId: "c") == nil)
        // Drain late turnStart hops onto the actor.
        for _ in 0..<200 { await Task.yield() }
        #expect(await bridge.activeTurnId(channelId: "c") == nil)
        let reply = try await t.value
        #expect(reply.text == "(interrupted)")
        // interrupt-time and/or late noteTurnStarted must have sent turn/interrupt once turnId existed.
        for _ in 0..<50 where capture.withLock({ $0["interruptTurn"] }) == nil {
            await Task.yield()
        }
        #expect(capture.withLock { $0["interruptTurn"] } == "u1")
        #expect(capture.withLock { $0["interruptThread"] } == "t1")
    }

    @Test func lateTurnIdAfterInterruptDoesNotRestamp() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeCodexBridge(gate: gate)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "long") }
        await gate.waitReceived(1)
        let genBefore = await bridge.turnGeneration(channelId: "c")
        #expect(await bridge.interrupt(channelId: "c") == true)
        #expect(await bridge.turnGeneration(channelId: "c") == genBefore + 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(await bridge.activeTurnId(channelId: "c") == nil)
        #expect(await bridge.isLive(channelId: "c") == true)
        _ = try await t.value
    }

    /// RV: codex live + registry/store backend=claude → SessionLifecycle still kills codex.
    @Test func lifecycleStopKillsCodexWhenBindingSaysClaude() async throws {
        let reg = SessionRegistry()
        let store = freshTempStore()
        let (codex, made) = makeCodexBridge(store: store)
        #expect(try await codex.runTurn(channelId: "c", text: "hi", config: SessionConfig(backend: .codex)).text == "ok:hi")
        #expect(await codex.isLive(channelId: "c") == true)

        await reg.bind(channelId: "c", SessionConfig(backend: .claude))
        try await store.upsert(
            channelId: "c",
            PersistedSession(backend: .claude, cwd: "/x", guildId: "g", updatedAt: "t")
        )

        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl", isDirectory: false)
        let life = SessionLifecycle(
            registry: reg,
            store: store,
            audit: AuditLog(fileURL: auditURL, now: { "T" }),
            stopClaude: { _ in },
            stopCodex: { ch in await codex.stop(channelId: ch) },
            stopGrok: { _ in },
            interruptClaude: { _ in false },
            interruptCodex: { _ in false },
            interruptGrok: { _ in false }
        )
        #expect(await life.stopChannel(channelId: "c", actorId: "u", guildId: "g") == true)
        #expect(await codex.isLive(channelId: "c") == false)
        #expect(made.last()?.isClosed == true)
        #expect(await reg.binding(channelId: "c") == nil)
        #expect(await store.binding(channelId: "c") == nil)
    }

    @Test func buildCodexTurnItemsSendsImageAsLocalImagePathAndKeepsNonImageAsHint() {
        let items = buildCodexTurnItems(
            text: "hi",
            files: [TurnFile(path: "/x/pic.png", mime: nil), TurnFile(path: "/x/note.txt", mime: "text/plain")]
        )
        #expect(items == [
            .object(["type": .string("text"), "text": .string("hi\n\nAttached file: /x/note.txt")]),
            .object(["type": .string("localImage"), "path": .string("/x/pic.png")]),
        ])
    }

    @Test func buildCodexTurnItemsNonImageOnlyStaysSingleTextItem() {
        let items = buildCodexTurnItems(text: "hi", files: [TurnFile(path: "/x/note.txt", mime: "text/plain")])
        #expect(items == [.object(["type": .string("text"), "text": .string("hi\n\nAttached file: /x/note.txt")])])
    }

    // MARK: - C3: dynamic tools (attach_file / share_document)

    @Test func dynamicToolsRegisteredOnThreadStart() async throws {
        let capture = LockedBox<[String: String]>([:])
        let (bridge, _) = makeCodexBridge(capture: capture)
        _ = try await bridge.runTurn(channelId: "c", text: "hi")
        let names = capture.withLock { $0["dynamicTools"] } ?? ""
        #expect(names.contains("attach_file"))
        #expect(names.contains("share_document"))
    }

    @Test func dynamicToolCallAttachFileRoutesToFileAttachHost() async throws {
        let gate = TurnGate()
        let serverBox = LockedBox<GateableCodexServer?>(nil)
        let responseCapture = LockedBox<[JSONValue]>([])
        let fileAttachHost = FileAttachHost()
        let calls = LockedBox<[(channelId: String, path: String, name: String?)]>([])
        await fileAttachHost.setAttachHandler { channelId, path, name in
            calls.withLock { $0.append((channelId, path, name)) }
            return "Sent \(name ?? path) to the channel."
        }
        let (bridge, _) = makeCodexBridge(gate: gate, responseCapture: responseCapture, fileAttachHost: fileAttachHost, serverBox: serverBox)

        let t = Task { try await bridge.runTurn(channelId: "c", text: "attach please") }
        await gate.waitReceived(1)   // turn in flight → channel/client/handler are live
        guard let server = serverBox.withLock({ $0 }) else {
            Issue.record("server not captured")
            await gate.release()
            _ = try await t.value
            return
        }
        await server.pushToolCall(
            id: 501, tool: "attach_file", arguments: .object(["path": .string("a.txt")]),
            callId: "call-1", threadId: "t1", turnId: "u1"
        )
        #expect(await waitUntil {
            responseCapture.withLock { $0 }.contains { msg in
                guard case .object(let o) = msg else { return false }
                return o["id"]?.numberValue == 501
            }
        })
        let resp = responseCapture.withLock { $0 }.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 501
        }
        #expect(resp?["result"]?["success"]?.boolValue == true)
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.channelId == "c")
        #expect(recorded.first?.path.hasSuffix("/a.txt") == true)   // resolved to an absolute path under cwd

        await gate.release()
        _ = try await t.value
    }

    @Test func dynamicToolCallShareDocumentRoutesToDocumentShareHost() async throws {
        let gate = TurnGate()
        let serverBox = LockedBox<GateableCodexServer?>(nil)
        let responseCapture = LockedBox<[JSONValue]>([])
        let documentShareHost = DocumentShareHost()
        let calls = LockedBox<[(channelId: String, path: String)]>([])
        await documentShareHost.setShareHandler { channelId, path in
            calls.withLock { $0.append((channelId, path)) }
            return ShareResult(ok: true, threadName: "📄 notes.md", path: "notes.md")
        }
        let (bridge, _) = makeCodexBridge(gate: gate, responseCapture: responseCapture, documentShareHost: documentShareHost, serverBox: serverBox)

        let t = Task { try await bridge.runTurn(channelId: "c", text: "share please") }
        await gate.waitReceived(1)
        guard let server = serverBox.withLock({ $0 }) else {
            Issue.record("server not captured")
            await gate.release()
            _ = try await t.value
            return
        }
        await server.pushToolCall(
            id: 502, tool: "share_document", arguments: .object(["path": .string("notes.md")]),
            callId: "call-2", threadId: "t1", turnId: "u1"
        )
        #expect(await waitUntil {
            responseCapture.withLock { $0 }.contains { msg in
                guard case .object(let o) = msg else { return false }
                return o["id"]?.numberValue == 502
            }
        })
        let resp = responseCapture.withLock { $0 }.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 502
        }
        #expect(resp?["result"]?["success"]?.boolValue == true)
        #expect(resp?["result"]?["contentItems"]?.arrayValue?.first?["text"]?.stringValue == "Shared \"notes.md\" to thread 📄 notes.md")
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.channelId == "c")
        #expect(recorded.first?.path == "notes.md")

        await gate.release()
        _ = try await t.value
    }

    @Test func dynamicToolCallAttachFileMissingPathRespondsFailureWithoutCallingHost() async throws {
        let gate = TurnGate()
        let serverBox = LockedBox<GateableCodexServer?>(nil)
        let responseCapture = LockedBox<[JSONValue]>([])
        let fileAttachHost = FileAttachHost()
        let called = LockedBox(false)
        await fileAttachHost.setAttachHandler { _, _, _ in
            called.withLock { $0 = true }
            return "should not be reached"
        }
        let (bridge, _) = makeCodexBridge(gate: gate, responseCapture: responseCapture, fileAttachHost: fileAttachHost, serverBox: serverBox)

        let t = Task { try await bridge.runTurn(channelId: "c", text: "attach please") }
        await gate.waitReceived(1)
        guard let server = serverBox.withLock({ $0 }) else {
            Issue.record("server not captured")
            await gate.release()
            _ = try await t.value
            return
        }
        await server.pushToolCall(
            id: 503, tool: "attach_file", arguments: .object([:]),
            callId: "call-3", threadId: "t1", turnId: "u1"
        )
        #expect(await waitUntil {
            responseCapture.withLock { $0 }.contains { msg in
                guard case .object(let o) = msg else { return false }
                return o["id"]?.numberValue == 503
            }
        })
        let resp = responseCapture.withLock { $0 }.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 503
        }
        #expect(resp?["result"]?["success"]?.boolValue == false)
        #expect(resp?["result"]?["contentItems"]?.arrayValue?.first?["text"]?.stringValue == "attach_file requires a path.")
        #expect(called.withLock { $0 } == false)

        await gate.release()
        _ = try await t.value
    }

    // MARK: - H2: turnId verification

    // A stale `turn/completed` (mismatched turnId) must not finish the still-running turn; only
    // the correctly turnId'd (or turnId-less) completion from the real fake-server path does.
    @Test func staleTurnCompletedWithMismatchedTurnIdIsIgnored() async throws {
        let gate = TurnGate()
        let serverBox = LockedBox<GateableCodexServer?>(nil)
        let (bridge, _) = makeCodexBridge(gate: gate, serverBox: serverBox)
        let t = Task { try await bridge.runTurn(channelId: "c", text: "long") }
        await gate.waitReceived(1)
        for _ in 0..<200 where await bridge.activeTurnId(channelId: "c") == nil {
            await Task.yield()
        }
        #expect(await bridge.activeTurnId(channelId: "c") == "u1")
        guard let server = serverBox.withLock({ $0 }) else {
            Issue.record("server not captured"); await gate.release(); _ = try await t.value; return
        }

        await server.pushRawNotification(method: "turn/completed", params: .object(["turnId": .string("stale-turn")]))
        for _ in 0..<200 { await Task.yield() }
        #expect(await bridge.isTurnRunning(channelId: "c") == true)   // stale notif ignored — still running

        await gate.release()   // real completion path (delta + turn/completed, no turnId on this fake)
        let reply = try await t.value
        #expect(reply.text == "ok:long")
    }

    // MARK: - M7: safe default when no permMode is bound

    // No config/binding at all → permMode falls back to "default" (approval required), not the
    // old "bypassPermissions" (auto-approve everything) danger default.
    @Test func unboundPermModeDefaultsToApprovalRequired() async throws {
        let capture = LockedBox<[String: String]>([:])
        let handlers = LockedBox<[AppServerApprovalHandler?]>([])
        let (bridge, _) = makeCodexBridge(capture: capture, onApprovalSpy: handlers)
        _ = try await bridge.runTurn(channelId: "c", text: "hi")   // no config → permMode unbound
        #expect(capture.withLock { $0["approvalPolicy"] } == "on-request")
        #expect(capture.withLock { $0["sandbox"] } == "workspace-write")
        #expect(handlers.withLock { $0.first ?? nil } != nil)   // approval handler installed (not auto)
    }

    // MARK: - C2: config.codexTimeoutMs drives the turn timeout

    @Test func codexTimeoutMsDrivesTurnTimeout() async throws {
        let gate = TurnGate()
        let (bridge, _) = makeCodexBridge(gate: gate, codexTimeoutMs: 100)   // 100ms, no test override
        let t = Task { try await bridge.runTurn(channelId: "c", text: "x") }
        await gate.waitReceived(1)   // held, never released → codexTimeoutMs-driven timeout fires
        await #expect(throws: (any Error).self) { _ = try await t.value }
    }

    // MARK: - C4-b: live /effort switch

    @Test func setEffortValidatesAndRequiresLiveChannel() async throws {
        let (bridge, _) = makeCodexBridge()
        #expect(await bridge.setEffort(channelId: "c", effort: "medium") == false)   // no live channel yet
        _ = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(await bridge.setEffort(channelId: "c", effort: "high") == true)       // known effort
        #expect(await bridge.setEffort(channelId: "c", effort: "zzz-not-a-level") == false)   // unknown
        #expect(await bridge.setEffort(channelId: "c", effort: "") == true)           // empty clears
    }

    // MARK: - H8/M2: profile-based permissionMode re-resolution

    // A bound permission PROFILE re-resolves permissionMode from the CURRENT config on every
    // session start rather than trusting a stored raw permMode.
    @Test func profileBoundPermissionModeReResolvesFromCurrentConfig() async throws {
        let configStore = freshTempConfigStore()
        var appConfig = AppConfig(discord: DiscordSecrets(token: "t", clientId: "c"))
        appConfig.profiles["reviewer"] = Profile(permissionMode: "plan", allowedTools: [], policyTier: "read-only")
        try await configStore.save(appConfig)

        let store = freshTempStore()
        try await store.upsert(channelId: "c", PersistedSession(
            backend: .codex, cwd: "/x", guildId: "g", permissionProfile: "reviewer", updatedAt: "t"
        ))

        let capture = LockedBox<[String: String]>([:])
        let (bridge, _) = makeCodexBridge(capture: capture, store: store, configStore: configStore)
        _ = try await bridge.runTurn(channelId: "c", guildId: "g", text: "hi", config: SessionConfig(backend: .codex))
        // "plan" → on-request/read-only (resolveThreadPolicy) — from the profile, not a stale/raw value.
        #expect(capture.withLock { $0["approvalPolicy"] } == "on-request")
        #expect(capture.withLock { $0["sandbox"] } == "read-only")
    }

    // A bound profile name that no longer exists in config blocks the session (TS
    // permissionResolver.ts:66-70) instead of silently falling back.
    @Test func unknownBoundProfileBlocksSessionStart() async throws {
        let configStore = freshTempConfigStore()
        let appConfig = AppConfig(discord: DiscordSecrets(token: "t", clientId: "c"))   // no profiles
        try await configStore.save(appConfig)

        let store = freshTempStore()
        try await store.upsert(channelId: "c", PersistedSession(
            backend: .codex, cwd: "/x", guildId: "g", permissionProfile: "ghost", updatedAt: "t"
        ))

        let (bridge, _) = makeCodexBridge(store: store, configStore: configStore)
        await #expect(throws: (any Error).self) {
            _ = try await bridge.runTurn(channelId: "c", guildId: "g", text: "hi", config: SessionConfig(backend: .codex))
        }
    }

    // WO-14: `configure` is the only way to move `.shared` off its `nil, nil` init defaults.
    // Every other test above injects `makeClient`, bypassing the PRODUCTION closure entirely.
    // This one leaves `makeClient` at its default (nil) so the real `resolveCodexSpawn` →
    // `CodexAppServerClient(spawn:codexHome:)` wiring runs end to end, using the values passed
    // to `configure` — not the ones passed to `init` (which stay nil here). The script dumps its
    // inherited `CODEX_HOME` to a file and exits; the bridge's `initialize()` call fails right
    // after (child already gone), which the test ignores via `try?`.
    @Test func configureExpandsCodexHomeBeforeProductionSpawn() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-configure-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let outFile = tmpDir.appendingPathComponent("captured-env.txt")
        let scriptPath = tmpDir.appendingPathComponent("fake-codex").path
        let script = "#!/bin/sh\necho \"CODEX_HOME=$CODEX_HOME\" > \"\(outFile.path)\"\nexit 1\n"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        // Omitting `makeClient:` runs the production default closure; store/configStore stay
        // isolated per the `makeCodexBridge` convention.
        let bridge = CodexSessionBridge(store: freshTempStore(), configStore: freshTempConfigStore())
        await bridge.configure(codexHome: "~/.codex", codexCliCommand: scriptPath)
        _ = try? await bridge.runTurn(channelId: "c", text: "hi")

        let sawFile = await waitUntil { FileManager.default.fileExists(atPath: outFile.path) }
        #expect(sawFile)
        let captured = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(captured == "CODEX_HOME=\(NSHomeDirectory())/.codex")
    }

}

// MARK: - M6: child-process PATH augmentation (mirrors GrokSpawnTests' grokChildEnvironment suite)

@Suite("codexChildEnvironment")
struct CodexChildEnvironmentTests {
    @Test func prependsWellKnownDirsOntoExistingPath() {
        let env = codexChildEnvironment(
            baseEnv: ["PATH": "/usr/bin:/bin", "OTHER": "kept"],
            homeDir: "/Users/alice"
        )
        #expect(env["OTHER"] == "kept")
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        // Well-known dirs come first, existing PATH entries are preserved at the end untouched.
        #expect(dirs.suffix(2) == ["/usr/bin", "/bin"])
        #expect(dirs.contains("/Users/alice/.local/bin"))
        #expect(dirs.contains("/Users/alice/.nvm/current/bin"))
    }

    @Test func doesNotDuplicateADirAlreadyOnPath() {
        let env = codexChildEnvironment(
            baseEnv: ["PATH": "/Users/alice/.cargo/bin:/usr/bin"],
            homeDir: "/Users/alice"
        )
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(dirs.filter { $0 == "/Users/alice/.cargo/bin" }.count == 1)
    }
}
