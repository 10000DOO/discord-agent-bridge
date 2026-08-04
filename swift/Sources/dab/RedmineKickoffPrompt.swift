import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "injected-turn")

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

/// Runs a bot-authored prompt through one full turn and delivers the reply — the shared pipeline
/// behind every programmatic turn drive. Bots are ignored by `handleMessageCreate`
/// (docs/redmine-session-confirm-kickoff.md), so this is the only way to make a channel's session
/// advance without a human typing. Extracted from `runRedmineKickoffPrompt` (WO-3,
/// design_orchestration_module_agents.md) so the orchestration module-agent flow (WO-5) can reuse
/// the exact same UX pipeline instead of hand-copying it again.
///
/// Mirrors the essential `runAndReply` progress UX (⏳/✅/❌, interrupt control, StreamStatusHost,
/// IdleWatchdog) so a bot-authored prompt still looks "alive".
///
/// Callers should fire-and-forget this when they need the interaction ack to return immediately.
///
/// Returns whether the prompt was durably posted (or `true` when `postPrompt` is false — nothing
/// to confirm). `OrchestrationHost.order`/`.report` await only up to this point before answering
/// their own caller: the message post is bounded (a few retried Discord calls), but the turn
/// itself is not, so it stays fire-and-forget below this line — same reason `order()` never
/// blocks its caller on a module's turn. Before this, `order`/`report` fired the whole function
/// as an untracked `Task` and answered "delivered" immediately, so a post that failed (or a
/// process restart before this ran at all) was never seen by anyone.
@discardableResult
func runInjectedTurn(
    client: any DiscordClient,
    channelId: String,
    guildId: String,
    backend: Backend,
    promptText: String,
    postPrompt: Bool,
    announceExtras: Bool,
    actorId: String,
    roleTier: String
) async -> Bool {
    let chId = ChannelSnowflake(channelId)
    // Discord's own client wraps long messages at 2000 chars, but this auto-post path bypasses
    // that, so chunk here — the full `promptText` still goes to the backend turn below unsplit.
    var promptMessageId: MessageSnowflake?
    if postPrompt {
        for chunk in DiscordText.chunkMessage(promptText) {
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
            log.error("injected turn prompt post failed channel=\(channelId)")
            return false
        }
    }

    if let promptMessageId {
        await addTurnReaction(
            client: client,
            channelId: chId,
            messageId: promptMessageId,
            emoji: TurnReactions.working
        )
    }

    // The prompt is durably posted (or there was none to post) — answer the caller truthfully
    // now. Everything below is the actual turn (unbounded LLM think time) and stays
    // fire-and-forget in its own detached task.
    Task {
        await runInjectedTurnBody(
            client: client, channelId: channelId, guildId: guildId, backend: backend,
            promptText: promptText, announceExtras: announceExtras, actorId: actorId,
            roleTier: roleTier, promptMessageId: promptMessageId
        )
    }
    return true
}

private func runInjectedTurnBody(
    client: any DiscordClient,
    channelId: String,
    guildId: String,
    backend: Backend,
    promptText: String,
    announceExtras: Bool,
    actorId: String,
    roleTier: String,
    promptMessageId: MessageSnowflake?
) async {
    let chId = ChannelSnowflake(channelId)
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
    // `announceExtras` lets callers keep their UX exactly as before (Redmine kickoff always passes
    // `false`: no mention/rate-limit line/usage panel/status-channel notifications).
    let pushCtx = TurnDeliveryContext(
        client: client, channelId: chId, guildId: guildId, backend: backend,
        caps: caps, actorId: actorId, roleTier: roleTier, permMode: sessionConfig?.permMode,
        announceExtras: announceExtras
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
                text: promptText,
                config: sessionConfig ?? SessionConfig(backend: backend),
                files: [],
                onAnswer: onAnswer
            )
        case .codex:
            let turn = try await CodexSessionBridge.shared.runTurn(
                channelId: channelId,
                ownerId: actorId,
                guildId: guildId,
                text: promptText,
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
                text: promptText,
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
        log.error("injected turn failed channel=\(channelId) err=\(error)")
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

/// Posts the kickoff prompt as a plain channel message, runs one turn on `backend`, and delivers
/// the reply. Thin wrapper around `runInjectedTurn` (WO-3) — keeps Redmine's issue-specific prompt
/// text generation separate from the shared turn-drive pipeline. `announceExtras: false` keeps
/// this path's intentionally trimmed UX (no mention/rate-limit line/usage panel/status-channel
/// notifications) exactly as before.
func runRedmineKickoffPrompt(
    client: any DiscordClient,
    channelId: String,
    guildId: String,
    backend: Backend,
    issue: RedmineIssueDTO,
    actorId: String,
    roleTier: String
) async {
    await runInjectedTurn(
        client: client,
        channelId: channelId,
        guildId: guildId,
        backend: backend,
        promptText: redmineKickoffPromptText(issue: issue),
        postPrompt: true,
        announceExtras: false,
        actorId: actorId,
        roleTier: roleTier
    )
}
