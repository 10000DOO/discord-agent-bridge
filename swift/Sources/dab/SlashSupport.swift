import DiscordAgentBridge
import DiscordBM
import Foundation
import NIOCore

/// Translate the library's backend-agnostic `SlashCommandSpec` into DiscordBM's registration
/// payload. Thin glue (no logic) — the shape/choices are decided and tested in the library.
/// - Empty `subcommands` + empty `options` → leaf command (e.g. `/stop`, `/clear`).
/// - Empty `subcommands` + non-empty `options` → top-level string options (`/model`, `/effort`).
/// - Non-empty `subcommands` → subcommand group (`/agent`, `/mode`).
func applicationCommandPayload(_ spec: SlashCommandSpec) -> Payloads.ApplicationCommandCreate {
    let adminPerms: [Permission]? = spec.requiresAdministrator ? [.administrator] : nil
    // Only the top-level name is prefixed (`/dab-agent start`) — see dabCommandPrefix.
    let name = dabCommandName(spec.name)
    if !spec.subcommands.isEmpty {
        let subs: [ApplicationCommand.Option] = spec.subcommands.map { sub in
            ApplicationCommand.Option(
                type: .subCommand,
                name: sub.name,
                name_localizations: [.korean: sub.name, .englishUS: sub.name],
                description: sub.description.en,
                description_localizations: localizations(sub.description),
                options: sub.options.map(stringOption)
            )
        }
        return Payloads.ApplicationCommandCreate(
            name: name,
            name_localizations: [.korean: name, .englishUS: name],
            description: spec.description.en,
            description_localizations: localizations(spec.description),
            options: subs,
            default_member_permissions: adminPerms,
            dm_permission: false
        )
    }
    if !spec.options.isEmpty {
        return Payloads.ApplicationCommandCreate(
            name: name,
            name_localizations: [.korean: name, .englishUS: name],
            description: spec.description.en,
            description_localizations: localizations(spec.description),
            options: spec.options.map(stringOption),
            default_member_permissions: adminPerms,
            dm_permission: false
        )
    }
    return Payloads.ApplicationCommandCreate(
        name: name,
            name_localizations: [.korean: name, .englishUS: name],
            description: spec.description.en,
            description_localizations: localizations(spec.description),
            options: nil,
            default_member_permissions: adminPerms,
            dm_permission: false
    )
}

/// DiscordBM 1.16.2 validate() bug: description_localizations values are checked against the
/// 32-char name limit instead of the real 100-char description limit (Payloads.swift:1073,1123).
/// Drop only the locale values that would actually trip that bug; keep the rest so the ko/en
/// dual-description feature still works for the (majority of) descriptions under 32 chars.
private func localizations(_ t: LocalizedText) -> [DiscordLocale: String]? {
    var out: [DiscordLocale: String] = [:]
    if t.ko.unicodeScalars.count <= 32 { out[.korean] = t.ko }
    if t.en.unicodeScalars.count <= 32 { out[.englishUS] = t.en }
    return out.isEmpty ? nil : out
}

/// M17: human-readable choice labels for known backend ids (TS `BACKEND_LABELS`,
/// src/discord/client.ts:90) — `SlashCommandSpec`'s `backend` choices otherwise expose the raw
/// enum id ("claude"/"codex"/"grok") as the Discord-visible name. `custom` is deliberately
/// absent: its label is already the dynamically-resolved provider name the library computes
/// (`customBackendLabel()`), not a fixed string, and must not be overridden here.
private let backendChoiceLabels: [String: String] = [
    "claude": "Claude Code",
    "codex": "Codex",
    "grok": "Grok",
]

private func stringOption(_ opt: SlashCommandSpec.Option) -> ApplicationCommand.Option {
    // Discord: autocomplete and static choices are mutually exclusive; empty choices → omit.
    let staticChoices: [ApplicationCommand.Option.Choice]? =
        opt.autocomplete || opt.choices.isEmpty
        ? nil
        : opt.choices.map { choice in
            let name = opt.name == "backend" ? (backendChoiceLabels[choice.value] ?? choice.name) : choice.name
            return .init(name: name, value: .string(choice.value))
        }
    return ApplicationCommand.Option(
        type: .string,
        name: opt.name,
        name_localizations: [.korean: opt.name, .englishUS: opt.name],
        description: opt.description.en,
        description_localizations: localizations(opt.description),
        required: opt.required,
        choices: staticChoices,
        autocomplete: opt.autocomplete ? true : nil
    )
}

func agentCommandPayload() -> Payloads.ApplicationCommandCreate {
    applicationCommandPayload(agentCommandSpec())
}

/// All commands registered at ready (library `allSlashCommandSpecs`, including `/doc` / `/setup`).
func allCommandPayloads() -> [Payloads.ApplicationCommandCreate] {
    allSlashCommandSpecs().map(applicationCommandPayload)
}

