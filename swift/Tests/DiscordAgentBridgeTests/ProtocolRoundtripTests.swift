import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("Protocol envelope encode/decode")
struct ProtocolRoundtripTests {
    @Test func reqRoundtrip() throws {
        let env = req(
            id: "h-1",
            method: "session.start",
            params: [
                "cwd": .string("/tmp"),
                "guildId": .string("g"),
                "channelId": .string("c"),
                "permMode": .string("default"),
            ]
        )
        let line = try serializeEnvelope(env)
        let back = try parseEnvelope(line)
        #expect(back.v == 1)
        #expect(back.type == .req)
        #expect(back.id == "h-1")
        #expect(back.method == "session.start")
        #expect(back.params?["cwd"]?.stringValue == "/tmp")
    }

    @Test func resErrorRoundtrip() throws {
        let env = resError(
            id: "h-2",
            method: "session.send",
            error: makeError(code: "unknown_session", message: "no such session", retryable: false),
            session: "s-1"
        )
        let back = try parseEnvelope(try serializeEnvelope(env))
        #expect(back.type == EnvelopeType.res)
        #expect(back.error?.code == "unknown_session")
        #expect(back.error?.message == "no such session")
        #expect(back.session == "s-1")
    }

    @Test func notifyReadyRoundtrip() throws {
        let env = notify(method: "sidecar.ready", params: ["v": .number(1)])
        let back = try parseEnvelope(try serializeEnvelope(env))
        #expect(back.type == .notify)
        #expect(back.method == "sidecar.ready")
    }

    @Test func emptyLineThrows() {
        #expect(throws: ProtocolParseError.emptyLine) {
            _ = try parseEnvelope("   ")
        }
    }

    @Test func invalidJSONThrows() {
        #expect(throws: ProtocolParseError.invalidJSON) {
            _ = try parseEnvelope("{not json")
        }
    }

    @Test func badVersionThrows() {
        #expect(throws: ProtocolParseError.unsupportedVersion("2")) {
            _ = try parseEnvelope(#"{"v":2,"type":"notify","method":"x"}"#)
        }
    }
}

@Suite("AgentEvent Codable")
struct AgentEventTests {
    @Test func textRoundtrip() throws {
        let ev = AgentEvent.text(text: "Hello", delta: true)
        let data = try JSONEncoder().encode(ev)
        let back = try JSONDecoder().decode(AgentEvent.self, from: data)
        #expect(back == .text(text: "Hello", delta: true))
        #expect(back.kind == "text")
    }

    @Test func toolUseRoundtrip() throws {
        let ev = AgentEvent.toolUse(
            id: "t1",
            name: "Bash",
            input: ["command": .string("ls")],
            parentToolUseId: nil
        )
        let data = try JSONEncoder().encode(ev)
        let back = try JSONDecoder().decode(AgentEvent.self, from: data)
        #expect(back.kind == "tool_use")
        if case .toolUse(let id, let name, let input, _) = back {
            #expect(id == "t1")
            #expect(name == "Bash")
            #expect(input["command"]?.stringValue == "ls")
        } else {
            Issue.record("expected tool_use")
        }
    }

    @Test func eventInEnvelope() throws {
        let env = eventEnvelope(
            session: "local-1",
            event: .text(text: "Hi", delta: true)
        )
        let back = try parseEnvelope(try serializeEnvelope(env))
        #expect(back.type == .event)
        #expect(back.session == "local-1")
        #expect(back.event == .text(text: "Hi", delta: true))
    }

    @Test func allKindsEncode() throws {
        let samples: [AgentEvent] = [
            .text(text: "a", delta: false),
            .thinking(text: "t", delta: true),
            .toolUse(id: "1", name: "N", input: .null, parentToolUseId: "p"),
            .toolResult(id: "1", ok: true, content: "ok", parentToolUseId: nil),
            .permissionRequest(id: "p", toolName: "Bash", input: [:]),
            .progress(label: "work", detail: "x"),
            .result(text: "done", costUsd: 0.01, tokensIn: 1, tokensOut: 2, durationMs: 3),
            .contextUsage(
                totalTokens: 10, maxTokens: 100, percentage: 10,
                model: "m", modelDisplayName: "M",
                clearableTokens: 1, memoryFileCount: 0, mcpServerCount: 0
            ),
            .subagentResult(
                taskId: "t", status: .completed, summary: "s",
                toolUseId: nil, durationMs: 1, toolUses: 2
            ),
            .error(message: "e", retryable: true),
            .rateLimit(resetAt: "2026-01-01", rateLimitType: "five_hour", utilization: 0.5),
        ]
        for ev in samples {
            let data = try JSONEncoder().encode(ev)
            let back = try JSONDecoder().decode(AgentEvent.self, from: data)
            #expect(back.kind == ev.kind)
        }
    }
}

@Suite("Spawn resolution")
struct SpawnTests {
    @Test func envOverride() {
        let spawn = resolveClaudeSidecarSpawn(
            env: ["DAB_CLAUDE_SIDECAR_CMD": "node /tmp/cli.js --flag"],
            repoRoot: URL(fileURLWithPath: "/nonexistent")
        )
        #expect(spawn.command == "node")
        #expect(spawn.args == ["/tmp/cli.js", "--flag"])
    }

    @Test func findsTsxWhenPresent() {
        guard let root = findRepoRoot() else {
            // Running without monorepo layout — skip
            return
        }
        let spawn = resolveClaudeSidecarSpawn(env: [:], repoRoot: root)
        #expect(spawn.command == "node")
        #expect(!spawn.args.isEmpty)
        // Prefer dist if exists, else tsx + src
        let joined = spawn.args.joined(separator: " ")
        #expect(joined.contains("cli.js") || joined.contains("cli.ts"))
    }
}
