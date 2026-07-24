import Foundation

/// Backend-agnostic description of a slash command. The library owns the shape (testable); `dab`
/// translates it to `DiscordBM`'s `Payloads.ApplicationCommandCreate` (thin glue, no logic). Kept
/// to exactly what `/agent` needs — subcommands with string options + choices.
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
        public init(name: String, description: String, required: Bool, choices: [Choice]) {
            self.name = name; self.description = description; self.required = required; self.choices = choices
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
    public var subcommands: [Subcommand]
    public init(name: String, description: String, subcommands: [Subcommand]) {
        self.name = name; self.description = description; self.subcommands = subcommands
    }
}

/// `/agent start backend:<claude|codex|grok>` and `/agent close`. (resume/stats/mode/model/effort
/// are later slices.)
public func agentCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "agent",
        description: "Manage this channel's agent session",
        subcommands: [
            .init(
                name: "start",
                description: "Start and bind an agent session in this channel",
                options: [
                    .init(
                        name: "backend",
                        description: "Which agent backend to use",
                        required: true,
                        choices: Backend.allCases.map { .init(name: $0.rawValue, value: $0.rawValue) }
                    ),
                    // model: free text (backend-specific, catalogs are dynamic) — blank = backend default.
                    .init(name: "model", description: "Model id (blank = backend default)", required: false, choices: []),
                    // effort: common union across backends.
                    .init(
                        name: "effort",
                        description: "Reasoning effort",
                        required: false,
                        choices: ["minimal", "low", "medium", "high"].map { .init(name: $0, value: $0) }
                    ),
                    // perm: common permission modes (Codex maps via resolveThreadPolicy; Grok = bypass or not).
                    .init(
                        name: "perm",
                        description: "Permission mode",
                        required: false,
                        choices: ["default", "plan", "acceptEdits", "bypassPermissions"].map { .init(name: $0, value: $0) }
                    ),
                ]
            ),
            .init(name: "close", description: "Unbind this channel's session", options: []),
        ]
    )
}
