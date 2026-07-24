import Testing
import Foundation
@testable import DiscordAgentBridge

private let bigTimeout: UInt64 = 60_000_000_000   // 60s — never fires within a test

/// Spin (no sleep) until the awaiting Task has registered its continuation on the gate.
private func waitRegistered(_ gate: PermissionGate) async {
    while await gate.pendingCount() == 0 { await Task.yield() }
}

@Suite("PermissionGate")
struct PermissionGateTests {
    @Test func resolveAllowAndDeny() async {
        for expected in [PermissionDecision.allow, .deny] {
            let gate = PermissionGate()
            let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner"), timeoutNs: bigTimeout) }
            await waitRegistered(gate)
            #expect(await gate.resolve(reqKey: "k", action: expected, byUserId: "owner") == true)
            #expect(await t.value == expected)
        }
    }

    @Test func timeoutDeniesByDefault() async {
        let gate = PermissionGate()
        let decision = await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash"), timeoutNs: 50_000_000) // 50ms
        #expect(decision == .deny)
    }

    @Test func approverMismatchIgnored() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner"), timeoutNs: bigTimeout) }
        await waitRegistered(gate)
        // Bystander cannot answer.
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "other") == false)
        #expect(await gate.pendingCount() == 1)   // still pending
        // The owner can.
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "owner") == true)
        #expect(await t.value == .allow)
    }

    @Test func unknownReqKeyIsNoOp() async {
        let gate = PermissionGate()
        #expect(await gate.resolve(reqKey: "nope", action: .allow) == false)
    }

    @Test func secondResolveIsNoOp() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner"), timeoutNs: bigTimeout) }
        await waitRegistered(gate)
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "owner") == true)
        _ = await t.value
        #expect(await gate.resolve(reqKey: "k", action: .deny, byUserId: "owner") == false)   // already settled
    }

    // Regression guard (c2 security RV): a prompt with NO approver cannot be resolved by anyone —
    // it stays pending and deny-by-defaults at timeout (never auto-allow via a stray click).
    @Test func nilApproverCannotBeResolved() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash"), timeoutNs: 60_000_000) } // 60ms
        await waitRegistered(gate)
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "anyone") == false)
        #expect(await gate.resolve(reqKey: "k", action: .allow) == false)   // byUserId nil too
        #expect(await gate.pendingCount() == 1)   // still pending → will deny at timeout
        #expect(await t.value == .deny)
    }
}

@Suite("permission custom_id")
struct PermissionCustomIdTests {
    @Test func roundtrip() {
        #expect(buildCustomId(reqKey: "abc", action: .allow) == "perm:abc:allow")
        #expect(parseCustomId("perm:abc:allow")?.reqKey == "abc")
        #expect(parseCustomId("perm:abc:allow")?.action == .allow)
        #expect(parseCustomId("perm:xy:deny")?.action == .deny)
    }

    @Test func rejectsGarbage() {
        #expect(parseCustomId("perm:abc") == nil)               // 2 tokens
        #expect(parseCustomId("perm:abc:allow:extra") == nil)   // 4 tokens
        #expect(parseCustomId("other:abc:allow") == nil)        // wrong prefix
        #expect(parseCustomId("perm::allow") == nil)            // empty reqKey
        #expect(parseCustomId("perm:abc:maybe") == nil)         // unknown action
    }
}

@Suite("resolveThreadPolicy")
struct ResolveThreadPolicyTests {
    @Test func claudePermModes() {
        #expect(resolveThreadPolicy(permMode: "acceptEdits") == .init(approvalPolicy: "never", sandbox: "workspace-write"))
        #expect(resolveThreadPolicy(permMode: "bypassPermissions") == .init(approvalPolicy: "never", sandbox: "danger-full-access"))
        #expect(resolveThreadPolicy(permMode: "plan") == .init(approvalPolicy: "on-request", sandbox: "read-only"))
        #expect(resolveThreadPolicy(permMode: "default") == .init(approvalPolicy: "on-request", sandbox: "workspace-write"))
        #expect(resolveThreadPolicy(permMode: "somethingUnknown") == .init(approvalPolicy: "on-request", sandbox: "workspace-write"))
    }

    @Test func codexSandboxModes() {
        #expect(resolveThreadPolicy(permMode: "read-only") == .init(approvalPolicy: "on-request", sandbox: "read-only"))
        #expect(resolveThreadPolicy(permMode: "workspace-write") == .init(approvalPolicy: "on-request", sandbox: "workspace-write"))
        #expect(resolveThreadPolicy(permMode: "danger-full-access") == .init(approvalPolicy: "never", sandbox: "danger-full-access"))
    }

    @Test func autoApprove() {
        #expect(isAutoApprovePolicy(resolveThreadPolicy(permMode: "bypassPermissions")) == true)
        #expect(isAutoApprovePolicy(resolveThreadPolicy(permMode: "plan")) == false)
    }
}

/// Minimal sidecar: emits ready, records `session.permission` params, answers ok.
private actor PermRecorderSidecar {
    private let transport: InMemorySidecarTransport
    let captured = LockedBox<[String: String]>([:])

    init(transport: InMemorySidecarTransport) { self.transport = transport }

    func run() async {
        if let line = try? serializeEnvelope(notify(method: "sidecar.ready", params: ["v": .number(1)])) {
            try? await transport.writeLine(line + "\n")
        }
        do { for try await line in transport.lines { await handle(line) } } catch {}
    }

    private func handle(_ line: String) async {
        guard let env = try? parseEnvelope(line), env.type == .req, let id = env.id, let method = env.method else { return }
        if method == "session.permission" {
            captured.withLock {
                $0["session"] = env.params?["session"]?.stringValue ?? ""
                $0["requestId"] = env.params?["requestId"]?.stringValue ?? ""
                $0["behavior"] = env.params?["behavior"]?.stringValue ?? ""
                if let m = env.params?["message"]?.stringValue { $0["message"] = m }
            }
        }
        if let out = try? serializeEnvelope(res(id: id, method: method, result: .object(["ok": .bool(true)]), session: env.session)) {
            try? await transport.writeLine(out + "\n")
        }
    }
}

@Suite("ClaudeSidecarClient.sessionPermission")
struct SessionPermissionTests {
    @Test func sendsCorrectParams() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let fake = PermRecorderSidecar(transport: pair.sidecar)
        let fakeTask = Task { await fake.run() }
        let client = ClaudeSidecarClient(transport: pair.host, requestTimeoutMs: 5_000)
        try await client.connect()

        try await client.sessionPermission(session: "sess-1", requestId: "req-9", behavior: "allow", message: "ok by owner")

        let got = fake.captured.withLock { $0 }
        #expect(got["session"] == "sess-1")
        #expect(got["requestId"] == "req-9")
        #expect(got["behavior"] == "allow")
        #expect(got["message"] == "ok by owner")

        await client.close()
        await pair.sidecar.close()
        fakeTask.cancel()
    }
}