// MARK: - Document share → DiscordBM (W16-d)

/// Post a markdown file into a `📄` thread on `channelId` (TS shareDocument + wiring.shareDocumentFor).
/// Resolves cwd from SessionStore (binding) and options from global documentShare config.
/// host.file.attach Discord sink: confine path under session cwd, read bytes, post as
/// channel attachment (TS `SessionWiring.sendFileFor` + `attachFileConfined` 1:1).
func postFileAttach(
    client: any DiscordClient,
    channelId: String,
    path: String,
    name: String? = nil,
    cwd: String? = nil
) async throws -> String {
    let resolvedCwd: String
    if let cwd {
        resolvedCwd = cwd
    } else if let session = await SessionStore.shared.binding(channelId: channelId), !session.archived {
        resolvedCwd = session.cwd
    } else if await SessionRegistry.shared.binding(channelId: channelId) != nil {
        resolvedCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
    } else {
        throw FileAttachHostError.noSession
    }

    let chId = channelId
    let result = await attachFileConfined(
        workspaceRoot: resolvedCwd,
        sendFile: { absPath, filename in
            let display = filename ?? (absPath as NSString).lastPathComponent
            let data = try Data(contentsOf: URL(fileURLWithPath: absPath))
            var buf = ByteBufferAllocator().buffer(capacity: data.count)
            buf.writeBytes(data)
            _ = try await client.createMessage(
                channelId: ChannelSnowflake(chId),
                payload: Payloads.CreateMessage(
                    files: [RawFile(data: buf, filename: display)],
                    attachments: [Payloads.Attachment(index: 0, filename: display)]
                )
            )
            return "Sent \(display) to the channel."
        },
        requestedPath: path,
        filename: name
    )
    if result.isError {
        throw FileAttachHostError.refused(result.text)
    }
    return result.text
}

func postDocumentShare(
    client: any DiscordClient,
    channelId: String,
    path: String,
    cwd: String? = nil,
    options: DocumentShareOptions? = nil
) async throws -> ShareResult {
    let resolvedCwd: String
    if let cwd {
        resolvedCwd = cwd
    } else if let session = await SessionStore.shared.binding(channelId: channelId), !session.archived {
        resolvedCwd = session.cwd
    } else if await SessionRegistry.shared.binding(channelId: channelId) != nil {
        // Registry-only (store not yet written) — fall back to DAB_CWD / home.
        resolvedCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
    } else {
        return .noSession
    }

    let opts: DocumentShareOptions
    if let options {
        opts = options
    } else {
        let section = try? await ConfigStore.shared.load().documentShare
        opts = DocumentShareOptions(section: section)
    }

    let chId = channelId
    let renderFn = await ImageRenderHost.shared.resolveRenderFn()
    return try await shareDocument(
        cwd: resolvedCwd,
        path: path,
        options: opts,
        channel: DocumentShareChannel { name in
            let resp = try await client.createThread(
                channelId: ChannelSnowflake(chId),
                payload: Payloads.CreateThreadWithoutMessage(name: name, type: .publicThread)
            )
            let thread = try resp.decode()
            let threadId = thread.id
            return DocumentShareThread { content, file in
                var files: [RawFile]?
                var attachments: [Payloads.Attachment]?
                if let file {
                    var buf = ByteBufferAllocator().buffer(capacity: file.data.count)
                    buf.writeBytes(file.data)
                    files = [RawFile(data: buf, filename: file.name)]
                    attachments = [Payloads.Attachment(index: 0, filename: file.name)]
                }
                _ = try await client.createMessage(
                    channelId: threadId,
                    payload: Payloads.CreateMessage(
                        content: content,
                        files: files,
                        attachments: attachments
                    )
                )
            }
        },
        renderImage: renderFn
    )
}

/// Localized share outcome for `/doc` ephemeral reply (TS i18n doc.* keys).
func formatDocShareReply(path: String, result: ShareResult) -> String {
    if result.ok {
        let p = result.path ?? path
        return I18n.t("doc.shared", ["path": p])
    }
    guard let code = result.code else {
        return I18n.t("router.noSession")
    }
    switch code {
    case .notFound:
        return I18n.t("doc.error.notFound", ["path": path])
    case .escape:
        return I18n.t("doc.error.escape")
    case .tooLarge:
        let max = result.max ?? "?"
        return I18n.t("doc.error.tooLarge", ["max": max])
    case .notMarkdown:
        return I18n.t("doc.error.notMarkdown")
    case .notFile:
        return I18n.t("doc.error.notFile", ["path": path])
    }
}

// MARK: - Usage embed → DiscordBM (W11-g slice2)

