import Foundation

/// Backend-agnostic description of a slash command. The library owns the shape (testable); `dab`
/// translates it to `DiscordBM`'s `Payloads.ApplicationCommandCreate` (thin glue, no logic).
/// Supports subcommands **or** top-level string options (leaf commands like `/model value:…`).
public struct SlashCommandSpec: Sendable, Equatable {
    public struct Choice: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }
    public struct Option: Sendable, Equatable {
        public var name: String
        public var description: String
        public var required: Bool
        public var choices: [Choice]
        /// When true, Discord asks the bot for suggestions (G-P1-03). Mutually exclusive with non-empty `choices`.
        public var autocomplete: Bool
        public init(
            name: String,
            description: String,
            required: Bool,
            choices: [Choice],
            autocomplete: Bool = false
        ) {
            self.name = name
            self.description = description
            self.required = required
            self.choices = choices
            self.autocomplete = autocomplete
        }
    }
    public struct Subcommand: Sendable, Equatable {
        public var name: String
        public var description: String
        public var options: [Option]
        public init(name: String, description: String, options: [Option]) {
            self.name = name; self.description = description; self.options = options
        }
    }
    public var name: String
    public var description: String
    /// Top-level options when the command has no subcommands (e.g. `/model`, `/effort`).
    public var options: [Option]
    public var subcommands: [Subcommand]
    /// When true, register with Discord `default_member_permissions = Administrator`
    /// (TS `/setup` / `/config` gate — hides the command from non-admins in the client UI).
    public var requiresAdministrator: Bool
    public init(
        name: String,
        description: String,
        options: [Option] = [],
        subcommands: [Subcommand] = [],
        requiresAdministrator: Bool = false
    ) {
        self.name = name
        self.description = description
        self.options = options
        self.subcommands = subcommands
        self.requiresAdministrator = requiresAdministrator
    }
}

/// `/agent start|close|resume|stats`.
public func agentCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "agent",
        description: "Manage this channel's agent session",
        subcommands: [
            // W11-b2 slice1: wizard-only start (backend→model→effort→perm selects). No free-text options.
            .init(
                name: "start",
                description: "Start and bind an agent session in this channel (wizard)",
                options: []
            ),
            // W14: close is a real stop (backend + unbind), not unbind-only.
            .init(name: "close", description: "Stop and unbind this channel's session", options: []),
            // G-P1-05: re-bind + status intro + soft ensure (lazy turn still works if soft fails).
            .init(name: "resume", description: "Re-bind stored session, post status, soft-reconnect", options: []),
            .init(name: "stats", description: "List active session bindings", options: []),
        ]
    )
}

/// `/mode backend` + `/mode perm` (TS parity; drive tier).
public func modeCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "mode",
        description: "Switch the backend or permission mode",
        subcommands: [
            .init(
                name: "backend",
                description: "Switch the agent backend (starts a fresh context)",
                options: [
                    .init(
                        name: "backend",
                        description: "Backend to switch to",
                        required: true,
                        choices: Backend.allCases.map {
                            // custom: dynamic model name when resolvable (TS buildSlashCommands).
                            let name = $0 == .custom ? customBackendLabel() : $0.rawValue
                            return .init(name: name, value: $0.rawValue)
                        }
                    ),
                ]
            ),
            .init(
                name: "perm",
                description: "Switch the permission mode (session kept)",
                options: [
                    .init(name: "value", description: "Permission mode", required: true, choices: []),
                ]
            ),
        ]
    )
}

/// `/model value:<id>` — update binding model (next turn / next ensure uses it).
/// `value` is autocomplete-driven (provider catalog for the channel backend; G-P1-03).
public func modelCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "model",
        description: "Switch the model for this session",
        options: [
            .init(
                name: "value",
                description: "Model to switch to",
                required: true,
                choices: [],
                autocomplete: true
            ),
        ]
    )
}

/// `/effort value:<level>` — update binding effort.
/// `value` is autocomplete-driven (runtime effort for channel backend/model; G-P1-03).
public func effortCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "effort",
        description: "Switch the reasoning effort for this session",
        options: [
            .init(
                name: "value",
                description: "Reasoning effort to switch to",
                required: true,
                choices: [],
                autocomplete: true
            ),
        ]
    )
}

/// Top-level `/stop` — hard-stop the current channel (drive tier; TS ACTION_TIER.stop).
public func stopCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(name: "stop", description: "Stop this channel's agent session")
}

/// `/clear` — drop live sessions, keep config, wipe backendSessionId (PLAN §14.6).
public func clearCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "clear",
        description: "Clear conversation context (fresh session, same folder/settings)"
    )
}

/// Top-level `/stop-all` — hard-stop every bound session (admin tier; TS ACTION_TIER['stop-all']).
public func stopAllCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(name: "stop-all", description: "Stop all agent sessions")
}

/// `/setup` — A4D guild channel structure (admin; TS `setDefaultMemberPermissions(Administrator)`).
public func setupCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "setup",
        description: "Create the agent control channel and sessions category (unnecessary if the channels already exist)",
        requiresAdministrator: true
    )
}

/// `/doc path:` — share a markdown file into a document thread (drive tier; TS `/doc`).
/// Free-text path (no autocomplete — avoids per-keystroke FS listing cost).
public func docCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "doc",
        description: "Share a markdown document into a thread",
        options: [
            .init(
                name: "path",
                description: "Path to the markdown file (absolute, or relative to the session folder)",
                required: true,
                choices: []
            ),
        ]
    )
}

/// `/config` — role tiers + defaults panel (admin; TS `setDefaultMemberPermissions(Administrator)`).
public func configCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "config",
        description: "Configure role tiers and defaults for this server",
        requiresAdministrator: true
    )
}

/// `/update` — check registry for a newer stable version (admin; W16-h).
public func updateCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "update",
        description: "Check for a new discord-agent-bridge version",
        requiresAdministrator: true
    )
}

/// Every slash command the bot registers (W11-d + lifecycle + W16-c/d/b/h /setup /doc /config /update).
public func allSlashCommandSpecs() -> [SlashCommandSpec] {
    [
        agentCommandSpec(),
        modeCommandSpec(),
        modelCommandSpec(),
        effortCommandSpec(),
        stopCommandSpec(),
        clearCommandSpec(),
        stopAllCommandSpec(),
        setupCommandSpec(),
        docCommandSpec(),
        configCommandSpec(),
        updateCommandSpec(),
    ]
}

/// Runs `clear` once per guild the bot currently belongs to, so guild-scoped commands left by a
/// predecessor that registered per-guild (e.g. a decommissioned client) don't linger alongside the
/// global set (OK-2 leftover). Global-registration boots only — dev boots (`DAB_DEV_GUILD_ID` set)
/// register on purpose to exactly one guild and must be skipped entirely, so that guild is never swept.
public func sweepStaleGuildCommands(
    knownGuildIds: [String],
    devGuildId: String?,
    clear: (String) async -> Void
) async {
    guard devGuildId == nil else { return }
    for guildId in knownGuildIds {
        await clear(guildId)
    }
}
