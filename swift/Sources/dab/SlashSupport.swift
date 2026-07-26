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
    if !spec.subcommands.isEmpty {
        let subs: [ApplicationCommand.Option] = spec.subcommands.map { sub in
            ApplicationCommand.Option(
                type: .subCommand,
                name: sub.name,
                description: sub.description,
                options: sub.options.map(stringOption)
            )
        }
        return Payloads.ApplicationCommandCreate(
            name: spec.name,
            description: spec.description,
            options: subs,
            default_member_permissions: adminPerms
        )
    }
    if !spec.options.isEmpty {
        return Payloads.ApplicationCommandCreate(
            name: spec.name,
            description: spec.description,
            options: spec.options.map(stringOption),
            default_member_permissions: adminPerms
        )
    }
    return Payloads.ApplicationCommandCreate(
        name: spec.name,
        description: spec.description,
        options: nil,
        default_member_permissions: adminPerms
    )
}

private func stringOption(_ opt: SlashCommandSpec.Option) -> ApplicationCommand.Option {
    ApplicationCommand.Option(
        type: .string,
        name: opt.name,
        description: opt.description,
        required: opt.required,
        // Empty → nil: a free-text option must omit `choices` (Discord rejects []).
        choices: opt.choices.isEmpty ? nil : opt.choices.map { .init(name: $0.name, value: .string($0.value)) }
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
        }
    )
}

/// Localized share outcome for `/doc` ephemeral reply (ko; mirrors TS i18n doc.* keys).
func formatDocShareReply(path: String, result: ShareResult) -> String {
    if result.ok {
        let p = result.path ?? path
        return "문서를 스레드에 공유했어요: `\(p)`"
    }
    guard let code = result.code else {
        return "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요."
    }
    switch code {
    case .notFound:
        return "파일을 찾을 수 없어요: `\(path)`"
    case .escape:
        return "경로를 공유할 수 없어요."
    case .tooLarge:
        let max = result.max ?? "?"
        return "파일이 너무 커요 (최대 \(max))."
    case .notMarkdown:
        return "마크다운(.md)만 공유할 수 있어요."
    case .notFile:
        return "파일이 아니에요(디렉터리/바이너리): `\(path)`"
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
            return { codexUsageUnavailable() }
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

