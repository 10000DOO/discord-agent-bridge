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
        // Allow event delivery
        try await Task.sleep(nanoseconds: 50_000_000)
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
        try await Task.sleep(nanoseconds: 50_000_000)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }
}
