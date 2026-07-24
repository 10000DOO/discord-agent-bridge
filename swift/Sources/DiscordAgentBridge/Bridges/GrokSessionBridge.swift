import Foundation

/// Sibling of `CodexSessionBridge` for the minimal `!grok` path (W10-c3). One `grok agent stdio`
/// child per channel; per-channel turn serialization.
///
/// Unlike Codex (turn completes on a `turn/completed` notification, so the bridge waits on a
/// continuation), Grok completes a turn when `sessionPrompt` RETURNS (it blocks on the
/// session/prompt response). Text arrives on `onNotification` meanwhile; the read loop dispatches
/// those handlers synchronously BEFORE it resumes the prompt response (AcpClient.swift:280-291,
/// 337-340, 386-391, 343-352), so a synchronous fold into a lock buffer is complete at return —
/// no continuation / TurnBox / timeout task needed here (the client's requestTimeoutMs owns the
/// turn budget). Do NOT hop onto the actor from the handler (a Task would run after the return).
public actor GrokSessionBridge {
    public static let shared = GrokSessionBridge()

    /// Client factory (test seam). Default = real spawn with the turn budget as requestTimeoutMs,
    /// so sessionPrompt is bounded by DAB_TURN_TIMEOUT_SEC. Injected via `@testable` in tests.
    private let makeClient: @Sendable () throws -> GrokAcpClient

    init(makeClient: @escaping @Sendable () throws -> GrokAcpClient = {
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
        // danger/parity: `--always-approve` (bypassPermissions) makes grok never send a permission
        // ask — parity with the !claude/!codex danger default. No permission UI yet (TEMPORARY, W11);
        // DANGEROUS on real machines (tools run unapproved).
        let spawn = resolveGrokSpawn(bypassPermissions: true)
        print("dab: spawning grok agent stdio: \(spawn.command) \(spawn.args.joined(separator: " "))")
        return try GrokAcpClient(spawn: spawn, requestTimeoutMs: max(5, sec) * 1000)
    }) {
        self.makeClient = makeClient
    }

    private struct Channel {
        let client: GrokAcpClient
    }

    /// channelId (snowflake string) → grok client (holds its own sessionId)
    private var channels: [String: Channel] = [:]
    /// Serialize turns per channel (avoid concurrent sessionPrompt on the same session).
    private var channelGates: [String: Task<String, Error>] = [:]

    // env rules copied from CodexSessionBridge (B/"sibling bridge": no forced sharing).
    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    /// Send user text for a Discord channel; wait for the prompt turn + accumulated text.
    /// Turns on the same channel are serialized.
    public func runTurn(channelId: String, text: String, config: SessionConfig? = nil) async throws -> String {
        // config seam (W11-a): model/effort/permMode not consumed yet — wizard wiring is W11-b.
        _ = config
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session (buffer/session cross-talk). The previous turn is
        // awaited INSIDE the task — that is where serialization happens.
        let prev = channelGates[channelId]
        let task = Task { () -> String in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(channelId: channelId, text: text)
        }
        channelGates[channelId] = task
        defer { if channelGates[channelId] == task { channelGates[channelId] = nil } }
        return try await task.value
    }

    private func executeTurn(channelId: String, text: String) async throws -> String {
        let channel = try await ensureChannel(channelId: channelId)

        // Synchronous fold: the read loop runs this handler before resuming sessionPrompt, so the
        // buffer is complete when the await returns (see type comment). No actor hop / Task here.
        let buf = LockedBox("")
        let unsub = channel.client.onNotification { method, params in
            if case .appendText(let delta) = grokUpdateStep(method: method, params: params) {
                buf.withLock { $0 += delta }
            }
        }
        defer { unsub() }

        _ = try await channel.client.sessionPrompt(prompt: text)
        let out = buf.withLock { $0 }
        return out.isEmpty ? "(no text)" : out
    }

    private func ensureChannel(channelId: String) async throws -> Channel {
        // Reuse a live client; a closed one (crashed/EOF) is dropped and respawned
        // (mirrors CodexSessionBridge.ensureChannel).
        if let existing = channels[channelId] {
            if !existing.client.isClosed {
                return existing
            }
            await existing.client.close()
            channels[channelId] = nil
        }
        // ponytail: channel당 grok 자식 프로세스가 상주하고 정리 경로가 없음(무한 증가 ceiling).
        // 최소 경로엔 /stop·세션 수명이 없어 닫을 자연 지점이 없다. W11에서 세션 수명 배선 시
        // close() + channels 제거로 업그레이드. 최소 경로에선 채널 수 소량 가정.
        let client = try makeClient()

        do {
            _ = try await client.initialize()
            _ = try await client.sessionNew(cwd: cwd)
        } catch {
            // Init failed: close the spawned child so it does not leak as an orphan.
            await client.close()
            throw error
        }

        let channel = Channel(client: client)
        channels[channelId] = channel
        print("dab: grok session channel=\(channelId) sid=\(client.sessionId ?? "?")")
        return channel
    }
}
