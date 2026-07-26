import DiscordAgentBridge
import DiscordBM
import Foundation

/// C14: `client.createMessage` wrapped in `sendWithRetry` — a transient failure is retried up
/// to 5 times (300/600/1200/2400ms backoff); a confirmed 10003 (Unknown Channel, same
/// classification as `channelConfirmedGone`) gives up immediately without spending any retry
/// budget. `onGone` lets a caller that has guildId handy hard-clean a stale binding
/// (`SessionLifecycle.stopChannel`); nil is fine — the live `channelDelete` gateway event and
/// the next boot's `resumeAll` (C10) already cover cleanup independently.
///
/// Only replaces the `try?` (silently-dropped) call sites — call sites that already surface a
/// thrown failure to their own caller (SlashSupport.swift's document/file-share posts) keep
/// their existing `try` + do/catch and are out of scope (retrying there would eat into the
/// ~3s Discord interaction-ack deadline those paths share, turning a transient hiccup into a
/// guaranteed interaction-token expiry — the same reason TS never retries a send either).
@discardableResult
func createMessageWithRetry(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    payload: Payloads.CreateMessage,
    onGone: (@Sendable () async -> Void)? = nil
) async -> DiscordClientResponse<DiscordChannel.Message>? {
    let outcome = await sendWithRetry {
        () -> SendAttemptResult<DiscordClientResponse<DiscordChannel.Message>> in
        guard let resp = try? await client.createMessage(channelId: channelId, payload: payload) else {
            return .transientFailure
        }
        switch resp.asError() {
        case .none:
            return .success(resp)
        case .jsonError(let jsonError) where jsonError.code == .unknownChannel:
            return .gone
        default:
            return .transientFailure
        }
    }
    switch outcome {
    case .sent(let response):
        return response
    case .gone:
        if let onGone { await onGone() }
        return nil
    case .unavailable:
        return nil
    }
}
