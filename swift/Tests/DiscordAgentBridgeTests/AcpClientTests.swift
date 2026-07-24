import Testing
import Foundation
@testable import DiscordAgentBridge

/// Minimal fake `grok agent stdio`: answers initialize / session/* and can emit notifications + permissions.
actor FakeGrokAcp {
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

        switch method {
        case "initialize":
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([
                    "protocolVersion": .number(1),
                    "serverInfo": .object(["name": .string("fake-grok")]),
                ]),
            ])
        case "session/new":
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(["sessionId": .string("sess-abc")]),
            ])
        case "session/load":
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([:]),
            ])
        case "session/prompt":
            // First text block routes the fake: "boom" → error response (turn failure);
            // else stream two agent_message_chunk updates then the terminator result.
            let firstText = msg["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? ""
            if firstText == "boom" {
                await write([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "error": .object([
                        "code": .number(-32000),
                        "message": .string("grok prompt failed"),
                    ]),
                ])
                return
            }
            for chunk in ["Hello", ", grok"] {
                await pushNotification(
                    method: "session/update",
                    params: .object(["update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["type": .string("text"), "text": .string(chunk)]),
                    ])])
                )
            }
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                // Echo inputs so the test can assert sessionPrompt sent correct params.
                "result": .object([
                    "stopReason": .string("end_turn"),
                    "echoSessionId": msg["params"]?["sessionId"] ?? .null,
                    "echoText": .string(firstText),
                ]),
            ])
        case "ping":
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(["pong": .bool(true)]),
            ])
        default:
            await write([
                "jsonrpc": .string("2.0"),
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
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params { obj["params"] = params }
        await write(obj)
    }

    func pushPermissionRequest(id: Int, params: JSONValue?) async {
        var obj: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/request_permission"),
        ]
        if let params { obj["params"] = params }
        await write(obj)
    }
}

@Suite("resolveGrokSpawn")
struct ResolveGrokSpawnTests {
    @Test func defaultsToGrokAgentStdio() {
        let spawn = resolveGrokSpawn(env: [:])
        #expect(spawn.command == "grok")
        #expect(spawn.args == ["agent", "stdio"])
    }

    @Test func grokCommandAndFlags() {
        let spawn = resolveGrokSpawn(
            env: [:],
            grokCommand: "/opt/grok",
            model: "grok-4",
            effort: "high",
            bypassPermissions: true
        )
        #expect(spawn.command == "/opt/grok")
        #expect(spawn.args == ["agent", "-m", "grok-4", "--reasoning-effort", "high", "--always-approve", "stdio"])
    }

    @Test func grokCmdEnvAppendsStdio() {
        let spawn = resolveGrokSpawn(env: ["GROK_CMD": "npx @xai/grok"])
        #expect(spawn.command == "npx")
        #expect(spawn.args == ["@xai/grok", "agent", "stdio"])
    }

    @Test func grokCmdEnvDoesNotDuplicateStdio() {
        let spawn = resolveGrokSpawn(env: ["GROK_CMD": "grok agent stdio"])
        #expect(spawn.command == "grok")
        #expect(spawn.args == ["agent", "stdio"])
    }

    @Test func grokCmdBareBinary() {
        let spawn = resolveGrokSpawn(env: ["GROK_CMD": "grok"])
        #expect(spawn.command == "grok")
        #expect(spawn.args == ["agent", "stdio"])
    }
}

@Suite("GrokAcpClient with fake transport")
struct AcpClientTests {
    @Test func initializeAndSessionNew() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        let initResult = try await client.initialize()
        #expect(initResult["serverInfo"]?["name"]?.stringValue == "fake-grok")
        #expect(client.initializeResult?["protocolVersion"]?.numberValue == 1)

        let sid = try await client.sessionNew(cwd: "/ws")
        #expect(sid == "sess-abc")
        #expect(client.sessionId == "sess-abc")

