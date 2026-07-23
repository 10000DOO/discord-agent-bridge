import Testing
import Foundation
@testable import DiscordAgentBridge

/// Minimal fake `codex app-server`: answers initialize / thread/start / turn/* and can emit notifications + approvals.
actor FakeAppServer {
    private let transport: InMemorySidecarTransport

    init(transport: InMemorySidecarTransport) {
        self.transport = transport
    }

    func run() async {
        do {
            for try await line in transport.lines {
                await handle(line)
            }
        } catch {
            // closed
        }
    }

    private func handle(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let msg) = value
        else { return }

        guard let method = msg["method"]?.stringValue,
              let id = msg["id"]
        else { return }

        // Client → server request only (has method + id)
        switch method {
        case "initialize":
            await write([
                // Spike wire: omit jsonrpc
                "id": id,
                "result": .object([
                    "userAgent": .string("fake-codex"),
                    "platformOs": .string("macos"),
                ]),
            ])
        case "thread/start":
            await write([
                "id": id,
                "result": .object([
                    "thread": .object(["id": .string("thread-uuid-1")]),
                ]),
            ])
        case "thread/resume":
            await write(["id": id, "result": .object([:])])
        case "turn/start":
            await write([
                "id": id,
                "result": .object([
                    "turn": .object([
                        "id": .string("turn-9"),
                        "status": .string("inProgress"),
                    ]),
                ]),
            ])
        case "turn/interrupt":
            await write(["id": id, "result": .object([:])])
        case "ping":
            await write(["id": id, "result": .object(["pong": .bool(true)])])
        default:
            await write([
                "id": id,
                "error": .object([
                    "code": .number(-32601),
                    "message": .string("Method not found: \(method)"),
                ]),
            ])
        }
    }

    func write(_ obj: [String: JSONValue]) async {
        guard let data = try? JSONEncoder().encode(JSONValue.object(obj)),
              let s = String(data: data, encoding: .utf8)
        else { return }
        try? await transport.writeLine(s + "\n")
    }

    func pushNotification(method: String, params: JSONValue?) async {
        var obj: [String: JSONValue] = ["method": .string(method)]
        if let params { obj["params"] = params }
        await write(obj)
    }

    func pushApprovalRequest(id: Int, method: String, params: JSONValue?) async {
        var obj: [String: JSONValue] = [
            "id": .number(Double(id)),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        await write(obj)
    }
}

@Suite("resolveCodexSpawn")
struct ResolveCodexSpawnTests {
    @Test func defaultsToCodexAppServer() {
        let spawn = resolveCodexSpawn(env: [:])
        #expect(spawn.command == "codex")
        #expect(spawn.args == ["app-server"])
    }

    @Test func codexCommandOverride() {
        let spawn = resolveCodexSpawn(env: [:], codexCommand: "/opt/codex")
        #expect(spawn.command == "/opt/codex")
        #expect(spawn.args == ["app-server"])
    }

    @Test func codexCmdEnvAppendsAppServer() {
        let spawn = resolveCodexSpawn(env: ["CODEX_CMD": "npx @openai/codex"])
        #expect(spawn.command == "npx")
        #expect(spawn.args == ["@openai/codex", "app-server"])
    }

    @Test func codexCmdEnvDoesNotDuplicateAppServer() {
        let spawn = resolveCodexSpawn(env: ["CODEX_CMD": "codex app-server"])
        #expect(spawn.command == "codex")
        #expect(spawn.args == ["app-server"])
    }
}

