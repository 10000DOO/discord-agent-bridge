import DiscordAgentBridge
import DiscordBM

/// Translate the library's backend-agnostic `SlashCommandSpec` into DiscordBM's registration
/// payload. Thin glue (no logic) — the shape/choices are decided and tested in the library.
/// Empty `subcommands` → a leaf command (e.g. `/stop`, `/stop-all`).
func applicationCommandPayload(_ spec: SlashCommandSpec) -> Payloads.ApplicationCommandCreate {
    if spec.subcommands.isEmpty {
        return Payloads.ApplicationCommandCreate(name: spec.name, description: spec.description, options: nil)
    }
    let subs: [ApplicationCommand.Option] = spec.subcommands.map { sub in
        ApplicationCommand.Option(
            type: .subCommand,
            name: sub.name,
            description: sub.description,
            options: sub.options.map { opt in
                ApplicationCommand.Option(
                    type: .string,
                    name: opt.name,
                    description: opt.description,
                    required: opt.required,
                    // Empty → nil: a free-text option must omit `choices` (Discord rejects []).
                    choices: opt.choices.isEmpty ? nil : opt.choices.map { .init(name: $0.name, value: .string($0.value)) }
                )
            }
        )
    }
    return Payloads.ApplicationCommandCreate(name: spec.name, description: spec.description, options: subs)
}

func agentCommandPayload() -> Payloads.ApplicationCommandCreate {
    applicationCommandPayload(agentCommandSpec())
}

/// All commands registered at ready (`/agent`, `/stop`, `/stop-all`).
func allCommandPayloads() -> [Payloads.ApplicationCommandCreate] {
    allSlashCommandSpecs().map(applicationCommandPayload)
}
