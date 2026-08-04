import Testing
import Foundation
@testable import DiscordAgentBridge

/// Minimal echo sidecar: ready notify, then answers session.* / sessions.list.
actor FakeSidecar {
    private let transport: InMemorySidecarTransport
    private var sessionCounter = 0

    init(transport: InMemorySidecarTransport) {
        self.transport = transport
    }

    func run() async {
        // Emit ready first
        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await transport.writeLine(line + "\n")
        }

        do {
            for try await line in transport.lines {
                await handle(line)
            }
        } catch {
            // closed
        }
    }

    private func handle(_ line: String) async {
        guard let env = try? parseEnvelope(line) else { return }
        guard env.type == .req, let id = env.id, let method = env.method else { return }

        switch method {
        case "session.start":
            sessionCounter += 1
            let handle = "fake-\(sessionCounter)"
            let result: JSONValue = .object([
                "session": .string(handle),
                "backendSessionId": .null,
            ])
            if let out = try? serializeEnvelope(res(id: id, method: method, result: result)) {
                try? await transport.writeLine(out + "\n")
            }
            // Emit a sample text event
            if let ev = try? serializeEnvelope(
                eventEnvelope(session: handle, event: .text(text: "hello-from-fake", delta: true))
            ) {
                try? await transport.writeLine(ev + "\n")
            }

        case "session.send":
            let session = env.session ?? env.params?["session"]?.stringValue ?? ""
            if let out = try? serializeEnvelope(
                res(id: id, method: method, result: .object(["ok": .bool(true)]), session: session)
            ) {
                try? await transport.writeLine(out + "\n")
            }
            if !session.isEmpty,
               let ev = try? serializeEnvelope(
                   eventEnvelope(session: session, event: .text(text: "ack", delta: false))
               )
            {
                try? await transport.writeLine(ev + "\n")
            }

        case "session.stop":
            if let out = try? serializeEnvelope(
                res(id: id, method: method, result: .object(["ok": .bool(true)]), session: env.session)
            ) {
                try? await transport.writeLine(out + "\n")
            }

        case "session.setModel", "session.setEffort":
            if let out = try? serializeEnvelope(
                res(id: id, method: method, result: .object(["ok": .bool(true)]), session: env.session)
            ) {
                try? await transport.writeLine(out + "\n")
            }

        case "sessions.list":
            let result: JSONValue = .object([
                "sessions": .array([
                    .object([
                        "sessionId": .string("backend-1"),
                        "cwd": env.params?["cwd"] ?? .string("/tmp"),
                        "label": .string("fake"),
                    ]),
                ]),
            ])
            if let out = try? serializeEnvelope(res(id: id, method: method, result: result)) {
                try? await transport.writeLine(out + "\n")
            }

        case "claude.catalog":
            // No params, not session-scoped. One model advertises effort levels, one doesn't.
            let result: JSONValue = .object([
                "models": .array([
                    .object([
                        "value": .string("claude-opus-4"),
                        "label": .string("Opus"),
                        "supportedEffortLevels": .array([.string("high"), .string("max")]),
                    ]),
                    .object([
                        "value": .string("claude-sonnet-4"),
                        "label": .string("Sonnet"),
                    ]),
                ]),
                "permissionModes": .array([
                    .object(["value": .string("default"), "label": .string("default")]),
                    .object(["value": .string("plan"), "label": .string("plan")]),
                ]),
                "effortLevels": .array(["low", "medium", "high", "xhigh", "max"].map { .string($0) }),
                "runtimeEffortLevels": .array(["low", "medium", "high", "xhigh"].map { .string($0) }),
                "defaultEffort": .string("high"),
            ])
            if let out = try? serializeEnvelope(res(id: id, method: method, result: result)) {
                try? await transport.writeLine(out + "\n")
            }

        case "host.file.attach", "host.file.share":
            // Should not be sent by client as req TO sidecar in tests
            break

        default:
            if let out = try? serializeEnvelope(
                resError(
                    id: id,
                    method: method,
                    error: makeError(code: "unsupported", message: "fake: \(method)")
                )
            ) {
                try? await transport.writeLine(out + "\n")
            }
        }
    }

    /// Simulate reverse RPC from sidecar to host.
    func sendReverseAttach(id: String, session: String, path: String) async {
        let env = req(
            id: id,
            method: "host.file.attach",
            params: ["path": .string(path)],
            session: session
        )
        if let line = try? serializeEnvelope(env) {
            try? await transport.writeLine(line + "\n")
        }
    }

    /// Simulate host.file.share reverse RPC from sidecar to host.
    func sendReverseShare(id: String, session: String, path: String) async {
        let env = req(
            id: id,
            method: "host.file.share",
            params: ["path": .string(path)],
            session: session
        )
        if let line = try? serializeEnvelope(env) {
            try? await transport.writeLine(line + "\n")
        }
    }
}

