import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "redmine-kickoff")

/// R3/R4 common entry point (WO-7): fires once, whether the caller just finished the
/// `/agent start` wizard for a brand-new channel or confirmed an existing session pick —
/// either way the channel is already bound by the time this runs.
///
/// Kickoff prompt text (3-3 D8) — explicitly a "light skim" request, not a deep-analysis one.
/// Sends the issue number, title, and full description inline (2026-07-30 user directive,
/// reversing the prior 2026-07-28 link-only decision) so the session doesn't need to look the
/// issue up itself; the link is dropped since the content is already inline.
func redmineKickoffPromptText(issue: RedmineIssueDTO) -> String {
    I18n.t("redmine.kickoff.prompt", ["issueId": "\(issue.id)", "subject": issue.subject, "description": issue.description])
}

/// Posts the kickoff prompt as a plain channel message, runs one turn on `backend`, and delivers
/// the reply. Mirrors the essential `runAndReply` progress UX (⏳/✅/❌, interrupt control,
/// StreamStatusHost, IdleWatchdog) so a bot-authored prompt still looks "alive" — bots are
/// ignored by `handleMessageCreate`, so this path must drive the turn itself
/// (docs/redmine-session-confirm-kickoff.md).
///
/// Callers should fire-and-forget this when they need the interaction ack to return immediately.
func runRedmineKickoffPrompt(
    client: any DiscordClient,
    channelId: String,
    guildId: String,
    backend: Backend,
    issue: RedmineIssueDTO,
    actorId: String,
    roleTier: String
) async {
    let chId = ChannelSnowflake(channelId)
    let text = redmineKickoffPromptText(issue: issue)
    // Discord's own client wraps long messages at 2000 chars, but this auto-post path bypasses
    // that, so chunk here — the full `text` still goes to the backend turn below unsplit.
    var promptMessageId: MessageSnowflake?
    for chunk in DiscordText.chunkMessage(text) {
        let posted = await createMessageWithRetry(
            client: client,
            channelId: chId,
            payload: .init(content: chunk),
            onGone: {
                await SessionLifecycle.shared.stopChannel(
                    channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                )
            }
        )
        if let posted, let id = try? posted.decode().id {
            promptMessageId = id
        }
    }
    if promptMessageId == nil {
        log.error("redmine kickoff prompt post failed channel=\(channelId) issue=\(issue.id)")
    }

    if let promptMessageId {
        await addTurnReaction(
            client: client,
            channelId: chId,
            messageId: promptMessageId,
            emoji: TurnReactions.working
        )
    }

    let sessionConfig = await SessionRegistry.shared.binding(channelId: channelId)
    let caps = await resolveSessionCapabilities(backend: backend, guildId: guildId)
    await ToolActivityHost.shared.setCapabilities(channelId: channelId, caps)
    await ToolActivityHost.shared.setNotifyContext(channelId: channelId, guildId: guildId, backend: backend)
    let controlMsgId = await postInterruptControlMessage(
        client: client, channelId: chId, guildId: guildId
    )
    if caps.streaming, let controlMsgId {
        await StreamStatusHost.shared.begin(
            channelId: channelId,
            guildId: guildId,
            messageId: controlMsgId.rawValue
        )
    }
    await IdleWatchdog.shared.arm(channelId: channelId)

    // WO-5 (docs/claude-turn-timeout-delay.md): same push-based pipeline as DabMain, via the
    // shared TurnDelivery functions — dedups what used to be a smaller hand-copied pipeline here.
    // `announceExtras: false` keeps this path's intentionally trimmed UX (no mention/rate-limit
    // line/usage panel/status-channel notifications) exactly as before.
    let pushCtx = TurnDeliveryContext(
        client: client, channelId: chId, guildId: guildId, backend: backend,
        caps: caps, actorId: actorId, roleTier: roleTier, permMode: sessionConfig?.permMode,
        announceExtras: false
    )
    let pushChain = LockedBox<Task<Void, Never>?>(nil)
    // RV follow-up (docs/claude-turn-timeout-delay.md 10장): same failure/tool-count tracking as
    // DabMain.handleMessageCreate — kept in sync since this mirrors its push pipeline.
    let pushFailed = LockedBox<Bool>(false)
    let lastToolCount = LockedBox<Int>(0)
    let onAnswer: @Sendable (TurnResult) -> Void = { turn in
        lastToolCount.withLock { $0 = turn.tools.reduce(0) { $0 + $1.count } }
        pushChain.withLock { prev in
            let previous = prev
            prev = Task {
                _ = await previous?.value
                if await !deliverTurnPush(turn, ctx: pushCtx) {
                    pushFailed.withLock { $0 = true }
                }
            }
        }
    }

    do {
        switch backend {
        case .claude, .custom:
            try await DabSessionBridge.shared.runTurn(
                channelId: channelId,
                guildId: guildId,
                ownerId: actorId,
                text: text,
                config: sessionConfig ?? SessionConfig(backend: backend),
                files: [],
                onAnswer: onAnswer
            )
        case .codex:
            let turn = try await CodexSessionBridge.shared.runTurn(
                channelId: channelId,
                ownerId: actorId,
                guildId: guildId,
                text: text,
                config: sessionConfig,
                files: []
            )
            lastToolCount.withLock { $0 = turn.tools.reduce(0) { $0 + $1.count } }
            if await !deliverTurnPush(turn, ctx: pushCtx) { pushFailed.withLock { $0 = true } }
        case .grok:
            let turn = try await GrokSessionBridge.shared.runTurn(
                channelId: channelId,
                ownerId: actorId,
                guildId: guildId,
                text: text,
                config: sessionConfig,
                files: []
            )
            lastToolCount.withLock { $0 = turn.tools.reduce(0) { $0 + $1.count } }
            if await !deliverTurnPush(turn, ctx: pushCtx) { pushFailed.withLock { $0 = true } }
        }
        await pushChain.withLock { $0 }?.value
        await finalizeTurnCompletion(
            client: client, channelId: chId, messageId: promptMessageId,
            controlMsgId: controlMsgId, guildId: guildId, ok: !(pushFailed.withLock { $0 }),
            toolCount: lastToolCount.withLock { $0 }
        )
    } catch {
        await pushChain.withLock { $0 }?.value
        await finalizeTurnCompletion(
            client: client, channelId: chId, messageId: promptMessageId,
            controlMsgId: controlMsgId, guildId: guildId, ok: false,
            toolCount: lastToolCount.withLock { $0 }
        )
        log.error("redmine kickoff turn failed channel=\(channelId) err=\(error)")
        let msg = "⚠️ \(error.localizedDescription)"
        for chunk in DiscordText.chunkMessage(msg) {
            _ = await createMessageWithRetry(
                client: client,
                channelId: chId,
                payload: .init(content: chunk),
                onGone: {
                    await SessionLifecycle.shared.stopChannel(
                        channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                    )
                }
            )
        }
        // Same retry-prompt as runAndReply's catch block (DabMain.swift) — only for the exact
        // "turn timeout (no terminal result)" case, since the session binding is already
        // invalidated by then and only needs an announcement, not a resend.
        if let rpcErr = error as? SidecarRpcError, rpcErr.code == "internal", rpcErr.message == "turn timeout (no terminal result)" {
            _ = await createMessageWithRetry(
                client: client,
                channelId: chId,
                payload: .init(
                    content: I18n.t("turnTimeout.prompt"),
                    components: discordActionRows(from: [buildTurnTimeoutRetryRow()])
                )
            )
        }
        await AuditLog.shared.record(AuditEntry(
            actorId: actorId, roleTier: roleTier, guildId: guildId, channelId: channelId,
            action: "turn", mode: backend.rawValue, outcome: error.localizedDescription, status: "error"
        ))
    }
}
