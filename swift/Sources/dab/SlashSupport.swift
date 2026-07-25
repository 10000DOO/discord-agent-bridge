import DiscordAgentBridge
import DiscordBM

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

/// All commands registered at ready (`/agent`, `/mode`, `/model`, `/effort`, `/stop`, `/clear`, `/stop-all`).
func allCommandPayloads() -> [Payloads.ApplicationCommandCreate] {
    allSlashCommandSpecs().map(applicationCommandPayload)
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

