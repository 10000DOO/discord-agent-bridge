import Testing
import Foundation
@testable import DiscordAgentBridge

// Shared helpers for the three-client hardening suites. Reuse the Fake*/InMemory pairs
// from SidecarClientTests / AppServerClientTests / AcpClientTests.

private func writeRaw(_ t: InMemorySidecarTransport, _ obj: [String: JSONValue]) async {
    guard let data = try? JSONEncoder().encode(JSONValue.object(obj)),
          let s = String(data: data, encoding: .utf8)
    else { return }
    try? await t.writeLine(s + "\n")
}

private func emitReady(_ t: InMemorySidecarTransport) async {
    if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
        try? await t.writeLine(line + "\n")
    }
}

private func decodeObject(_ line: String) -> [String: JSONValue]? {
    guard let data = line.data(using: .utf8),
          let v = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .object(let o) = v
    else { return nil }
    return o
}

/// Answer the first request seen on `t` with the given canned fields (echoing its id).
private func respondOnce(_ t: InMemorySidecarTransport, with fields: [String: JSONValue]) -> Task<Void, Never> {
    Task {
        do {
            for try await line in t.lines {
                guard let msg = decodeObject(line), let id = msg["id"] else { continue }
                var out = fields
                out["id"] = id
                await writeRaw(t, out)
                return
            }
        } catch {}
    }
}

@Suite("Claude client hardening")
struct ClaudeClientHardeningTests {
    @Test func requestTimeoutRetryable() async throws {
        let pair = InMemorySidecarTransport.makePair()
        await emitReady(pair.sidecar) // ready, but nobody answers requests
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 100)
        try await client.connect()

