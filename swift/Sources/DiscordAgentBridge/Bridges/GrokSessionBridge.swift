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

    /// Client factory (test seam). Grok's model/effort AND bypass are SPAWN-time flags, so the factory
    /// takes the channel's SessionConfig to build the spawn (TS parity: no live setModel/setEffort).
    /// The permission handler is also construction-time, so it is passed too. `@testable` in tests.
    private let makeClient: @Sendable (SessionConfig?, _ onPermission: AcpPermissionHandler?) throws -> GrokAcpClient
    /// Permission gate (default shared; tests inject a fresh gate for isolation).
    private let gate: PermissionGate

    init(
        makeClient: @escaping @Sendable (SessionConfig?, _ onPermission: AcpPermissionHandler?) throws -> GrokAcpClient = { config, onPermission in
            let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
            // W11-c: bypass (`--always-approve`) only when the permMode is an auto-approve one; else
            // grok emits permission asks answered via the Discord gate (onPermission). model/effort
            // from the bound config. No permMode bound → bypass (danger default parity).
            let bypass = grokBypassPermMode(config?.permMode)
            let spawn = resolveGrokSpawn(model: config?.model, effort: config?.effort, bypassPermissions: bypass)
            print("dab: spawning grok agent stdio: \(spawn.command) \(spawn.args.joined(separator: " "))")
            return try GrokAcpClient(spawn: spawn, requestTimeoutMs: max(5, sec) * 1000, onPermission: onPermission)
        },
        gate: PermissionGate = .shared
    ) {
        self.makeClient = makeClient
        self.gate = gate
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

    // ponytail: permission-button deadline < the turn budget (client requestTimeoutMs) so an
    // unanswered ask denies before the sessionPrompt request itself times out.
    private var permGateTimeoutNs: UInt64 {
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
        return UInt64(max(5, sec)) * 1_000_000_000 / 2
    }

    /// Send user text for a Discord channel; wait for the prompt turn + accumulated text.
    /// Turns on the same channel are serialized.
    public func runTurn(channelId: String, ownerId: String? = nil, text: String, config: SessionConfig? = nil) async throws -> String {
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session (buffer/session cross-talk). The previous turn is
        // awaited INSIDE the task — that is where serialization happens.
        let prev = channelGates[channelId]
        let task = Task { () -> String in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(channelId: channelId, ownerId: ownerId, text: text, config: config)
        }
        channelGates[channelId] = task
        defer { if channelGates[channelId] == task { channelGates[channelId] = nil } }
        return try await task.value
    }

    private func executeTurn(channelId: String, ownerId: String?, text: String, config: SessionConfig?) async throws -> String {
        let channel = try await ensureChannel(channelId: channelId, config: config, ownerId: ownerId)

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

    private func ensureChannel(channelId: String, config: SessionConfig?, ownerId: String?) async throws -> Channel {
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
        // W11에서 세션 수명 배선 시 close() + channels 제거로 업그레이드.
        // ponytail: model/effort/bypass are baked at spawn from the FIRST turn's config (TS parity —
        // Grok has no live setModel/setEffort). A later /perm change would need a respawn (W11-c+).

        // W11-c: bypass permMode → `--always-approve` (no handler). Non-bypass → route grok's
        // permission asks through the Discord gate (onPermission), deny-by-default on timeout.
        let gateTimeout = permGateTimeoutNs
        let gate = self.gate
        let onPermission: AcpPermissionHandler?
        if grokBypassPermMode(config?.permMode) {
            onPermission = nil   // `--always-approve`: grok never asks
        } else {
            onPermission = { req in
                let decision = await gate.await(
                    prompt: PermissionPrompt(
                        reqKey: UUID().uuidString,
                        channelId: channelId,
                        toolName: req.toolName ?? "tool",
                        approverId: ownerId
                    ),
                    timeoutNs: gateTimeout
                )
                return decision == .allow ? .allow : .deny   // deny-by-default via gate timeout
            }
        }
        let client = try makeClient(config, onPermission)

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

/// Whether a permMode auto-approves for Grok (→ `--always-approve`, no permission UI). No bound
/// permMode → true (danger default parity). Non-bypass modes route asks through the gate.
func grokBypassPermMode(_ permMode: String?) -> Bool {
    guard let permMode, !permMode.isEmpty else { return true }
    return permMode == "bypassPermissions" || permMode == "danger-full-access"
}
