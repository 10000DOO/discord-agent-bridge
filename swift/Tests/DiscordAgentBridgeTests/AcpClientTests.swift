import Testing
import Foundation
@testable import DiscordAgentBridge

/// Minimal fake `grok agent stdio`: answers initialize / session/* and can emit notifications + permissions.
actor FakeGrokAcp {
    private let transport: InMemorySidecarTransport
    /// Last session/new or session/load params (G-P1-11 meta/mcpServers assertions).
    private(set) var lastSessionParams: JSONValue?
    /// Last session/prompt params.
    private(set) var lastPromptParams: JSONValue?

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
            lastSessionParams = msg["params"]
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(["sessionId": .string("sess-abc")]),
            ])
        case "session/load":
            lastSessionParams = msg["params"]
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([:]),
            ])
        case "session/prompt":
            lastPromptParams = msg["params"]
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
            // Hold path: "hold" never completes until process closes (concurrent prompt test).
            if firstText == "hold" {
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
            let promptBlocks = msg["params"]?["prompt"] ?? .null
            await write([
                "jsonrpc": .string("2.0"),
                "id": id,
                // Echo inputs so the test can assert sessionPrompt sent correct params.
                "result": .object([
                    "stopReason": .string("end_turn"),
                    "echoSessionId": msg["params"]?["sessionId"] ?? .null,
                    "echoText": .string(firstText),
                    "echoPrompt": promptBlocks,
                    "_meta": .object([
                        "totalTokens": .number(42),
                        "modelId": .string("grok-4.5"),
                        "usage": .object([
                            "inputTokens": .number(10),
                            "outputTokens": .number(5),
                            "costUsdTicks": .number(1e9),
                        ]),
                    ]),
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
            bypassPermissions: true,
            isGrokModel: { _ in true }
        )
        #expect(spawn.command == "/opt/grok")
        #expect(spawn.args == ["agent", "-m", "grok-4", "--reasoning-effort", "high", "--always-approve", "stdio"])
    }

    @Test func omitsModelWhenIsGrokModelRejects() {
        let spawn = resolveGrokSpawn(
            env: [:],
            model: "opus",
            effort: "high",
            isGrokModel: { _ in false }
        )
        #expect(spawn.args == ["agent", "--reasoning-effort", "high", "stdio"])
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
        #expect(await waitUntil { seen.withLock { $0.count } >= 1 })

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
        #expect(await waitUntil {
            recorded.withLock { $0 }.contains { msg in
                guard case .object(let o) = msg else { return false }
                return o["id"]?.numberValue == 42 && o["result"] != nil
            }
        })

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
        #expect(await waitUntil {
            recorded.withLock { $0 }.contains { msg in
                guard case .object(let o) = msg else { return false }
                return o["id"]?.numberValue == 7 && o["result"] != nil
            }
        })

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

    // H3 (security regression): formatAcpRpcError must scrub secrets the same way buildExitError
    // does — a backend-echoed error message can carry a leaked token, and it must not reach the
    // user unmasked.
    @Test func formatAcpRpcErrorRedactsSecrets() {
        let withXaiKey = formatAcpRpcError(.object([
            "code": .number(-32000),
            "message": .string("auth failed for xai-abcdEFGH12345678ijklmnop"),
        ]))
        #expect(!withXaiKey.contains("xai-abcdEFGH12345678ijklmnop"))
        #expect(withXaiKey.contains("[REDACTED]"))

        let withBearerToken = formatAcpRpcError(.object([
            "code": .number(401),
            "message": .string("rejected: Bearer sk-ant-1234567890abcdefgh"),
        ]))
        #expect(!withBearerToken.contains("sk-ant-1234567890abcdefgh"))

        // Non-secret messages still pass through unchanged (besides the fixed prefix).
        let plain = formatAcpRpcError(.object([
            "code": .number(-32601),
            "message": .string("method not found"),
        ]))
        #expect(plain == "grok agent stdio error -32601: method not found")
    }
}

@Suite("classifyAcpFailure / stderrTail")
struct AcpFailureClassifyTests {
    @Test func authFailureReturnsLoginHint() {
        #expect(classifyAcpFailure("Error: not authenticated. Run grok login.") == ACP_LOGIN_MESSAGE)
        #expect(classifyAcpFailure("please log in") == ACP_LOGIN_MESSAGE)
        #expect(classifyAcpFailure("unauthorized token") == ACP_LOGIN_MESSAGE)
    }