@Suite("CodexAppServerClient with fake transport")
struct AppServerClientTests {
    @Test func initializeOmittingJsonrpcOnResponse() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        let result = try await client.initialize()
        #expect(result["userAgent"]?.stringValue == "fake-codex")
        #expect(client.initializeResult?["platformOs"]?.stringValue == "macos")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func genericRequestPing() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        let result = try await client.request(method: "ping")
        #expect(result["pong"]?.boolValue == true)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func threadStartAndTurnStart() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        let threadId = try await client.threadStart(
            params: .object([
                "cwd": .string("/ws"),
                "approvalPolicy": .string("never"),
                "sandbox": .string("read-only"),
            ])
        )
        #expect(threadId == "thread-uuid-1")

        let turnId = try await client.turnStart(
            params: .object([
                "threadId": .string(threadId),
                "input": .array([.object(["type": .string("text"), "text": .string("hi")])]),
            ])
        )
        #expect(turnId == "turn-9")

        _ = try await client.turnInterrupt(
            params: .object(["threadId": .string(threadId), "turnId": .string(turnId)])
        )
        _ = try await client.threadResume(params: .object(["threadId": .string(threadId)]))

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func notificationsDispatched() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        let seen = LockedBox<[(String, JSONValue?)]>([])
        _ = client.onNotification { method, params in
            seen.withLock { $0.append((method, params)) }
        }

        await fake.pushNotification(
            method: "item/agentMessage/delta",
            params: .object([
                "threadId": .string("t"),
                "turnId": .string("u"),
                "delta": .string("Hello"),
            ])
        )
        // Allow delivery
        try await Task.sleep(nanoseconds: 50_000_000)

        let got = seen.withLock { $0 }
        #expect(got.count == 1)
        #expect(got.first?.0 == "item/agentMessage/delta")
        #expect(got.first?.1?["delta"]?.stringValue == "Hello")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func approvalAutoAcceptWhenNoHandler() async throws {
        // Client writes responses on host → appear on sidecar.lines (no FakeAppServer consumer).
        let pair = InMemorySidecarTransport.makePair()
        let recorded = LockedBox<[JSONValue]>([])
        let recordTask = Task {
            do {
                for try await line in pair.sidecar.lines {
                    if let data = line.data(using: .utf8),
                       let v = try? JSONDecoder().decode(JSONValue.self, from: data)
                    {
                        recorded.withLock { $0.append(v) }
                    }
                }
            } catch {}
        }

        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        let approvalLine = try JSONEncoder().encode(
            JSONValue.object([
                "id": .number(99),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object(["command": .string("ls")]),
            ])
        )
        if let s = String(data: approvalLine, encoding: .utf8) {
            try await pair.sidecar.writeLine(s + "\n")
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        let msgs = recorded.withLock { $0 }
        let resp = msgs.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 99 && o["result"] != nil
        }
        #expect(resp?["result"]?["decision"]?.stringValue == "accept")

        await client.close()
        await pair.sidecar.close()
        recordTask.cancel()
    }

    @Test func approvalHandlerDecline() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let recorded = LockedBox<[JSONValue]>([])
        let recordTask = Task {
            do {
                for try await line in pair.sidecar.lines {
                    if let data = line.data(using: .utf8),
                       let v = try? JSONDecoder().decode(JSONValue.self, from: data)
                    {
                        recorded.withLock { $0.append(v) }
                    }
                }
            } catch {}
        }

        let client = CodexAppServerClient(
            transport: pair.host,
            requestTimeoutMs: 5_000,
            onApproval: { _ in .decline }
        )

        let approvalLine = try JSONEncoder().encode(
            JSONValue.object([
                "id": .number(7),
                "method": .string("item/fileChange/requestApproval"),
                "params": .object(["path": .string("/tmp/x")]),
            ])
        )
        if let s = String(data: approvalLine, encoding: .utf8) {
            try await pair.sidecar.writeLine(s + "\n")
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        let msgs = recorded.withLock { $0 }
        let resp = msgs.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 7
        }
        #expect(resp?["result"]?["decision"]?.stringValue == "decline")

        await client.close()
        await pair.sidecar.close()
        recordTask.cancel()
    }

    @Test func closedClientRejectsRequest() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 1_000)
        await client.close()
        await pair.sidecar.close()

        do {
            _ = try await client.request(method: "ping")
            Issue.record("expected closed error")
        } catch let err as AppServerError {
            #expect(err.message.contains("closed"))
        }
    }

    @Test func extractIdHelpers() {
        let thread = JSONValue.object(["thread": .object(["id": .string("t1")])])
        #expect(extractThreadId(thread) == "t1")
        #expect(extractThreadId(.object(["threadId": .string("t2")])) == "t2")

        let turn = JSONValue.object(["turn": .object(["id": .string("u1")])])
        #expect(extractTurnId(turn) == "u1")
        #expect(isApprovalMethod("item/commandExecution/requestApproval"))
        #expect(isApprovalMethod("fooApproval"))
        #expect(!isApprovalMethod("turn/start"))
    }
}