/// Map pure `UsageEmbedSpec` to DiscordBM `Embed`.
func discordEmbed(from spec: UsageEmbedSpec) -> Embed {
    Embed(
        title: spec.title,
        description: spec.description,
        color: DiscordColor(value: spec.color) ?? DiscordColor(value: DiscordColors.idle),
        footer: spec.footer.map { Embed.Footer(text: $0) },
        fields: spec.fields.map { Embed.Field(name: $0.name, value: $0.value, inline: $0.inline) }
    )
}

/// Map pure `StatusEmbedSpec` to DiscordBM `Embed` (W16-g).
func discordEmbed(from spec: StatusEmbedSpec) -> Embed {
    Embed(
        title: spec.title,
        color: DiscordColor(value: spec.color) ?? DiscordColor(value: DiscordColors.idle),
        footer: spec.footer.map { Embed.Footer(text: $0) },
        fields: spec.fields.map { Embed.Field(name: $0.name, value: $0.value, inline: $0.inline) }
    )
}

/// Map pure `RedmineIssueEmbedSpec` to DiscordBM `Embed` (WO-8).
func discordEmbed(from spec: RedmineIssueEmbedSpec) -> Embed {
    Embed(
        title: spec.title,
        description: spec.description,
        url: spec.url,
        color: DiscordColor(value: DiscordColors.idle),
        fields: spec.fields.map { Embed.Field(name: $0.name, value: $0.value, inline: $0.inline) }
    )
}

/// Best-effort pin of a channel message (W16-g residual). Missing Manage Messages / pin
/// permission or channel pin-cap failures are ignored — intro still stays in the channel.
func pinMessageBestEffort(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake
) async {
    _ = try? await client.pinMessage(channelId: channelId, messageId: messageId)
}

/// Post session status intro embed and pin it when possible (wizard bind / start).
@discardableResult
func postSessionStatusIntro(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    content: String,
    embed: Embed
) async -> MessageSnowflake? {
    do {
        let resp = try await client.createMessage(
            channelId: channelId,
            payload: .init(content: content, embeds: [embed])
        )
        let messageId = try resp.decode().id
        await pinMessageBestEffort(client: client, channelId: channelId, messageId: messageId)
        return messageId
    } catch {
        return nil
    }
}

/// Map pure `StreamEmbedSpec` to DiscordBM `Embed` (W11-g residual live stream status).
func discordEmbed(from spec: StreamEmbedSpec) -> Embed {
    Embed(
        title: spec.title,
        description: spec.description,
        color: DiscordColor(value: spec.color) ?? DiscordColor(value: DiscordColors.streaming),
        footer: spec.footer.map { Embed.Footer(text: $0) }
    )
}

// MARK: - Tool activity threads (W16-g)

/// DiscordBM-backed TurnThreadChannel for tool_use / tool_result work threads.
func turnThreadChannel(client: any DiscordClient, channelId: String) -> TurnThreadChannel {
    TurnThreadChannel { name in
        let resp = try await client.createThread(
            channelId: ChannelSnowflake(channelId),
            payload: Payloads.CreateThreadWithoutMessage(name: name, type: .publicThread)
        )
        let thread = try resp.decode()
        let threadId = thread.id
        return TurnThreadMessage(id: threadId.rawValue) { content in
            _ = try await client.createMessage(
                channelId: threadId,
                payload: Payloads.CreateMessage(content: content)
            )
        }
    }
}

/// Post a compact status-channel notification when server notifications are enabled (W16-g).
func postStatusNotification(
    client: any DiscordClient,
    guildId: String,
    sessionChannelId: String,
    event: AgentEvent,
    backend: Backend
) async {
    guard guildId != "dm", !guildId.isEmpty else { return }
    let server = await ConfigStore.shared.loadServerConfig(guildId: guildId)
    let resolved = resolveNotifications(server)
    guard resolved.enabled, let statusId = resolved.channelId, !statusId.isEmpty else { return }
    let sink = NotificationSink { content in
        _ = try await client.createMessage(
            channelId: ChannelSnowflake(statusId),
            payload: Payloads.CreateMessage(content: content)
        )
    }
    let getUsage: (@Sendable () async -> UsageResult?)? = {
        switch backend {
        case .claude, .custom:
            return { await ClaudeUsageService.shared.getUsage() }
        case .grok:
            return { await GrokUsageService.shared.getUsage() }
        case .codex:
            return { await CodexUsageService.shared.getUsage() }
        }
    }()
    let notifier = SessionNotifier(
        statusChannel: sink,
        sessionChannelId: sessionChannelId,
        events: resolved.events,
        getUsage: getUsage
    )
    await notifier.notify(event)
}

// MARK: - Wizard → DiscordBM components (W11-b2 slice1)