@Suite("ClaudeSidecarClient with fake transport")
struct SidecarClientTests {
    @Test func connectWaitsForReadyAndSessionStart() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        let started = try await client.sessionStart(
            SessionStartParams(
                cwd: "/tmp",
                guildId: "guild",
                channelId: "channel",
                permMode: "default"
            )
        )
        #expect(started.session.hasPrefix("fake-"))
        #expect(started.backendSessionId == nil)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func sessionSendAndEvents() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )

        let received = LockedBox<[AgentEvent]>([])
        let handlers = SidecarSessionHandlers { ev in
            received.withLock { $0.append(ev) }
        }
        client.registerSessionHandlers(handle: started.session, handlers: handlers)

        // Collect via stream as well
        let stream = client.events(for: started.session)
        let streamEvents = LockedBox<[AgentEvent]>([])
        let collectTask = Task {
            for await ev in stream {
                streamEvents.withLock { $0.append(ev) }
                if streamEvents.withLock({ $0.count }) >= 1 { break }
            }
        }

        try await client.sessionSend(session: started.session, text: "hi")
        #expect(await waitUntil {
            received.withLock { $0 }.contains(where: {
                if case .text(let t, _) = $0 { return t == "ack" }
                return false
            })
        })
        collectTask.cancel()

        let got = received.withLock { $0 }
        #expect(got.contains(where: { if case .text(let t, _) = $0 { return t == "ack" }; return false }))

        try await client.sessionStop(session: started.session)
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func sessionsList() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let list = try await client.sessionsList(cwd: "/tmp", limit: 10)
        #expect(list.sessions.count == 1)
        #expect(list.sessions[0].sessionId == "backend-1")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func sessionSetModelAndSetEffort() async throws {
        // W11-g residual: live session.setModel / session.setEffort RPC on the client.
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )
        // Must not throw against a supporting fake (protocol §3.6).
        try await client.sessionSetModel(session: started.session, model: "sonnet")
        try await client.sessionSetEffort(session: started.session, effort: "high")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func reverseRpcUnsupported() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        // Start so we have a session id
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )

        // Capture host → sidecar lines for the reverse res
        // The reverse RPC is host.file.attach from fake; client should answer unsupported.
        // We observe by reading pair.sidecar's peer responses via a second reader isn't easy.
        // Instead: send reverse and ensure client doesn't crash; wait briefly.
        await fake.sendReverseAttach(id: "s-rev-1", session: started.session, path: "/tmp/x")
        // Reverse RPC is fire-and-forget; yield so the read loop can answer before teardown.
        for _ in 0..<32 { await Task.yield() }

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func reverseRpcHostFileAttachWired() async throws {
        // Single consumer on sidecar.lines: answer session.start + capture reverse res.
        let pair = InMemorySidecarTransport.makePair()
        let resBox = LockedBox<Envelope?>(nil)
        let pump = Task {
            for try await line in pair.sidecar.lines {
                guard let env = try? parseEnvelope(line) else { continue }
                if env.type == .req, env.method == "session.start", let id = env.id {
                    let out = try serializeEnvelope(res(
                        id: id,
                        method: "session.start",
                        result: .object(["session": .string("sess-attach"), "backendSessionId": .null])
                    ))
                    try await pair.sidecar.writeLine(out + "\n")
                }
                if env.type == .res, env.id == "s-attach-1" {
                    resBox.withLock { $0 = env }
                    break
                }
            }
        }

        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await pair.sidecar.writeLine(line + "\n")
        }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )

        let attachBox = LockedBox<(String, String?)?>(nil)
        client.registerSessionHandlers(
            handle: started.session,
            handlers: SidecarSessionHandlers(
                onEvent: { _ in },
                onFileAttach: { path, name in
                    attachBox.withLock { $0 = (path, name) }
                    return "Sent \(name ?? path) to the channel."
                }
            )
        )

        let reverse = req(
            id: "s-attach-1",
            method: "host.file.attach",
            params: ["path": .string("/tmp/ws/out.txt"), "name": .string("out.txt")],
            session: started.session
        )
        try await pair.sidecar.writeLine(try serializeEnvelope(reverse) + "\n")
        _ = await pump.result

        let got = attachBox.withLock { $0 }
        #expect(got?.0 == "/tmp/ws/out.txt")
        #expect(got?.1 == "out.txt")
        let env = resBox.withLock { $0 }
        #expect(env?.result?["ok"]?.boolValue == true)
        #expect(env?.result?["message"]?.stringValue == "Sent out.txt to the channel.")

        await client.close()
        await pair.sidecar.close()
    }

    @Test func reverseRpcHostFileShareWired() async throws {
        // Single consumer on sidecar.lines: answer session.start + capture reverse res.
        let pair = InMemorySidecarTransport.makePair()
        let resBox = LockedBox<Envelope?>(nil)
        let pump = Task {
            for try await line in pair.sidecar.lines {
                guard let env = try? parseEnvelope(line) else { continue }
                if env.type == .req, env.method == "session.start", let id = env.id {
                    let out = try serializeEnvelope(res(
                        id: id,
                        method: "session.start",
                        result: .object(["session": .string("sess-share"), "backendSessionId": .null])
                    ))
                    try await pair.sidecar.writeLine(out + "\n")
                }
                if env.type == .res, env.id == "s-share-1" {
                    resBox.withLock { $0 = env }
                    break
                }
            }
        }

        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await pair.sidecar.writeLine(line + "\n")
        }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )

        let sharePath = LockedBox<String?>(nil)
        client.registerSessionHandlers(
            handle: started.session,
            handlers: SidecarSessionHandlers(
                onEvent: { _ in },
                onFileShare: { path in
                    sharePath.withLock { $0 = path }
                    return ShareResult(ok: true, threadName: "📄 note.md", path: path)
                }
            )
        )

        let reverse = req(
            id: "s-share-1",
            method: "host.file.share",
            params: ["path": .string("docs/note.md")],
            session: started.session
        )
        try await pair.sidecar.writeLine(try serializeEnvelope(reverse) + "\n")
        _ = await pump.result

        #expect(sharePath.withLock { $0 } == "docs/note.md")
        let env = resBox.withLock { $0 }
        #expect(env?.result?["ok"]?.boolValue == true)
        #expect(env?.result?["path"]?.stringValue == "docs/note.md")
        #expect(env?.result?["threadName"]?.stringValue == "📄 note.md")

        await client.close()
        await pair.sidecar.close()
    }

    @Test func reverseRpcHostFileShareUnwired() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let errBox = LockedBox<SidecarError?>(nil)
        let pump = Task {
            for try await line in pair.sidecar.lines {
                guard let env = try? parseEnvelope(line) else { continue }
                if env.type == .req, env.method == "session.start", let id = env.id {
                    let out = try serializeEnvelope(res(
                        id: id,
                        method: "session.start",
                        result: .object(["session": .string("sess-unwired"), "backendSessionId": .null])
                    ))
                    try await pair.sidecar.writeLine(out + "\n")
                }
                if env.type == .res, env.id == "s-share-u" {
                    errBox.withLock { $0 = env.error }
                    break
                }
            }
        }

        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await pair.sidecar.writeLine(line + "\n")
        }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )
        // Handlers without onFileShare → unsupported
        client.registerSessionHandlers(
            handle: started.session,
            handlers: SidecarSessionHandlers(onEvent: { _ in })
        )

        let reverse = req(
            id: "s-share-u",
            method: "host.file.share",
            params: ["path": .string("x.md")],
            session: started.session
        )
        try await pair.sidecar.writeLine(try serializeEnvelope(reverse) + "\n")
        _ = await pump.result

        #expect(errBox.withLock { $0 }?.code == "unsupported")

        await client.close()
        await pair.sidecar.close()
    }

    // MARK: - host.orchestration.order / .report (WO-5, design_orchestration_module_agents.md)
    //
    // Exercises the full reverse-RPC wire, not just `OrchestrationHost` directly (that's already
    // covered exhaustively by OrchestrationHostTests.swift): fake sidecar → ClaudeSidecarClient
    // .handleReverseRpc → the registered onOrchestrationOrder/onOrchestrationReport closure (same
    // shape DabSessionBridge wires) → a real, isolated `OrchestrationHost` → `orchestrationDecisionText`
    // → back over the wire as `{ok, message}`.

    @Test func reverseRpcHostOrchestrationOrderBusyAndOutsideWorkspaceDiffer() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let resBox = LockedBox<[String: Envelope]>([:])
        let pump = Task {
            for try await line in pair.sidecar.lines {
                guard let env = try? parseEnvelope(line) else { continue }
                if env.type == .req, env.method == "session.start", let id = env.id {
                    let out = try serializeEnvelope(res(
                        id: id, method: "session.start",
                        result: .object(["session": .string("sess-orch-order"), "backendSessionId": .null])
                    ))
                    try await pair.sidecar.writeLine(out + "\n")
                }
                if env.type == .res, let id = env.id, id.hasPrefix("s-order-") {
                    resBox.withLock { $0[id] = env }
                    if resBox.withLock({ $0.count }) >= 2 { break }
                }
            }
        }

        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await pair.sidecar.writeLine(line + "\n")
        }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )

        // Isolated OrchestrationHost: "lead-1" is bound as orchestrator, "mod-1" is an existing
        // "core" module channel forced mid-turn (→ .busy). Neither request needs a provisioner
        // or turn-runner — .busy and .outsideWorkspace both return before those seams are used.
        let store = freshTempStore()
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try await store.upsert(channelId: "lead-1", PersistedSession(
            backend: .claude, cwd: projectDir.path, guildId: "g", updatedAt: "t", orchestrationRole: "orchestrator"
        ))
        try await store.upsert(channelId: "mod-1", PersistedSession(
            backend: .claude, cwd: projectDir.path, guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "lead-1", moduleName: "core"
        ))
        let configStore = ConfigStore(baseDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-sidecar-cfg-\(UUID().uuidString)", isDirectory: true))
        let host = OrchestrationHost(store: store, configStore: configStore, isTurnRunning: { $0 == "mod-1" })

        client.registerSessionHandlers(
            handle: started.session,
            handlers: SidecarSessionHandlers(
                onEvent: { _ in },
                onOrchestrationOrder: { module, path, text in
                    let decision = await host.order(fromChannelId: "lead-1", module: module, path: path, text: text)
                    return orchestrationDecisionText(decision)
                }
            )
        )

        // .busy — re-orders the already mid-turn "core" module channel.
        try await pair.sidecar.writeLine(try serializeEnvelope(req(
            id: "s-order-busy", method: "host.orchestration.order",
            params: ["module": .string("core"), "path": .string(projectDir.path), "text": .string("go")],
            session: started.session
        )) + "\n")
        // .outsideWorkspace — a path far outside the workspace root.
        try await pair.sidecar.writeLine(try serializeEnvelope(req(
            id: "s-order-outside", method: "host.orchestration.order",
            params: ["module": .string("ui"), "path": .string("/etc"), "text": .string("go")],
            session: started.session
        )) + "\n")
        _ = await pump.result

        let busyEnv = resBox.withLock { $0["s-order-busy"] }
        let outsideEnv = resBox.withLock { $0["s-order-outside"] }
        #expect(busyEnv?.result?["ok"]?.boolValue == false)
        #expect(outsideEnv?.result?["ok"]?.boolValue == false)
        let busyMsg = busyEnv?.result?["message"]?.stringValue ?? ""
        let outsideMsg = outsideEnv?.result?["message"]?.stringValue ?? ""
        #expect(busyMsg.contains("already running a turn"))
        #expect(outsideMsg.contains("outside the allowed workspace"))
        #expect(busyMsg != outsideMsg)

        await client.close()
        await pair.sidecar.close()
    }

    @Test func reverseRpcHostOrchestrationReportWired() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let resBox = LockedBox<Envelope?>(nil)
        let pump = Task {
            for try await line in pair.sidecar.lines {
                guard let env = try? parseEnvelope(line) else { continue }
                if env.type == .req, env.method == "session.start", let id = env.id {
                    let out = try serializeEnvelope(res(
                        id: id, method: "session.start",
                        result: .object(["session": .string("sess-orch-report"), "backendSessionId": .null])
                    ))
                    try await pair.sidecar.writeLine(out + "\n")
                }
                if env.type == .res, env.id == "s-report-1" {
                    resBox.withLock { $0 = env }
                    break
                }
            }
        }

        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await pair.sidecar.writeLine(line + "\n")
        }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )

        let store = freshTempStore()
        try await store.upsert(channelId: "lead-1", PersistedSession(
            backend: .claude, cwd: "/tmp", guildId: "g", updatedAt: "t", orchestrationRole: "orchestrator"
        ))
        try await store.upsert(channelId: "mod-1", PersistedSession(
            backend: .claude, cwd: "/tmp/core", guildId: "g", updatedAt: "t",
            orchestrationRole: "agent", orchestratorChannelId: "lead-1", moduleName: "core"
        ))
        let turnRecorder = LockedBox<[(String, String)]>([])
        let host = OrchestrationHost(
            store: store, configStore: ConfigStore(baseDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("dab-orch-sidecar-report-cfg-\(UUID().uuidString)", isDirectory: true)),
            runInjectedTurn: { channelId, _, _, text, _, _, _, _ in
                turnRecorder.withLock { $0.append((channelId, text)) }
                return true
            }
        )

        client.registerSessionHandlers(
            handle: started.session,
            handlers: SidecarSessionHandlers(
                onEvent: { _ in },
                onOrchestrationReport: { text in
                    let decision = await host.report(fromChannelId: "mod-1", text: text)
                    return orchestrationDecisionText(decision)
                }
            )
        )

        try await pair.sidecar.writeLine(try serializeEnvelope(req(
            id: "s-report-1", method: "host.orchestration.report",
            params: ["text": .string("DONE: implemented")],
            session: started.session
        )) + "\n")
        _ = await pump.result

        let env = resBox.withLock { $0 }
        #expect(env?.result?["ok"]?.boolValue == true)
        #expect(env?.result?["message"]?.stringValue == "Delivered to channel <#lead-1>.")
        await waitUntil { turnRecorder.withLock { $0 }.contains { $0.0 == "lead-1" && $0.1 == "DONE: implemented" } }

        await client.close()
        await pair.sidecar.close()
    }

    @Test func reverseRpcHostOrchestrationUnwiredReturnsUnsupported() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let errBoxes = LockedBox<[String: SidecarError]>([:])
        let pump = Task {
            for try await line in pair.sidecar.lines {
                guard let env = try? parseEnvelope(line) else { continue }
                if env.type == .req, env.method == "session.start", let id = env.id {
                    let out = try serializeEnvelope(res(
                        id: id, method: "session.start",
                        result: .object(["session": .string("sess-orch-unwired"), "backendSessionId": .null])
                    ))
                    try await pair.sidecar.writeLine(out + "\n")
                }
                if env.type == .res, let id = env.id, let err = env.error {
                    errBoxes.withLock { $0[id] = err }
                    if errBoxes.withLock({ $0.count }) >= 2 { break }
                }
            }
        }

        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await pair.sidecar.writeLine(line + "\n")
        }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()
        let started = try await client.sessionStart(
            SessionStartParams(cwd: "/tmp", guildId: "g", channelId: "c", permMode: "default")
        )
        // Handlers without onOrchestrationOrder/onOrchestrationReport → unsupported, same as an
        // unwired onFileShare (reverseRpcHostFileShareUnwired above).
        client.registerSessionHandlers(handle: started.session, handlers: SidecarSessionHandlers(onEvent: { _ in }))

        try await pair.sidecar.writeLine(try serializeEnvelope(req(
            id: "s-orch-order-u", method: "host.orchestration.order",
            params: ["module": .string("core"), "path": .string("/tmp"), "text": .string("go")],
            session: started.session
        )) + "\n")
        try await pair.sidecar.writeLine(try serializeEnvelope(req(
            id: "s-orch-report-u", method: "host.orchestration.report",
            params: ["text": .string("done")],
            session: started.session
        )) + "\n")
        _ = await pump.result

        #expect(errBoxes.withLock { $0["s-orch-order-u"] }?.code == "unsupported")
        #expect(errBoxes.withLock { $0["s-orch-report-u"] }?.code == "unsupported")

        await client.close()
        await pair.sidecar.close()
    }

    @Test func claudeCatalogRoundTrip() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        let cat = try await client.claudeCatalog()

        #expect(cat.models.count == 2)
        #expect(cat.models[0].value == "claude-opus-4")
        #expect(cat.models[0].label == "Opus")
        #expect(cat.models[0].supportedEffortLevels == ["high", "max"])
        #expect(cat.models[1].value == "claude-sonnet-4")
        #expect(cat.models[1].label == "Sonnet")
        #expect(cat.models[1].supportedEffortLevels == nil)
        #expect(cat.permissionModes == [
            ModelChoice(value: "default", label: "default"),
            ModelChoice(value: "plan", label: "plan"),
        ])
        #expect(cat.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(cat.runtimeEffortLevels == ["low", "medium", "high", "xhigh"])
        #expect(cat.defaultEffort == "high")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    // MARK: - ClaudeCatalogResult(from:) decoder path (Protocol.swift)

    @Test func catalogResultThrowsWhenNotObject() {
        #expect(throws: (any Error).self) {
            try ClaudeCatalogResult(from: .array([]))
        }
    }

    @Test func catalogResultDefaultsMissingFields() throws {
        let r = try ClaudeCatalogResult(from: .object([:]))
        #expect(r.models.isEmpty)
        #expect(r.permissionModes.isEmpty)
        #expect(r.effortLevels.isEmpty)
        #expect(r.runtimeEffortLevels.isEmpty)
        #expect(r.defaultEffort == "")
    }

    @Test func catalogResultModelWithoutEffortLevelsIsNil() throws {
        let r = try ClaudeCatalogResult(from: .object([
            "models": .array([.object(["value": .string("m"), "label": .string("M")])]),
        ]))
        #expect(r.models.count == 1)
        #expect(r.models[0].supportedEffortLevels == nil)
    }
}
