import DiscordAgentBridge
import DiscordBM

/// Translate the library's backend-agnostic `SlashCommandSpec` into DiscordBM's registration
/// payload. Thin glue (no logic) — the shape/choices are decided and tested in the library.
/// - Empty `subcommands` + empty `options` → leaf command (e.g. `/stop`, `/clear`).
/// - Empty `subcommands` + non-empty `options` → top-level string options (`/model`, `/effort`).
/// - Non-empty `subcommands` → subcommand group (`/agent`, `/mode`).
func applicationCommandPayload(_ spec: SlashCommandSpec) -> Payloads.ApplicationCommandCreate {
    if !spec.subcommands.isEmpty {
        let subs: [ApplicationCommand.Option] = spec.subcommands.map { sub in
            ApplicationCommand.Option(
                type: .subCommand,
                name: sub.name,
                description: sub.description,
                options: sub.options.map(stringOption)
            )
        }
        return Payloads.ApplicationCommandCreate(name: spec.name, description: spec.description, options: subs)
    }
    if !spec.options.isEmpty {
        return Payloads.ApplicationCommandCreate(
            name: spec.name,
            description: spec.description,
            options: spec.options.map(stringOption)
        )
    }
    return Payloads.ApplicationCommandCreate(name: spec.name, description: spec.description, options: nil)
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