/// Map pure `WizardView` rows to Discord embeds + action rows (select menus + buttons).
func discordPayload(from view: WizardView) -> (embeds: [Embed], components: [Interaction.ActionRow]) {
    let embed = Embed(title: view.title, description: view.description)
    let rows: [Interaction.ActionRow] = view.rows.map { row in
        let comps: [Interaction.ActionRow.Component] = row.components.map { c in
            switch c {
            case .select(let customId, let placeholder, let options):
                let opts = options.map {
                    Interaction.ActionRow.StringSelectMenu.Option(
                        label: $0.label,
                        value: $0.value,
                        description: $0.description,
                        default: $0.isDefault
                    )
                }
                return .stringSelect(Interaction.ActionRow.StringSelectMenu(
                    custom_id: customId,
                    options: opts,
                    placeholder: placeholder
                ))
            case .button(let customId, let label, let style, let disabled):
                let s: Interaction.ActionRow.Button.NonLinkStyle = {
                    switch style {
                    case .primary: return .primary
                    case .secondary: return .secondary
                    case .success: return .success
                    case .danger: return .danger
                    }
                }()
                return .button(Interaction.ActionRow.Button(
                    style: s,
                    label: label,
                    custom_id: customId,
                    disabled: disabled ? true : nil
                ))
            }
        }
        return Interaction.ActionRow(components: comps)
    }
    return ([embed], rows)
}

// MARK: - Config panel → DiscordBM (W16-b)

/// Map pure `ConfigPanelView` rows to Discord embeds + action rows (role/string/channel selects + buttons).
func discordPayload(from view: ConfigPanelView) -> (
    embeds: [Embed],
    roleRows: [Interaction.ActionRow],
    defaultRows: [Interaction.ActionRow]
) {
    let embed = Embed(title: view.title, description: view.description)
    return (
        [embed],
        view.roleRows.map(configPanelActionRow),
        view.defaultRows.map(configPanelActionRow)
    )
}

/// Notifications (or other) sub-panel → embed + action rows.
func discordPayload(from sub: ConfigPanelSubView) -> (
    embeds: [Embed],
    rows: [Interaction.ActionRow]
) {
    (
        [Embed(title: sub.title, description: sub.description)],
        sub.rows.map(configPanelActionRow)
    )
}

private func configPanelActionRow(_ row: ConfigPanelRow) -> Interaction.ActionRow {
    let comps: [Interaction.ActionRow.Component] = row.components.map { c in
        switch c {
        case .roleSelect(let customId, let placeholder, let defaultRoleIds, let minValues, let maxValues):
            let defaults: [Interaction.ActionRow.DefaultValue]? = defaultRoleIds.isEmpty
                ? nil
                : defaultRoleIds.map { Interaction.ActionRow.DefaultValue(id: RoleSnowflake($0)) }
            return .roleSelect(Interaction.ActionRow.SelectMenu(
                custom_id: customId,
                placeholder: placeholder,
                default_values: defaults,
                min_values: minValues,
                max_values: maxValues
            ))
        case .userSelect(let customId, let placeholder, let defaultUserIds, let minValues, let maxValues):
            let defaults: [Interaction.ActionRow.DefaultValue]? = defaultUserIds.isEmpty
                ? nil
                : defaultUserIds.map { Interaction.ActionRow.DefaultValue(id: UserSnowflake($0)) }
            return .userSelect(Interaction.ActionRow.SelectMenu(
                custom_id: customId,
                placeholder: placeholder,
                default_values: defaults,
                min_values: minValues,
                max_values: maxValues
            ))
        case .channelSelect(let customId, let placeholder, let defaultChannelIds, let minValues, let maxValues):
            let defaults: [Interaction.ActionRow.DefaultValue]? = defaultChannelIds.isEmpty
                ? nil
                : defaultChannelIds.map { Interaction.ActionRow.DefaultValue(id: ChannelSnowflake($0)) }
            return .channelSelect(Interaction.ActionRow.ChannelSelectMenu(
                custom_id: customId,
                channel_types: [.guildText, .guildAnnouncement],
                placeholder: placeholder,
                default_values: defaults,
                min_values: minValues,
                max_values: maxValues
            ))
        case .select(let customId, let placeholder, let options):
            let opts = options.map {
                Interaction.ActionRow.StringSelectMenu.Option(
                    label: $0.label,
                    value: $0.value,
                    default: $0.isDefault
                )
            }
            return .stringSelect(Interaction.ActionRow.StringSelectMenu(
                custom_id: customId,
                options: opts,
                placeholder: placeholder
            ))
        case .button(let customId, let label, let style):
            let s: Interaction.ActionRow.Button.NonLinkStyle = {
                switch style {
                case .primary: return .primary
                case .secondary: return .secondary
                case .success: return .success
                case .danger: return .danger
                }
            }()
            return .button(Interaction.ActionRow.Button(
                style: s,
                label: label,
                custom_id: customId
            ))
        }
    }
    return Interaction.ActionRow(components: comps)
}