    @Test func enoentReturnsNotInstalled() {
        #expect(classifyAcpFailure("spawn grok ENOENT", code: "ENOENT") == ACP_NOT_INSTALLED_MESSAGE)
        #expect(classifyAcpFailure("Error: ENOENT") == ACP_NOT_INSTALLED_MESSAGE)
    }

    @Test func genericReturnsNil() {
        #expect(classifyAcpFailure("segfault at 0x0") == nil)
        #expect(classifyAcpFailure("") == nil)
    }

    @Test func stderrTailTruncatesWithEllipsis() {
        let long = String(repeating: "a", count: 600)
        let tail = stderrTail(long, maxChars: 500)
        #expect(tail.hasPrefix("…"))
        #expect(tail.count == 501) // ellipsis + 500
        #expect(stderrTail("  short  ") == "short")
    }
}

@Suite("GrokAcpClient control vs prompt timeout")
struct AcpControlPromptTimeoutTests {
    @Test func controlRequestTimesOutWhenNoResponse() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 60)
        do {
            _ = try await client.request(method: "ping")
            Issue.record("expected control timeout")
        } catch let err as AcpClientError {
            #expect(err.message.contains("timed out after 60ms"))
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func sessionPromptHasNoClientTimeout() async throws {
        // Short control budget; prompt waits past it, then fake responds.
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 80)
        let fake = Task {
            do {
                for try await line in pair.sidecar.lines {
                    guard let data = line.data(using: .utf8),
                          let v = try? JSONDecoder().decode(JSONValue.self, from: data),
                          case .object(let msg) = v,
                          let method = msg["method"]?.stringValue,
                          let id = msg["id"]
                    else { continue }
                    switch method {
                    case "initialize":
                        try? await pair.sidecar.writeLine(
                            #"{"jsonrpc":"2.0","id":\#(Int(id.numberValue ?? 0)),"result":{"protocolVersion":1}}"# + "\n"
                        )
                    case "session/new":
                        try? await pair.sidecar.writeLine(
                            #"{"jsonrpc":"2.0","id":\#(Int(id.numberValue ?? 0)),"result":{"sessionId":"s-late"}}"# + "\n"
                        )
                    case "session/prompt":
                        // Wait longer than control timeout (80ms) then complete.
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        try? await pair.sidecar.writeLine(
                            #"{"jsonrpc":"2.0","id":\#(Int(id.numberValue ?? 0)),"result":{"stopReason":"end_turn"}}"# + "\n"
                        )
                    default:
                        break
                    }
                }
            } catch {}
        }
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")
        let result = try await client.sessionPrompt(prompt: "late")
        #expect(result["stopReason"]?.stringValue == "end_turn")
        await client.close()
        await pair.sidecar.close()
        fake.cancel()
    }

    @Test func explicitNilTimeoutDoesNotFireTimer() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 50)
        let idBox = LockedBox<Int?>(nil)
        let watch = Task {
            do {
                for try await line in pair.sidecar.lines {
                    guard let data = line.data(using: .utf8),
                          let v = try? JSONDecoder().decode(JSONValue.self, from: data),
                          case .object(let msg) = v,
                          let id = msg["id"]?.numberValue
                    else { continue }
                    idBox.withLock { $0 = Int(id) }
                    // Respond after 150ms (> control 50ms) — nil timeout must still wait.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    try? await pair.sidecar.writeLine(
                        #"{"jsonrpc":"2.0","id":\#(Int(id)),"result":{"ok":true}}"# + "\n"
                    )
                    break
                }
            } catch {}
        }
        let result = try await client.request(method: "custom/slow", params: nil, timeoutMs: nil)
        #expect(result["ok"]?.boolValue == true)
        #expect(idBox.withLock { $0 } != nil)
        watch.cancel()
        await client.close()
        await pair.sidecar.close()
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

    @Test func nonTextIgnoredOnTextPath() {
        // agent_thought_chunk stays out of the text reply path; tool_call → grokToolEvents
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

    @Test func toolCallMapsToToolUse() {
        var seq = 0
        let params = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("t1"),
            "title": .string("Bash"),
            "kind": .string("execute"),
            "rawInput": .object(["command": .string("ls")]),
        ])])
        let events = grokToolEvents(method: "session/update", params: params, mintId: &seq)
        #expect(events == [
            .toolUse(
                id: "t1",
                name: "Bash",
                input: .object(["command": .string("ls")]),
                parentToolUseId: nil
            ),
        ])
    }

    @Test func toolCallEditNormalizesNameAndInput() {
        var seq = 0
        let params = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("e1"),
            "title": .string("edit file"),
            "kind": .string("edit"),
            "rawInput": .object([
                "path": .string("/ws/a.ts"),
                "oldText": .string("a"),
                "newText": .string("b"),
            ]),
            "parentToolId": .string("parent-1"),
        ])])
        let events = grokToolEvents(method: "session/update", params: params, mintId: &seq)
        guard case .toolUse(let id, let name, let input, let parent)? = events.first else {
            Issue.record("expected tool_use"); return
        }
        #expect(id == "e1")
        #expect(name == "Edit")
        #expect(parent == "parent-1")
        #expect(input["file_path"]?.stringValue == "/ws/a.ts")
        #expect(input["old_string"]?.stringValue == "a")
        #expect(input["new_string"]?.stringValue == "b")
    }

    @Test func toolCallUpdateTerminalOnly() {
        var seq = 0
        let intermediate = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("t1"),
            // no status — intermediate (diff carrier)
            "content": .string("diff body"),
        ])])
        #expect(grokToolEvents(method: "session/update", params: intermediate, mintId: &seq).isEmpty)

        let done = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("t1"),
            "status": .string("completed"),
            "content": .string("ok"),
        ])])
        #expect(grokToolEvents(method: "session/update", params: done, mintId: &seq) == [
            .toolResult(id: "t1", ok: true, content: "ok", parentToolUseId: nil),
        ])

        let failed = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("t2"),
            "status": .string("failed"),
            "rawOutput": .string("boom"),
        ])])
        #expect(grokToolEvents(method: "session/update", params: failed, mintId: &seq) == [
            .toolResult(id: "t2", ok: false, content: "boom", parentToolUseId: nil),
        ])
    }

    // M19: parentToolId falls back through top-level snake_case, then `_meta` (camelCase then
    // snake_case), in that order — top-level camelCase always wins when present (TS extractUpdate).
    @Test func toolCallParentToolIdFallsBackThroughSnakeCaseAndMeta() {
        var seq = 0

        let snakeTop = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("t1"),
            "title": .string("Bash"),
            "parent_tool_use_id": .string("parent-snake"),
        ])])
        guard case .toolUse(_, _, _, let p1)? = grokToolEvents(method: "session/update", params: snakeTop, mintId: &seq).first else {
            Issue.record("expected tool_use"); return
        }
        #expect(p1 == "parent-snake")

        let metaCamel = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("t2"),
            "title": .string("Bash"),
            "_meta": .object(["parentToolId": .string("parent-meta-camel")]),
        ])])
        guard case .toolUse(_, _, _, let p2)? = grokToolEvents(method: "session/update", params: metaCamel, mintId: &seq).first else {
            Issue.record("expected tool_use"); return
        }
        #expect(p2 == "parent-meta-camel")

        let metaSnake = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("t3"),
            "title": .string("Bash"),
            "_meta": .object(["parent_tool_use_id": .string("parent-meta-snake")]),
        ])])
        guard case .toolUse(_, _, _, let p3)? = grokToolEvents(method: "session/update", params: metaSnake, mintId: &seq).first else {
            Issue.record("expected tool_use"); return
        }
        #expect(p3 == "parent-meta-snake")

        // Top-level camelCase wins over `_meta` when both are present.
        let both = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string("t4"),
            "title": .string("Bash"),
            "parentToolId": .string("top-wins"),
            "_meta": .object(["parentToolId": .string("meta-loses")]),
        ])])
        guard case .toolUse(_, _, _, let p4)? = grokToolEvents(method: "session/update", params: both, mintId: &seq).first else {
            Issue.record("expected tool_use"); return
        }
        #expect(p4 == "top-wins")
    }

    @Test func toolCallMintsIdWhenMissing() {
        var seq = 0
        let params = JSONValue.object(["update": .object([
            "sessionUpdate": .string("tool_call"),
            "title": .string("Read"),
        ])])
        let events = grokToolEvents(method: "session/update", params: params, mintId: &seq)
        #expect(seq == 1)
        #expect(events.first == .toolUse(
            id: "grok-tool-1",
            name: "Read",
            input: .object([:]),
            parentToolUseId: nil
        ))
    }

    // W16-g gap: agent_thought_chunk / plan → thinking / progress (TS acpSession mapUpdate).

    @Test func thoughtChunkMapsToThinking() {
        let params = JSONValue.object(["update": .object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["type": .string("text"), "text": .string("pondering")]),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: params) == [
            .thinking(text: "pondering", delta: true),
        ])
        // x.ai method alias
        #expect(grokProgressEvents(method: "x.ai/session/update", params: params) == [
            .thinking(text: "pondering", delta: true),
        ])
        // empty / missing text skipped (TS parity)
        let empty = JSONValue.object(["update": .object([
            "sessionUpdate": .string("agent_thought_chunk"),
            "content": .object(["text": .string("")]),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: empty).isEmpty)
        let bare = JSONValue.object(["update": .object([
            "sessionUpdate": .string("agent_thought_chunk"),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: bare).isEmpty)
        // text path stays clean
        #expect(grokUpdateStep(method: "session/update", params: params) == .ignore)
    }

    @Test func planMapsToProgressWithStatusMarks() {
        let params = JSONValue.object(["update": .object([
            "sessionUpdate": .string("plan"),
            "entries": .array([
                .object(["content": .string("read the file"), "status": .string("completed")]),
                .object(["content": .string("write the fix"), "status": .string("in_progress")]),
                .object(["content": .string("run tests"), "status": .string("pending")]),
                .object(["status": .string("pending")]), // no content → skipped
            ]),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: params) == [
            .progress(
                label: "Plan",
                detail: "✓ read the file\n▶ write the fix\n• run tests"
            ),
        ])
    }

    @Test func planEmptyEntriesStillEmitsBarePlan() {
        let empty = JSONValue.object(["update": .object([
            "sessionUpdate": .string("plan"),
            "entries": .array([]),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: empty) == [
            .progress(label: "Plan", detail: nil),
        ])
        let noEntries = JSONValue.object(["update": .object([
            "sessionUpdate": .string("plan"),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: noEntries) == [
            .progress(label: "Plan", detail: nil),
        ])
        // unknown method / non-progress kinds
        #expect(grokProgressEvents(method: "session/cancel", params: nil).isEmpty)
        let tool = JSONValue.object(["update": .object(["sessionUpdate": .string("tool_call")])])
        #expect(grokProgressEvents(method: "session/update", params: tool).isEmpty)
        let msg = JSONValue.object(["update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["text": .string("hi")]),
        ])])
        #expect(grokProgressEvents(method: "session/update", params: msg).isEmpty)
    }

    @Test func planStatusMarkMapping() {
        #expect(planStatusMark("completed") == "✓")
        #expect(planStatusMark("in_progress") == "▶")
        #expect(planStatusMark("pending") == "•")
        #expect(planStatusMark(nil) == "•")
        #expect(planStatusMark("unknown") == "•")
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

    @Test func lastPromptResultStoredAfterSuccess() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")
        #expect(client.lastPromptResult == nil)
        let result = try await client.sessionPrompt(prompt: "hi")
        #expect(client.lastPromptResult == result)
        #expect(result["stopReason"]?.stringValue == "end_turn")
        #expect(result["_meta"]?["modelId"]?.stringValue == "grok-4.5")
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func concurrentPromptRejected() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")

        let first = Task { try await client.sessionPrompt(prompt: "hold") }
        // Let the first request leave the client and set promptInFlight.
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            _ = try await client.sessionPrompt(prompt: "second")
            Issue.record("expected already-in-flight error")
        } catch let err as AcpClientError {
            #expect(err.message.contains("already in flight"))
        }
        first.cancel()
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func multimodalPromptBlocks() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")
        let result = try await client.sessionPrompt(blocks: [
            .text("see this"),
            .image(data: "aW1n", mimeType: "image/png"),
        ])
        #expect(result["echoPrompt"]?.arrayValue?.count == 2)
        #expect(result["echoPrompt"]?.arrayValue?[0]["type"]?.stringValue == "text")
        #expect(result["echoPrompt"]?.arrayValue?[1]["type"]?.stringValue == "image")
        #expect(result["echoPrompt"]?.arrayValue?[1]["mimeType"]?.stringValue == "image/png")
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func emptyBlocksBecomeSpaceText() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")
        let result = try await client.sessionPrompt(blocks: [])
        #expect(result["echoText"]?.stringValue == " ")
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }
}

@Suite("GrokAcpClient session meta / mcpServers (G-P1-11)")
struct GrokAcpSessionMetaMcpTests {
    @Test func sessionNewAttachesMetaAndEmptyMcpByDefault() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        _ = try await client.initialize()
        _ = try await client.sessionNew(
            cwd: "/ws",
            meta: AcpSessionMeta(rules: "be terse", systemPromptOverride: "X")
        )
        // sessionNew awaits the RPC response, so lastSessionParams is already set.
        let params = await fake.lastSessionParams
        #expect(params?["cwd"]?.stringValue == "/ws")
        #expect(params?["mcpServers"]?.arrayValue?.isEmpty == true)
        #expect(params?["_meta"]?["rules"]?.stringValue == "be terse")
        #expect(params?["_meta"]?["systemPromptOverride"]?.stringValue == "X")
        #expect(params?["_meta"]?["agentProfile"] == nil)
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func sessionNewOmitsMetaWhenNil() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/tmp/ws")
        let params = await fake.lastSessionParams
        #expect(params?["_meta"] == nil)
        #expect(params?["mcpServers"]?.arrayValue?.isEmpty == true)
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func mcpServersForwardedAsNameValueEnvArray() async throws {
        let mcp = [
            AcpMcpServerConfig(
                name: "discord",
                command: "/usr/bin/node",
                args: ["/tmp/attach.mjs"],
                env: [
                    AcpMcpEnvVar(name: "DAB_ATTACH_URL", value: "http://127.0.0.1:9"),
                    AcpMcpEnvVar(name: "DAB_ATTACH_TOKEN", value: "tok"),
                    AcpMcpEnvVar(name: "DAB_WORKSPACE", value: "/ws"),
                ]
            ),
        ]
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000, mcpServers: mcp)
        _ = try await client.initialize()
        _ = try await client.sessionNew(cwd: "/ws")
        let servers = await fake.lastSessionParams?["mcpServers"]?.arrayValue
        #expect(servers?.count == 1)
        #expect(servers?[0]["name"]?.stringValue == "discord")
        #expect(servers?[0]["command"]?.stringValue == "/usr/bin/node")
        let env = servers?[0]["env"]?.arrayValue
        #expect(env?.count == 3)
        #expect(env?[0]["name"]?.stringValue == "DAB_ATTACH_URL")
        #expect(env?[0]["value"]?.stringValue == "http://127.0.0.1:9")

        try await client.sessionLoad(sessionId: "sess-9", cwd: "/ws")
        let loadParams = await fake.lastSessionParams
        #expect(loadParams?["sessionId"]?.stringValue == "sess-9")
        let loadServers = loadParams?["mcpServers"]?.arrayValue
        #expect(loadServers?.count == 1)
        #expect(loadServers?[0]["name"]?.stringValue == "discord")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func metaAndMcpWireHelpers() {
        let meta = AcpSessionMeta(rules: "r", agentProfile: .string("default"))
        let j = meta.asJSON()
        #expect(j["rules"]?.stringValue == "r")
        #expect(j["agentProfile"]?.stringValue == "default")
        #expect(j["systemPromptOverride"] == nil)

        let blockText = AcpPromptBlock.text("hi").asJSON()
        #expect(blockText["type"]?.stringValue == "text")
        let blockImg = AcpPromptBlock.image(data: "qq", mimeType: "image/jpeg").asJSON()
        #expect(blockImg["type"]?.stringValue == "image")
        #expect(blockImg["data"]?.stringValue == "qq")
    }
}
