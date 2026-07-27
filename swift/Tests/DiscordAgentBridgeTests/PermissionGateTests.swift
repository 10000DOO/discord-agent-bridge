import Testing
import Foundation
@testable import DiscordAgentBridge

/// Spin (no sleep) until the awaiting Task has registered its continuation on the gate.
private func waitRegistered(_ gate: PermissionGate) async {
    while await gate.pendingCount() == 0 { await Task.yield() }
}

@Suite("PermissionGate")
struct PermissionGateTests {
    @Test func resolveAllowAndDeny() async {
        for expected in [PermissionDecision.allow, .deny] {
            let gate = PermissionGate()
            let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner")) }
            await waitRegistered(gate)
            #expect(await gate.resolve(reqKey: "k", action: expected, byUserId: "owner") == true)
            #expect(await t.value == expected)
        }
    }

    // W16-e: Always-Allow settles the waiter with `.always` (backend maps via backendBehavior → allow).
    @Test func resolveAlwaysReturnsAlwaysDecision() async {
        let gate = PermissionGate()
        let t = Task {
            await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "Bash", approverId: "owner"))
        }
        await waitRegistered(gate)
        #expect(await gate.peekToolName("k") == "Bash")
        #expect(await gate.resolve(reqKey: "k", action: .always, byUserId: "owner") == true)
        let decision = await t.value
        #expect(decision == .always)
        #expect(decision.isAllowing == true)
        #expect(decision.backendBehavior == "allow")
        #expect(decision.isAlways == true)
        #expect(await gate.peekToolName("k") == nil)   // cleared after settle
    }

    @Test func peekToolNameWhilePending() async {
        let gate = PermissionGate()
        let t = Task {
            await gate.await(prompt: .init(reqKey: "r1", channelId: "c", toolName: "WebFetch", approverId: "owner"))
        }
        await waitRegistered(gate)
        #expect(await gate.peekToolName("r1") == "WebFetch")
        #expect(await gate.peekToolName("missing") == nil)
        #expect(await gate.resolve(reqKey: "r1", action: .allow, byUserId: "owner") == true)
        _ = await t.value
    }

    // H3 (TS parity): no timeout — an unanswered ask stays pending indefinitely instead of
    // auto-denying. Verified by staying pending well past what used to be the timeout window.
    @Test func unansweredAskStaysPendingIndefinitely() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner")) }
        await waitRegistered(gate)
        try? await Task.sleep(nanoseconds: 200_000_000)   // past the old 200ms timeout window
        #expect(await gate.pendingCount() == 1)            // still pending — never auto-denied
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "owner") == true)
        #expect(await t.value == .allow)
    }

    @Test func approverMismatchIgnored() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner")) }
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
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash", approverId: "owner")) }
        await waitRegistered(gate)
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "owner") == true)
        _ = await t.value
        #expect(await gate.resolve(reqKey: "k", action: .deny, byUserId: "owner") == false)   // already settled
    }

    // H6 (TS parity, permissionButtons.ts:133): a prompt with NO approver can be resolved by
    // anyone — the approver check only applies when `approverId` is actually set.
    @Test func nilApproverCanBeResolvedByAnyone() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash")) }
        await waitRegistered(gate)
        #expect(await gate.resolve(reqKey: "k", action: .allow, byUserId: "anyone") == true)
        #expect(await t.value == .allow)
    }

    // Same as above but with byUserId omitted entirely — still resolves when there's no approver.
    @Test func nilApproverResolvesEvenWithoutByUserId() async {
        let gate = PermissionGate()
        let t = Task { await gate.await(prompt: .init(reqKey: "k", channelId: "c", toolName: "bash")) }
        await waitRegistered(gate)
        #expect(await gate.resolve(reqKey: "k", action: .deny) == true)   // byUserId nil
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
        // W16-e Always-Allow custom_id
        #expect(buildCustomId(reqKey: "abc", action: .always) == "perm:abc:always")
        #expect(parseCustomId("perm:abc:always")?.action == .always)
        #expect(parseCustomId("perm:abc:always")?.reqKey == "abc")
    }

    @Test func rejectsGarbage() {
        #expect(parseCustomId("perm:abc") == nil)               // 2 tokens
        #expect(parseCustomId("perm:abc:allow:extra") == nil)   // 4 tokens
        #expect(parseCustomId("other:abc:allow") == nil)        // wrong prefix
        #expect(parseCustomId("perm::allow") == nil)            // empty reqKey
        #expect(parseCustomId("perm:abc:maybe") == nil)         // unknown action
    }

    @Test func backendBehaviorMapping() {
        #expect(PermissionDecision.allow.backendBehavior == "allow")
        #expect(PermissionDecision.always.backendBehavior == "allow")
        #expect(PermissionDecision.deny.backendBehavior == "deny")
        #expect(PermissionDecision.allow.isAllowing)
        #expect(PermissionDecision.always.isAllowing)
        #expect(!PermissionDecision.deny.isAllowing)
    }
}

// H1: `permissionDetail` (DabSessionBridge.swift, private) is `DiscordText.truncate(formatToolInput(input), 3000)`.
// Exercised here directly against its public building blocks (formatToolInput lives in
// Render/ToolFormat.swift and is shared with the tool-thread opening message).
@Suite("permission detail format (H1)")
struct PermissionDetailFormatTests {
    @Test func stringInputPassesThrough() {
        let out = DiscordText.truncate(formatToolInput(.string("ls -la")), 3000)
        #expect(out == "ls -la")
    }

    @Test func objectInputBecomesFencedJson() {
        let out = formatToolInput(.object(["command": .string("ls")]))
        #expect(out == "```json\n{\n  \"command\" : \"ls\"\n}\n```")
    }

    @Test func arrayInputBecomesFencedJson() {
        let out = formatToolInput(.array([.string("a"), .number(1)]))
        #expect(out.hasPrefix("```json\n["))
        #expect(out.hasSuffix("]\n```"))
    }

    @Test func over3000CharsIsTruncated() {
        let huge = String(repeating: "x", count: 4000)
        let out = DiscordText.truncate(formatToolInput(.object(["path": .string(huge)])), 3000)
        #expect(out.utf16.count == 3000)
        #expect(out.hasSuffix("…"))
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
