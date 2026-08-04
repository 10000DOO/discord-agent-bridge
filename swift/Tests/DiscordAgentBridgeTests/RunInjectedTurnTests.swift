import Testing
import Foundation
import DiscordBM
@testable import DiscordAgentBridge
@testable import dab

// WO-3 (design_orchestration_module_agents.md): `runInjectedTurn` is the pipeline extracted out of
// `runRedmineKickoffPrompt`. `postPrompt: false` is new behavior (Redmine's own call always passes
// `true`), so it needs its own coverage — `RedmineKickoffPromptTests`/`TurnDeliveryTests` are left
// untouched on purpose (WO-3 completion condition: they must still pass unmodified).
//
// This drives the REAL pipeline (not a hand-rolled substitute) through `DabSessionBridge.shared`,
// since that singleton isn't test-injectable from `runInjectedTurn`'s fixed signature. To keep this
// safe on a dev machine that may have real Claude credentials wired up, `DAB_CLAUDE_SIDECAR_CMD` is
// pointed at a nonexistent binary for the duration of the test — the real sidecar spawn then fails
// synchronously (ENOENT) instead of ever touching a real process or network call. `DAB_HOME` is
// likewise redirected to a throwaway temp dir, since the failed turn still writes to
// `AuditLog`/`ConfigStore` (both resolve their real file path off `DAB_HOME` under
// ~/.discord-agent-bridge otherwise). `.serialized` guards against this env mutation racing any
// other test that might one day also exercise `.shared`.

private final class RecordingClient: DiscordClient, @unchecked Sendable {
    let appId: ApplicationSnowflake? = nil
    private let contentsBox = LockedBox<[String?]>([])
    var sentContents: [String?] { contentsBox.withLock { $0 } }

    func send(request: DiscordHTTPRequest) async throws -> DiscordHTTPResponse {
        throw CancellationError()
    }

    func send<E: Sendable & Encodable & ValidatablePayload>(
        request: DiscordHTTPRequest,
        payload: E
    ) async throws -> DiscordHTTPResponse {
        throw CancellationError()
    }

    func sendMultipart<E: Sendable & MultipartEncodable & ValidatablePayload>(
        request: DiscordHTTPRequest,
        payload: E
    ) async throws -> DiscordHTTPResponse {
        if let create = payload as? Payloads.CreateMessage {
            contentsBox.withLock { $0.append(create.content) }
        }
        throw CancellationError()
    }
}

@Suite("runInjectedTurn", .serialized)
struct RunInjectedTurnTests {
    @Test func postPromptFalseNeverPostsThePromptTextButStillRunsTheTurn() async {
        // `AuditLog.shared`/`ConfigStore.shared` are `static let` — whichever env is in effect on
        // this process's FIRST touch of either sticks for the process lifetime. If some other test
        // reaches `.shared` before this one, DAB_HOME here does nothing and the real
        // ~/.discord-agent-bridge/audit/audit.jsonl gets written to regardless of this override.
        let tmpHome = FileManager.default.temporaryDirectory.appendingPathComponent("dab-test-home-\(UUID().uuidString)").path
        setenv("DAB_CLAUDE_SIDECAR_CMD", "/nonexistent-dab-test-sidecar-xyz", 1)
        setenv("DAB_HOME", tmpHome, 1)
        defer { unsetenv("DAB_CLAUDE_SIDECAR_CMD"); unsetenv("DAB_HOME") }

        let client = RecordingClient()
        let marker = "UNIQUE_PROMPT_MARKER_\(UUID().uuidString)"
        let posted = await runInjectedTurn(
            client: client,
            channelId: "test-channel-\(UUID().uuidString)",
            guildId: "g1",
            backend: .claude,
            promptText: marker,
            postPrompt: false,
            announceExtras: false,
            actorId: "u1",
            roleTier: "execute"
        )

        // postPrompt: false has nothing to confirm — always reports delivered.
        #expect(posted)
        // Negative: postPrompt: false never posts the prompt body itself.
        #expect(!client.sentContents.contains(marker))
        // Positive: the turn was actually attempted, not just skipped — the forced spawn failure
        // surfaces through runInjectedTurn's catch block as a posted "⚠️ ..." notice. The turn
        // itself now runs in a detached task behind the returned confirmation (only the prompt
        // post is awaited), so poll for it instead of asserting immediately.
        await waitUntil { client.sentContents.contains { $0?.hasPrefix("⚠️") == true } }
        #expect(client.sentContents.contains { $0?.hasPrefix("⚠️") == true })
    }
}
