import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "turn-delivery")

// WO-5 (docs/claude-turn-timeout-delay.md): shared turn post-processing, used by
// DabMain.handleMessageCreate (Claude's `onAnswer` push callback + Codex/Grok's single-shot
// return) and RedmineKickoffPrompt.runRedmineKickoffPrompt (dedup — that file used to carry its
// own smaller copy of the same pipeline). Two functions, matching the "no judgment about when a
// turn is really over" redesign:
//   - `deliverTurnPush`: everything that fires on every `.result` — no gating.
//   - `finalizeTurnCompletion`: the one-shot completion decoration (emoji/stream/stop
//     button/IdleWatchdog), fired once right after the FIRST terminal event (result or error) —
//     i.e. right after `runTurn` returns or throws, TS `armCompletionIndicator` parity.

/// Everything `deliverTurnPush`/`finalizeTurnCompletion` need beyond the push payload itself.
struct TurnDeliveryContext: Sendable {
    var client: any DiscordClient
    var channelId: ChannelSnowflake
    var guildId: String
    var backend: Backend
    var caps: Capabilities
    var actorId: String
    var roleTier: String
    var permMode: String?
    /// RedmineKickoffPrompt's trimmed-down UX intentionally never had mention / rate-limit line /
    /// usage panel / status-channel notifications (docs/claude-turn-timeout-delay.md WO-5 — "기존에
    /// 없던 기능을 새로 추가하지 말 것"). `false` there keeps that exact shape; DabMain's normal turn
    /// path leaves this on.
    var announceExtras: Bool = true

    init(
        client: any DiscordClient, channelId: ChannelSnowflake, guildId: String, backend: Backend,
        caps: Capabilities, actorId: String, roleTier: String, permMode: String?, announceExtras: Bool = true
    ) {
        self.client = client
        self.channelId = channelId
        self.guildId = guildId
        self.backend = backend
        self.caps = caps
        self.actorId = actorId
        self.roleTier = roleTier
        self.permMode = permMode
        self.announceExtras = announceExtras
    }
}

/// Prefer persisted session ownerId; fall back to the message author (drive path).
func resolveOwnerId(channelId: String, messageAuthorId: String) async -> String {
    if let o = await SessionStore.shared.binding(channelId: channelId)?.ownerId, !o.isEmpty {
        return o
    }
    return messageAuthorId
}

