import DiscordAgentBridge
import DiscordBM
import Foundation

// Discord side of the pinned task panel (docs/task-panel-and-diff-view.md WO-4 · WO-5).
//
// One panel per channel, pinned once and edited forever after (D3-1): Discord posts a
// "pinned a message" system line on every pin and caps a channel at 50 pins, so re-pinning each
// update would both spam the channel and burn the cap.

private let taskPanelLog = Logger(name: "task-panel")

/// Channels already told that pinning is not permitted — the notice is worth one message, not one
/// per update (R9).
actor TaskPanelNoticeLedger {
    static let shared = TaskPanelNoticeLedger()
    private var notified: Set<String> = []

    /// True on the first call for a channel, false afterwards.
    func claim(channelId: String) -> Bool {
        notified.insert(channelId).inserted
    }

    /// Allow the notice again (used once pinning succeeds, so a later regression is reported).
    func clear(channelId: String) {
        notified.remove(channelId)
    }
}

func taskPanelEmbed(from spec: TaskPanelSpec) -> Embed {
    Embed(
        title: spec.title,
        description: spec.description,
        color: DiscordColor(value: spec.color) ?? DiscordColor(value: DiscordColors.streaming)
    )
}

/// Create-or-edit sink for TaskPanelHost. Creating also pins, once.
func makeTaskPanelSink(client: any DiscordClient) -> TaskPanelSink {
    { channelId, messageId, spec in
        let channel = ChannelSnowflake(channelId)
        let embed = taskPanelEmbed(from: spec)

        // Edit path: the panel already exists (pinned or demoted), so never pin again here.
        if let messageId {
            let resp = try? await client.updateMessage(
                channelId: channel,
                messageId: MessageSnowflake(messageId),
                payload: .init(embeds: [embed])
            )
            if resp?.asError() != nil {
                // Someone deleted the panel by hand: forget it so the next update recreates one.
                taskPanelLog.warn("task-panel: edit failed channel=\(channelId) — recreating next update")
                return nil
            }
            return messageId
        }

        guard let created = await createMessageWithRetry(
            client: client,
            channelId: channel,
            payload: .init(embeds: [embed])
        ), let message = try? created.decode() else {
            taskPanelLog.warn("task-panel: create failed channel=\(channelId)")
            return nil
        }
        let newId = message.id
        let pinned = await pinMessageBestEffort(client: client, channelId: channel, messageId: newId)
        if pinned {
            await TaskPanelNoticeLedger.shared.clear(channelId: channelId)
        } else {
            await postTaskPanelPinNotice(client: client, channelId: channelId)
        }
        return newId.rawValue
    }
}

/// Unpin + delete for TaskPanelHost.dispose (R5).
func makeTaskPanelRemover(client: any DiscordClient) -> TaskPanelRemover {
    { channelId, messageId in
        let channel = ChannelSnowflake(channelId)
        let message = MessageSnowflake(messageId)
        _ = try? await client.unpinMessage(channelId: channel, messageId: message)
        _ = try? await client.deleteMessage(channelId: channel, messageId: message)
    }
}

/// One-time notice with the two things that fix it: what to switch on, and a ready-made
/// re-authorization link. Discord blocks a bot from granting itself a permission it lacks, so this
/// is as automatic as it gets — one click.
private func postTaskPanelPinNotice(client: any DiscordClient, channelId: String) async {
    guard await TaskPanelNoticeLedger.shared.claim(channelId: channelId) else { return }
    let appId = await BotGatewayIdentity.shared.getApplicationId()
    var description = I18n.t("taskPanel.pin.denied")
    if let appId, !appId.isEmpty {
        description += "\n\n" + I18n.t("taskPanel.pin.reinvite", ["url": botReinviteURL(applicationId: appId)])
    }
    let embed = Embed(
        title: I18n.t("taskPanel.pin.deniedTitle"),
        description: description,
        color: DiscordColor(value: DiscordColors.permission)
    )
    let row: Interaction.ActionRow = [
        .button(.init(style: .secondary, label: I18n.t("taskPanel.pin.recheck"), custom_id: taskPanelRecheckCustomId))
    ]
    _ = await createMessageWithRetry(
        client: client,
        channelId: ChannelSnowflake(channelId),
        payload: .init(embeds: [embed], components: [row])
    )
}

// MARK: - Recheck button

let taskPanelRecheckCustomId = "taskpanel:recheck"

/// Retry the pin after the operator flipped the permission. Ephemeral either way — this is a
/// one-person confirmation, not channel news.
func handleTaskPanelRecheckComponent(client: any DiscordClient, payload: Interaction) async {
    let channelId = payload.channel_id?.rawValue ?? ""
    let messageId = await TaskPanelHost.shared.panelMessageId(channelId: channelId)
    let key: String
    if let messageId, !channelId.isEmpty {
        let pinned = await pinMessageBestEffort(
            client: client,
            channelId: ChannelSnowflake(channelId),
            messageId: MessageSnowflake(messageId)
        )
        if pinned {
            await TaskPanelNoticeLedger.shared.clear(channelId: channelId)
        }
        key = pinned ? "taskPanel.pin.recheckOk" : "taskPanel.pin.recheckStillDenied"
    } else {
        key = "taskPanel.pin.recheckNoPanel"
    }
    _ = try? await client.createInteractionResponse(
        id: payload.id,
        token: payload.token,
        payload: .channelMessageWithSource(.init(content: I18n.t(key), flags: [.ephemeral]))
    )
}

// MARK: - Boot adoption (D3-3)

/// Re-attach to a panel this channel already has pinned, so a restart edits the existing message
/// instead of pinning a second one. Newest match wins; nothing found → the next update creates one.
func adoptExistingTaskPanel(client: any DiscordClient, channelId: String) async {
    guard let resp = try? await client.listChannelPins(channelId: ChannelSnowflake(channelId)),
          let pins = try? resp.decode()
    else { return }
    let botUserId = await BotGatewayIdentity.shared.getUserId()
    for pin in pins.items {
        let message = pin.message
        guard message.author?.id.rawValue == botUserId else { continue }
        guard let description = message.embeds.first?.description, isTaskPanelDescription(description) else { continue }
        await TaskPanelHost.shared.adopt(channelId: channelId, messageId: message.id.rawValue)
        taskPanelLog.info("task-panel: adopted pinned panel channel=\(channelId) message=\(message.id.rawValue)")
        return
    }
}
