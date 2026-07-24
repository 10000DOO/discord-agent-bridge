import DiscordAgentBridge
import Foundation

/// Sibling of `DabSessionBridge` for the minimal `!codex` path (W10-c1). Same shape:
/// per-channel session, per-channel turn serialization, blocking runTurn that accumulates
/// text until the turn completes (or a timeout fallback), via a continuation.
///
/// Unlike Claude (one shared sidecar, many sessions), Codex uses **one `codex app-server`
/// child per channel** — matching TS `CodexAppSession` (one client per session,
/// src/modes/codex/appSession.ts:317) — so a client's notifications belong to that channel's
/// single thread and need no threadId routing.
actor CodexSessionBridge {
    static let shared = CodexSessionBridge()

    private struct Channel {
        let client: CodexAppServerClient
        let threadId: String
    }

    /// channelId (snowflake string) → codex client + thread
    private var channels: [String: Channel] = [:]
    /// channelId → in-flight turn accumulator
    private var turns: [String: TurnBox] = [:]
    /// Serialize turns per channel (avoid concurrent turn/start on the same thread).
    private var channelGates: [String: Task<String, Error>] = [:]

    private struct TurnBox {
        var text = ""
        var done = false
        var continuation: CheckedContinuation<String, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    // env rules copied from DabSessionBridge (B/"sibling bridge": no forced sharing).
    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    private var turnTimeoutNs: UInt64 {
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 120
        return UInt64(max(5, sec)) * 1_000_000_000
    }

    /// Send user text for a Discord channel; wait for accumulated text + completion (or timeout).
    /// Turns on the same channel are serialized.
    func runTurn(channelId: String, text: String) async throws -> String {
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
        let timeoutNs = turnTimeoutNs
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.finishTurn(channelId: channelId, error: nil, timeoutFallback: true)
            }
            turns[channelId] = TurnBox(
                text: "",
                done: false,
                continuation: cont,
                timeoutTask: timeoutTask
            )

            Task {
                do {
                    _ = try await channel.client.turnStart(
                        params: .object([
                            "threadId": .string(channel.threadId),
                            "input": .array([.object([
                                "type": .string("text"),
                                "text": .string(text),
                            ])]),
                        ])
                    )
                } catch {
                    self.finishTurn(channelId: channelId, error: error)
                }
            }
        }
    }

    private func ensureChannel(channelId: String) async throws -> Channel {
        // Reuse a live client; a closed one (crashed/EOF) is dropped and respawned
        // (mirrors TS appSession.ts:296 `if (this.client && !this.client.isClosed) return`).
        if let existing = channels[channelId] {
            if !existing.client.isClosed {
                return existing
            }
            await existing.client.close()
            channels[channelId] = nil
        }
        // ponytail: channel당 codex 자식 프로세스가 상주하고 정리 경로가 없음(무한 증가 ceiling).
        // 최소 경로엔 /stop·세션 수명이 없어 닫을 자연 지점이 없다. W11에서 세션 수명 배선 시
        // close() + channels 제거로 업그레이드. 최소 경로에선 채널 수 소량 가정.
        let spawn = resolveCodexSpawn()
        print("dab: spawning codex app-server: \(spawn.command) \(spawn.args.joined(separator: " "))")
        // approval auto-accept: no onApproval handler → CodexAppServerClient answers `.accept`.
        let client = try CodexAppServerClient(spawn: spawn, requestTimeoutMs: 120_000)

        let threadId: String
        do {
            _ = try await client.initialize()
            // ponytail: hardcoded danger policy = Claude default `bypassPermissions` equivalent
            // (policy.ts:32-33 maps bypassPermissions → never / danger-full-access). No permission
            // UI in the minimal path — TEMPORARY until W11 wires Allow/Deny + /mode. DANGEROUS on
            // real machines: the agent runs shell commands and edits files with no sandbox and no
            // approval prompt. Gate behind a per-channel policy once W11 lands.
            threadId = try await client.threadStart(
                params: .object([
                    "cwd": .string(cwd),
                    "approvalPolicy": .string("never"),
                    "sandbox": .string("danger-full-access"),
                ])
            )
        } catch {
            // Init failed: close the spawned child so it does not leak as an orphan.
            await client.close()
            throw error
        }

        client.onNotification { [weak self] method, params in
            Task { await self?.onNotification(channelId: channelId, method: method, params: params) }
        }
        let channel = Channel(client: client, threadId: threadId)
        channels[channelId] = channel
        print("dab: codex thread channel=\(channelId) thread=\(threadId)")
        return channel
    }

    private func onNotification(channelId: String, method: String, params: JSONValue?) {
        guard var box = turns[channelId], !box.done else { return }
        switch codexTurnStep(method: method, params: params) {
        case .appendText(let delta):
            box.text += delta
            turns[channelId] = box
        case .fullText(let text):
            // Only when no deltas streamed (avoids duplicating the streamed message).
            if box.text.isEmpty {
                box.text = text
                turns[channelId] = box
            }
        case .finished:
            finishTurnUnlocked(channelId: channelId, result: box.text.isEmpty ? "(empty result)" : box.text)
        case .failed(let message):
            finishTurnUnlocked(channelId: channelId, result: nil, error: AppServerError(message))
        case .ignore:
            break
        }
    }

    private func finishTurn(channelId: String, error: Error?, timeoutFallback: Bool = false) {
        guard let box = turns[channelId], !box.done else { return }
        if let error {
            finishTurnUnlocked(channelId: channelId, result: nil, error: error)
            return
        }
        if timeoutFallback {
            if box.text.isEmpty {
                finishTurnUnlocked(
                    channelId: channelId,
                    result: nil,
                    error: AppServerError("codex turn timeout (no text)")
                )
            } else {
                finishTurnUnlocked(channelId: channelId, result: box.text + "\n…(timeout)")
            }
        }
    }

    private func finishTurnUnlocked(channelId: String, result: String?, error: Error? = nil) {
        guard var box = turns[channelId], !box.done else { return }
        box.done = true
        box.timeoutTask?.cancel()
        let cont = box.continuation
        box.continuation = nil
        box.timeoutTask = nil
        turns[channelId] = box
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? box.text)
        }
    }
}