/// "매 push마다" (WO-5 6장): answer text, cost/token footer, rate-limit line, completion mention,
/// usage panel, status-channel result/rate-limit notifications, audit log. No gating — fires once
/// per `.result` for Claude (via `onAnswer`), or once for Codex/Grok's single return.
///
/// Returns `false` when the actual answer send (`deliverAnswer`) failed — the caller uses this to
/// mark the turn's completion reaction ❌ instead of ✅ even though the AI itself succeeded,
/// because the user never actually received anything. A failed send does not abort the rest of
/// this push (footer/mention/etc. still attempt independently) nor future pushes on this turn.
@discardableResult
func deliverTurnPush(_ turn: TurnResult, ctx: TurnDeliveryContext) async -> Bool {
    // 답변 전송 (always — this is the one item Redmine's trimmed UX also keeps).
    let body = turn.text.isEmpty ? "(no text)" : turn.text
    let renderFn = await ImageRenderHost.shared.resolveRenderFn()
    var delivered = true
    do {
        try await deliverAnswer(
            body,
            options: DeliverOptions(
                renderImage: renderFn,
                emit: { out in try await emitDeliverPayload(client: ctx.client, channelId: ctx.channelId, payload: out) }
            )
        )
    } catch {
        log.error("deliverAnswer failed channel=\(ctx.channelId.rawValue) error=\(error)")
        // Best-effort notice — if the channel is this broken, the notice may fail too; ignore.
        _ = try? await ctx.client.createMessage(
            channelId: ctx.channelId,
            payload: .init(content: I18n.t("turn.deliveryFailed"))
        )
        delivered = false
    }
    // 비용/토큰/시간 푸터 (always — Redmine kept this one too).
    if let usage = turn.usage, let line = buildResultLine(usage) {
        _ = await createMessageWithRetry(
            client: ctx.client, channelId: ctx.channelId, payload: .init(content: line),
            onGone: {
                await SessionLifecycle.shared.stopChannel(
                    channelId: ctx.channelId.rawValue, actorId: "system", guildId: ctx.guildId, roleTier: "execute"
                )
            }
        )
    }
    await AuditLog.shared.record(AuditEntry(
        actorId: ctx.actorId, roleTier: ctx.roleTier, guildId: ctx.guildId, channelId: ctx.channelId.rawValue,
        action: "turn", mode: ctx.backend.rawValue, permMode: ctx.permMode, status: "ok"
    ))
    // Safety net (not gated by announceExtras — this must fire regardless): a module (agent-role)
    // channel's turn just ended. If it never called `report()`, forward this answer for it instead
    // of leaving the lead with nothing (prompt/role-doc guidance alone isn't 100% reliable).
    await OrchestrationHost.shared.autoReportIfMissing(channelId: ctx.channelId.rawValue, text: body)

    guard ctx.announceExtras else { return delivered }

    let (usageSnap, usageTitle) = await usageSnapshotAndTitle(backend: ctx.backend)
    // A rate update is part of this push's terminal snapshot. Post it before the completion
    // mention so the usage panel remains the last artifact in this push.
    if let rl = turn.rateLimit {
        await postRateLimitLine(
            client: ctx.client, channelId: ctx.channelId, guildId: ctx.guildId, rateLimit: rl, usage: usageSnap
        )
    }
    // mentionOnComplete is part of this push too: answer → footer → rate-limit → mention → usage.
    let ownerId = await resolveOwnerId(channelId: ctx.channelId.rawValue, messageAuthorId: ctx.actorId)
    if let mention = mentionOnCompleteContent(ownerId: ownerId) {
        _ = await createMessageWithRetry(
            client: ctx.client, channelId: ctx.channelId, payload: .init(content: mention),
            onGone: {
                await SessionLifecycle.shared.stopChannel(
                    channelId: ctx.channelId.rawValue, actorId: "system", guildId: ctx.guildId, roleTier: "execute"
                )
            }
        )
    }
    if ctx.caps.usagePanel {
        let embedExtras = UsageEmbedExtras(
            meta: await resolveUsageSessionMeta(channelId: ctx.channelId.rawValue, fallbackPermMode: ctx.permMode),
            title: usageTitle,
            observedModelIsActual: ctx.backend == .claude || ctx.backend == .custom,
            tools: turn.tools,
            agents: turn.agents
        )
        await postUsageEmbedOrFallback(
            client: ctx.client, channelId: ctx.channelId, guildId: ctx.guildId,
            usage: usageSnap, ctxUsage: turn.contextUsage, extras: embedExtras
        )
    }
    // W16-g: status-channel notification (result + rate_limit when present).
    let resultEv = AgentEvent.result(
        text: turn.text, costUsd: turn.usage?.costUsd, tokensIn: turn.usage?.tokensIn,
        tokensOut: turn.usage?.tokensOut, durationMs: turn.usage?.durationMs
    )
    await postStatusNotification(
        client: ctx.client, guildId: ctx.guildId, sessionChannelId: ctx.channelId.rawValue, event: resultEv, backend: ctx.backend
    )
    if let rl = turn.rateLimit {
        let rlEv = AgentEvent.rateLimit(resetAt: rl.resetAt, rateLimitType: rl.rateLimitType, utilization: rl.utilization)
        await postStatusNotification(
            client: ctx.client, guildId: ctx.guildId, sessionChannelId: ctx.channelId.rawValue, event: rlEv, backend: ctx.backend
        )
    }
    return delivered
}

/// "첫 결과 이벤트 시점에 1회" (WO-5 6장): completion emoji, stream status end, stop button
/// finalize, IdleWatchdog.stop. Fires once, right after the FIRST terminal event (`.result` or
/// error) — i.e. right after `runTurn` returns (success) or throws (failure) — never gated on
/// "is this really the last result" (TS `armCompletionIndicator` parity).
/// `toolCount` restores the completion embed's "Finished · 🛠️ N" tool-count display (pre-WO-5
/// behavior); callers pass the most recent `TurnResult.tools` count seen across this turn's pushes.
func finalizeTurnCompletion(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake?,
    controlMsgId: MessageSnowflake?,
    guildId: String,
    ok: Bool,
    toolCount: Int = 0
) async {
    await IdleWatchdog.shared.stop(channelId: channelId.rawValue)
    if let messageId {
        await completeTurnReaction(
            client: client, channelId: channelId, messageId: messageId,
            terminal: ok ? TurnReactions.done : TurnReactions.error
        )
    }
    await StreamStatusHost.shared.end(channelId: channelId.rawValue)
    await finalizeInterruptControlMessage(
        client: client, channelId: channelId, messageId: controlMsgId, guildId: guildId, toolCount: toolCount
    )
}
