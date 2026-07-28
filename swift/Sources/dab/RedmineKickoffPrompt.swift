import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "redmine-kickoff")

/// R3/R4 common entry point (WO-7): fires once, whether the caller just finished the
/// `/agent start` wizard for a brand-new channel or confirmed an existing session pick —
/// either way the channel is already bound by the time this runs.
///
/// Kickoff prompt text (3-3 D8) — explicitly a "light skim" request, not a deep-analysis one.
/// Sends only the issue number + link, not the full description (2026-07-28 user directive) —
/// a session with the Redmine MCP tool can look the issue up itself; otherwise the link suffices.
func redmineKickoffPromptText(issue: RedmineIssueDTO) -> String {
    "#\(issue.id) \(issue.url) 내용을 가볍게 파악해줘. 깊은 분석은 필요 없고, 무슨 이슈인지 정도만 파악하면 돼."
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

    do {
        let turn: TurnResult
        switch backend {
        case .claude, .custom:
            turn = try await DabSessionBridge.shared.runTurn(
                channelId: channelId,
                guildId: guildId,
                ownerId: actorId,
                text: text,
                config: sessionConfig ?? SessionConfig(backend: backend),
                files: []
            )
        case .codex:
            turn = try await CodexSessionBridge.shared.runTurn(
                channelId: channelId,
                ownerId: actorId,
                guildId: guildId,
                text: text,
                config: sessionConfig,
                files: []
            )
        case .grok:
            turn = try await GrokSessionBridge.shared.runTurn(
                channelId: channelId,
                ownerId: actorId,
                guildId: guildId,
                text: text,
                config: sessionConfig,
                files: []
            )
        }
        await IdleWatchdog.shared.stop(channelId: channelId)
        if let promptMessageId {
            await completeTurnReaction(
                client: client,
                channelId: chId,
                messageId: promptMessageId,
                terminal: TurnReactions.done
            )
        }
        await StreamStatusHost.shared.end(channelId: channelId)
        let toolCount = turn.tools.reduce(0) { $0 + $1.count }
        await finalizeInterruptControlMessage(
            client: client, channelId: chId, messageId: controlMsgId,
            guildId: guildId, toolCount: toolCount
        )
        let body = turn.text.isEmpty ? "(no text)" : turn.text
        let renderFn = await ImageRenderHost.shared.resolveRenderFn()
        try await deliverAnswer(
            body,
            options: DeliverOptions(
                renderImage: renderFn,
                emit: { out in
                    try await emitDeliverPayload(client: client, channelId: chId, payload: out)
                }
            )
        )
        if let usage = turn.usage, let line = buildResultLine(usage) {
            _ = await createMessageWithRetry(
                client: client,
                channelId: chId,
                payload: .init(content: line),
                onGone: {
                    await SessionLifecycle.shared.stopChannel(
                        channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                    )
                }
            )
        }
        await AuditLog.shared.record(AuditEntry(
            actorId: actorId, roleTier: roleTier, guildId: guildId, channelId: channelId,
            action: "turn", mode: backend.rawValue, status: "ok"
        ))
    } catch {
        await IdleWatchdog.shared.stop(channelId: channelId)
        if let promptMessageId {
            await completeTurnReaction(
                client: client,
                channelId: chId,
                messageId: promptMessageId,
                terminal: TurnReactions.error
            )
        }
        await StreamStatusHost.shared.end(channelId: channelId)
        await finalizeInterruptControlMessage(
            client: client, channelId: chId, messageId: controlMsgId, guildId: guildId
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
                    content: "다시 시작할까요?",
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