        try await client.sessionLoad(sessionId: "sess-resume", cwd: "/ws")
        #expect(client.sessionId == "sess-resume")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func genericRequestPing() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        let result = try await client.request(method: "ping")
        #expect(result["pong"]?.boolValue == true)

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func notificationsDispatched() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }

        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        let seen = LockedBox<[(String, JSONValue?)]>([])
        _ = client.onNotification { method, params in
            seen.withLock { $0.append((method, params)) }
        }

        await fake.pushNotification(
            method: "session/update",
            params: .object([
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("hi")]),
                ]),
            ])
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        let got = seen.withLock { $0 }
        #expect(got.count == 1)
        #expect(got.first?.0 == "session/update")
        #expect(
            got.first?.1?["update"]?["sessionUpdate"]?.stringValue == "agent_message_chunk"
        )

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func permissionDefaultDenyCancelled() async throws {
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

        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        let permLine = try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .number(42),
                "method": .string("session/request_permission"),
                "params": .object([
                    "sessionId": .string("s1"),
                    "toolCall": .object(["title": .string("Bash"), "kind": .string("execute")]),
                    "options": .array([
                        .object(["optionId": .string("allow_once"), "kind": .string("allow_once")]),
                        .object(["optionId": .string("reject_once"), "kind": .string("reject_once")]),
                    ]),
                ]),
            ])
        )
        if let s = String(data: permLine, encoding: .utf8) {
            try await pair.sidecar.writeLine(s + "\n")
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        let msgs = recorded.withLock { $0 }
        let resp = msgs.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 42 && o["result"] != nil
        }
        #expect(resp?["result"]?["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(resp?["result"]?["outcome"]?["optionId"]?.stringValue == "reject_once")

        await client.close()
        await pair.sidecar.close()
        recordTask.cancel()
    }

    @Test func permissionHandlerAllow() async throws {
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

        let client = GrokAcpClient(
            transport: pair.host,
            requestTimeoutMs: 5_000,
            onPermission: { _ in .allow }
        )
        let permLine = try JSONEncoder().encode(
            JSONValue.object([
                "id": .number(7),
                "method": .string("session/request_permission"),
                "params": .object([
                    "options": .array([
                        .object(["optionId": .string("allow_once"), "kind": .string("allow_once")]),
                    ]),
                ]),
            ])
        )
        if let s = String(data: permLine, encoding: .utf8) {
            try await pair.sidecar.writeLine(s + "\n")
        }
        try await Task.sleep(nanoseconds: 80_000_000)

        let msgs = recorded.withLock { $0 }
        let resp = msgs.first { msg in
            guard case .object(let o) = msg else { return false }
            return o["id"]?.numberValue == 7
        }
        #expect(resp?["result"]?["outcome"]?["optionId"]?.stringValue == "allow_once")

        await client.close()
        await pair.sidecar.close()
        recordTask.cancel()
    }

    @Test func closedClientRejectsRequest() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 1_000)
        await client.close()
        await pair.sidecar.close()

        do {
            _ = try await client.request(method: "ping")
            Issue.record("expected closed error")
        } catch let err as AcpClientError {
            #expect(err.message.contains("closed"))
        }
    }

    @Test func extractAndPermissionHelpers() {
        #expect(extractAcpSessionId(.object(["sessionId": .string("s1")])) == "s1")
        #expect(extractAcpSessionId(.object(["session_id": .string("s2")])) == "s2")
        #expect(isAcpPermissionMethod("session/request_permission"))
        #expect(!isAcpPermissionMethod("session/update"))

        let denyNoOpts = buildAcpPermissionResult(decision: .deny, options: [])
        #expect(denyNoOpts["outcome"]?["outcome"]?.stringValue == "cancelled")

        let allow = buildAcpPermissionResult(
            decision: .allow,
            options: [AcpPermissionOption(optionId: "a", kind: "allow_once")]
        )
        #expect(allow["outcome"]?["optionId"]?.stringValue == "a")
    }
}

@Suite("grokUpdateStep")
struct GrokUpdateStepTests {
    private func agentChunk(_ text: String) -> JSONValue {
        .object(["update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string(text)]),
        ])])
    }

    @Test func textChunkMaps() {
        #expect(grokUpdateStep(method: "session/update", params: agentChunk("hi")) == .appendText("hi"))
        // x.ai/session/update is the same stream (acpClient.ts:504)
        #expect(grokUpdateStep(method: "x.ai/session/update", params: agentChunk("y")) == .appendText("y"))
    }

    @Test func nonTextIgnored() {
        // agent_thought_chunk / tool_call are out of scope for the text reply path
        let thought = JSONValue.object(["update": .object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["text": .string("thinking")]),
        ])])
        #expect(grokUpdateStep(method: "session/update", params: thought) == .ignore)
        let tool = JSONValue.object(["update": .object(["sessionUpdate": .string("tool_call")])])
        #expect(grokUpdateStep(method: "session/update", params: tool) == .ignore)
        // empty text, unknown method
        #expect(grokUpdateStep(method: "session/update", params: agentChunk("")) == .ignore)
        #expect(grokUpdateStep(method: "session/cancel", params: nil) == .ignore)
    }
}

@Suite("GrokAcpClient prompt turn (fake transport)")
struct GrokPromptTurnTests {
    // Subscribe like a bridge would, run a prompt, assert the terminator result + accumulated text.
    @Test func promptAccumulatesAndCompletes() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)

        let text = LockedBox("")
        _ = client.onNotification { method, params in
            if case .appendText(let d) = grokUpdateStep(method: method, params: params) {
                text.withLock { $0 += d }
            }
        }

        _ = try await client.initialize()
        let sid = try await client.sessionNew(cwd: "/ws")
        let result = try await client.sessionPrompt(prompt: "hi")

        // (a) request params correct (echoed by the fake)
        #expect(result["echoSessionId"]?.stringValue == sid)
        #expect(result["echoText"]?.stringValue == "hi")
        // (b) terminator result readable
        #expect(result["stopReason"]?.stringValue == "end_turn")
        // (c) session/update chunks accumulated
        #expect(text.withLock { $0 } == "Hello, grok")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func promptErrorThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)

        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")
        do {
            _ = try await client.sessionPrompt(prompt: "boom")
            Issue.record("expected prompt error to throw")
        } catch let err as AcpClientError {
            #expect(err.message.contains("grok prompt failed"))
        }

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func promptWithoutSessionThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 1_000)
        do {
            _ = try await client.sessionPrompt(prompt: "hi")
            Issue.record("expected no-session error")
        } catch let err as AcpClientError {
            #expect(err.message.contains("no session"))
        }
        await client.close()
        await pair.sidecar.close()
    }
}