        do {
            _ = try await client.request(method: "session.stop", params: ["session": .string("x")], session: "x")
            Issue.record("expected timeout")
        } catch let err as SidecarRpcError {
            #expect(err.message.contains("timeout"))
            #expect(err.retryable)
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func inFlightRejectedOnTransportClose() async throws {
        let pair = InMemorySidecarTransport.makePair()
        await emitReady(pair.sidecar)
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        let task = Task { try await client.request(method: "session.stop", params: ["session": .string("x")], session: "x") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await pair.host.close() // finishes host.lines → read loop ends → failAll

        do {
            _ = try await task.value
            Issue.record("expected in-flight rejection")
        } catch let err as SidecarRpcError {
            #expect(err.message.contains("closed"))
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func errorResponseThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        do {
            _ = try await client.request(method: "bogus.method")
            Issue.record("expected error response to throw")
        } catch let err as SidecarRpcError {
            #expect(err.code == "unsupported")
        }
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func backendIdNotifyReachesHandler() async throws {
        let pair = InMemorySidecarTransport.makePair()
        await emitReady(pair.sidecar)
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        let got = LockedBox<String?>(nil)
        client.registerSessionHandlers(
            handle: "sess-1",
            handlers: SidecarSessionHandlers(onEvent: { _ in }, onBackendId: { backend in got.withLock { $0 = backend } })
        )
        await writeRaw(pair.sidecar, [
            "v": .number(1),
            "type": .string("notify"),
            "method": .string("session.backend_id"),
            "session": .string("sess-1"),
            "params": .object(["backendSessionId": .string("backend-xyz")]),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(got.withLock { $0 } == "backend-xyz")

        await client.close()
        await pair.sidecar.close()
    }
}

@Suite("Codex client hardening")
struct CodexClientHardeningTests {
    @Test func requestTimeout() async throws {
        let pair = InMemorySidecarTransport.makePair() // no responder
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 100)
        do {
            _ = try await client.request(method: "ping")
            Issue.record("expected timeout")
        } catch let err as AppServerError {
            #expect(err.message.contains("timed out"))
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func inFlightRejectedOnTransportClose() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        let task = Task { try await client.request(method: "ping") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await pair.host.close()
        do {
            _ = try await task.value
            Issue.record("expected in-flight rejection")
        } catch let err as AppServerError {
            #expect(err.message.contains("closed"))
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func errorResponseThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeAppServer(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        do {
            _ = try await client.request(method: "bogus")
            Issue.record("expected error response to throw")
        } catch let err as AppServerError {
            #expect(err.message.contains("-32601"))
        }
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func threadStartNoIdThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let responder = respondOnce(pair.sidecar, with: ["result": .object([:])])
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        do {
            _ = try await client.threadStart(params: .object([:]))
            Issue.record("expected no thread.id error")
        } catch let err as AppServerError {
            #expect(err.message.contains("thread.id"))
        }
        await client.close()
        await pair.sidecar.close()
        responder.cancel()
    }

    @Test func turnStartNoIdThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let responder = respondOnce(pair.sidecar, with: ["result": .object([:])])
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        do {
            _ = try await client.turnStart(params: .object([:]))
            Issue.record("expected no turn.id error")
        } catch let err as AppServerError {
            #expect(err.message.contains("turn.id"))
        }
        await client.close()
        await pair.sidecar.close()
        responder.cancel()
    }

    @Test func nonApprovalServerRequestGetsMethodNotFound() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let recorded = LockedBox<[JSONValue]>([])
        let recordTask = Task {
            do {
                for try await line in pair.sidecar.lines {
                    if let o = decodeObject(line) { recorded.withLock { $0.append(.object(o)) } }
                }
            } catch {}
        }
        let client = CodexAppServerClient(transport: pair.host, requestTimeoutMs: 5_000)
        await writeRaw(pair.sidecar, [
            "id": .number(11),
            "method": .string("tools/list"), // non-approval server → host request
            "params": .object([:]),
        ])
        try await Task.sleep(nanoseconds: 80_000_000)
        let resp = recorded.withLock { $0 }.first { m in
            guard case .object(let o) = m else { return false }
            return o["id"]?.numberValue == 11 && o["error"] != nil
        }
        #expect(resp?["error"]?["code"]?.numberValue == -32601)

        await client.close()
        await pair.sidecar.close()
        recordTask.cancel()
    }
}

@Suite("Grok client hardening")
struct GrokClientHardeningTests {
    @Test func requestTimeout() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 100)
        do {
            _ = try await client.request(method: "ping")
            Issue.record("expected timeout")
        } catch let err as AcpClientError {
            #expect(err.message.contains("timed out"))
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func inFlightRejectedOnTransportClose() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        let task = Task { try await client.request(method: "ping") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await pair.host.close()
        do {
            _ = try await task.value
            Issue.record("expected in-flight rejection")
        } catch let err as AcpClientError {
            #expect(err.message.contains("closed"))
        }
        await client.close()
        await pair.sidecar.close()
    }

    @Test func errorResponseThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = FakeGrokAcp(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        do {
            _ = try await client.request(method: "bogus")
            Issue.record("expected error response to throw")
        } catch let err as AcpClientError {
            #expect(err.message.contains("-32601"))
        }
        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }

    @Test func sessionNewNoIdThrows() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let responder = respondOnce(pair.sidecar, with: ["result": .object([:])])
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        do {
            _ = try await client.sessionNew(cwd: "/ws")
            Issue.record("expected no sessionId error")
        } catch let err as AcpClientError {
            #expect(err.message.contains("sessionId"))
        }
        await client.close()
        await pair.sidecar.close()
        responder.cancel()
    }

    @Test func nonPermissionServerRequestGetsMethodNotFound() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let recorded = LockedBox<[JSONValue]>([])
        let recordTask = Task {
            do {
                for try await line in pair.sidecar.lines {
                    if let o = decodeObject(line) { recorded.withLock { $0.append(.object(o)) } }
                }
            } catch {}
        }
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        await writeRaw(pair.sidecar, [
            "jsonrpc": .string("2.0"),
            "id": .number(21),
            "method": .string("fs/read_text_file"), // non-permission server → host request
            "params": .object([:]),
        ])
        try await Task.sleep(nanoseconds: 80_000_000)
        let resp = recorded.withLock { $0 }.first { m in
            guard case .object(let o) = m else { return false }
            return o["id"]?.numberValue == 21 && o["error"] != nil
        }
        #expect(resp?["error"]?["code"]?.numberValue == -32601)

        await client.close()
        await pair.sidecar.close()
        recordTask.cancel()
    }
}
