import Testing
import Foundation
import DiscordBM
@testable import DiscordAgentBridge
@testable import dab

// RV follow-up (docs/claude-turn-timeout-delay.md 10장, WO-5 RV 지적사항 수정):
//   1. `deliverTurnPush` swallowed a failed answer send entirely (no notice, completion still ✅).
//   2. `finalizeTurnCompletion` dropped the tool-count that used to show as "완료 · 🛠️ N".
// Both are exercised here against a fake `DiscordClient` — every call records what it was asked
// to send and then throws, since every real call site in this pipeline is either the one path
// under test (`deliverAnswer`'s propagated throw) or already best-effort (`try?`), so a
// successful HTTP response is never actually needed to observe behavior.

private enum FakeSendError: Error { case simulated }

private final class RecordingDiscordClient: DiscordClient, @unchecked Sendable {
    let appId: ApplicationSnowflake? = nil
    private let contentsBox = LockedBox<[String?]>([])
    private let embedTitlesBox = LockedBox<[String?]>([])
    private let reactionsBox = LockedBox<[String]>([])

    var sentContents: [String?] { contentsBox.withLock { $0 } }
    var sentEmbedTitles: [String?] { embedTitlesBox.withLock { $0 } }
    var addedReactions: [String] { reactionsBox.withLock { $0 } }

    func send(request: DiscordHTTPRequest) async throws -> DiscordHTTPResponse {
        if case .api(.addMessageReaction(_, _, let emojiName)) = request.endpoint {
            reactionsBox.withLock { $0.append(emojiName) }
        }
        throw FakeSendError.simulated
    }

    func send<E: Sendable & Encodable & ValidatablePayload>(
        request: DiscordHTTPRequest,
        payload: E
    ) async throws -> DiscordHTTPResponse {
        throw FakeSendError.simulated
    }

    func sendMultipart<E: Sendable & MultipartEncodable & ValidatablePayload>(
        request: DiscordHTTPRequest,
        payload: E
    ) async throws -> DiscordHTTPResponse {
        if let create = payload as? Payloads.CreateMessage {
            contentsBox.withLock { $0.append(create.content) }
            embedTitlesBox.withLock { $0.append(create.embeds?.first?.title) }
        } else if let edit = payload as? Payloads.EditMessage {
            contentsBox.withLock { $0.append(edit.content) }
            embedTitlesBox.withLock { $0.append(edit.embeds?.first?.title) }
        }
        throw FakeSendError.simulated
    }
}

@Suite("TurnDelivery")
struct TurnDeliveryTests {
    private func makeCtx(client: RecordingDiscordClient, announceExtras: Bool = false) -> TurnDeliveryContext {
        TurnDeliveryContext(
            client: client, channelId: ChannelSnowflake("1"), guildId: "g1", backend: .claude,
            caps: .allEnabled, actorId: "u1", roleTier: "execute", permMode: nil,
            announceExtras: announceExtras
        )
    }

    @Test("failed answer send returns false and posts a best-effort failure notice")
    func failedSendReturnsFalseAndPostsNotice() async {
        let client = RecordingDiscordClient()
        let ctx = makeCtx(client: client)
        let ok = await deliverTurnPush(TurnResult(text: "hello"), ctx: ctx)

        #expect(ok == false)
        let contents = client.sentContents
        #expect(contents.contains("hello")) // the failed answer attempt itself
        #expect(contents.contains { $0?.contains("⚠️") == true }) // best-effort failure notice
    }

    @Test("finalizeTurnCompletion(ok: false) reacts ❌, not ✅")
    func finalizeMarksFailureReaction() async {
        let client = RecordingDiscordClient()
        await finalizeTurnCompletion(
            client: client, channelId: ChannelSnowflake("1"), messageId: MessageSnowflake("9"),
            controlMsgId: nil, guildId: "g1", ok: false
        )
        #expect(client.addedReactions == [TurnReactions.error])
    }

    @Test("finalizeTurnCompletion(ok: true) reacts ✅")
    func finalizeMarksSuccessReaction() async {
        let client = RecordingDiscordClient()
        await finalizeTurnCompletion(
            client: client, channelId: ChannelSnowflake("1"), messageId: MessageSnowflake("9"),
            controlMsgId: nil, guildId: "g1", ok: true
        )
        #expect(client.addedReactions == [TurnReactions.done])
    }

    @Test("finalizeTurnCompletion forwards toolCount into the completion embed title")
    func finalizeForwardsToolCount() async {
        let client = RecordingDiscordClient()
        await finalizeTurnCompletion(
            client: client, channelId: ChannelSnowflake("1"), messageId: nil,
            controlMsgId: MessageSnowflake("2"), guildId: "g1", ok: true, toolCount: 3
        )
        #expect(client.sentEmbedTitles.contains { $0?.contains("🛠️ 3") == true })
    }

    @Test("finalizeTurnCompletion with no tools omits the tool-count suffix (default unchanged)")
    func finalizeOmitsToolCountWhenZero() async {
        let client = RecordingDiscordClient()
        await finalizeTurnCompletion(
            client: client, channelId: ChannelSnowflake("1"), messageId: nil,
            controlMsgId: MessageSnowflake("2"), guildId: "g1", ok: true
        )
        #expect(client.sentEmbedTitles.contains { $0?.contains("🛠️") == false })
    }
}
