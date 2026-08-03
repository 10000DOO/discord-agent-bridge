import Foundation

// MARK: - Discord-visible command prefix

/// Prefix on every Discord-visible top-level command (`/dab-update`, `/dab-agent`), so this bot's
/// commands cannot be shadowed by another bot — or a client-mod plugin — owning the same bare name.
///
/// Specs, routing switches, and tests all keep the BARE name (`update`). The prefix is added once
/// at registration (`dabCommandName`) and removed once on dispatch (`bareCommandName`), so adding a
/// command needs no prefix bookkeeping. Subcommand names are never prefixed — they are already
/// namespaced by their parent (`/dab-agent start`).
public let dabCommandPrefix = "dab-"

/// Discord-visible name for a bare spec name.
public func dabCommandName(_ bare: String) -> String { dabCommandPrefix + bare }

/// Bare name to route on. A missing prefix is tolerated so an interaction from a stale client cache
/// — or a leftover unprefixed registration mid-propagation — still routes instead of silently
/// falling through to the unknown-command branch.
public func bareCommandName(_ received: String) -> String {
    received.hasPrefix(dabCommandPrefix)
        ? String(received.dropFirst(dabCommandPrefix.count))
        : received
}

/// A ko/en text pair for slash command descriptions. `AppLocale` has exactly two cases
/// (`I18n.swift:7-10`), so this is a fixed 2-field struct rather than a dictionary — both
/// values are required at compile time (no silent fallback on a missing key).
public struct LocalizedText: Sendable, Equatable {
    public var ko: String
    public var en: String
    public init(ko: String, en: String) { self.ko = ko; self.en = en }
}

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
        public var description: LocalizedText
        public var required: Bool
        public var choices: [Choice]
        /// When true, Discord asks the bot for suggestions (G-P1-03). Mutually exclusive with non-empty `choices`.
        public var autocomplete: Bool
        public init(
            name: String,
            description: LocalizedText,
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
        public var description: LocalizedText
        public var options: [Option]
        public init(name: String, description: LocalizedText, options: [Option]) {
            self.name = name; self.description = description; self.options = options
        }
    }
    public var name: String
    public var description: LocalizedText
    /// Top-level options when the command has no subcommands (e.g. `/model`, `/effort`).
    public var options: [Option]
    public var subcommands: [Subcommand]
    /// When true, register with Discord `default_member_permissions = Administrator`
    /// (TS `/setup` / `/config` gate — hides the command from non-admins in the client UI).
    public var requiresAdministrator: Bool
    public init(
        name: String,
        description: LocalizedText,
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
        description: LocalizedText(ko: "이 채널의 에이전트 세션을 관리합니다", en: "Manage this channel's agent session"),
        subcommands: [
            // W11-b2 slice1: wizard-only start (backend→model→effort→perm selects). No free-text options.
            .init(
                name: "start",
                description: LocalizedText(ko: "이 채널에 에이전트 세션을 시작하고 연결합니다 (마법사)", en: "Start and bind an agent session in this channel (wizard)"),
                options: []
            ),
            // W14: close is a real stop (backend + unbind), not unbind-only.
            .init(name: "close", description: LocalizedText(ko: "이 채널의 세션을 중지하고 연결을 해제합니다", en: "Stop and unbind this channel's session"), options: []),
            // G-P1-05: re-bind + status intro + soft ensure (lazy turn still works if soft fails).
            .init(name: "resume", description: LocalizedText(ko: "저장된 세션을 다시 연결하고 상태를 게시한 뒤 소프트 재연결합니다", en: "Re-bind stored session, post status, soft-reconnect"), options: []),
            .init(name: "stats", description: LocalizedText(ko: "활성 세션 연결 목록을 표시합니다", en: "List active session bindings"), options: []),
        ]
    )
}

/// `/mode backend` + `/mode perm` (TS parity; drive tier).
public func modeCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "mode",
        description: LocalizedText(ko: "백엔드 또는 권한 모드를 전환합니다", en: "Switch the backend or permission mode"),
        subcommands: [
            .init(
                name: "backend",
                description: LocalizedText(ko: "에이전트 백엔드를 전환합니다 (새 컨텍스트로 시작)", en: "Switch the agent backend (starts a fresh context)"),
                options: [
                    .init(
                        name: "backend",
                        description: LocalizedText(ko: "전환할 백엔드", en: "Backend to switch to"),
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
                description: LocalizedText(ko: "권한 모드를 전환합니다 (세션 유지)", en: "Switch the permission mode (session kept)"),
                options: [
                    .init(name: "value", description: LocalizedText(ko: "권한 모드", en: "Permission mode"), required: true, choices: []),
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
        description: LocalizedText(ko: "이 세션의 모델을 전환합니다", en: "Switch the model for this session"),
        options: [
            .init(
                name: "value",
                description: LocalizedText(ko: "전환할 모델", en: "Model to switch to"),
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
        description: LocalizedText(ko: "이 세션의 추론 강도를 전환합니다", en: "Switch the reasoning effort for this session"),
        options: [
            .init(
                name: "value",
                description: LocalizedText(ko: "전환할 추론 강도", en: "Reasoning effort to switch to"),
                required: true,
                choices: [],
                autocomplete: true
            ),
        ]
    )
}

/// Top-level `/stop` — hard-stop the current channel (drive tier; TS ACTION_TIER.stop).
public func stopCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(name: "stop", description: LocalizedText(ko: "이 채널의 에이전트 세션을 중지합니다", en: "Stop this channel's agent session"))
}

/// `/clear` — drop live sessions, keep config, wipe backendSessionId (PLAN §14.6).
public func clearCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "clear",
        description: LocalizedText(ko: "대화 컨텍스트를 초기화합니다 (같은 폴더/설정으로 새 세션 시작)", en: "Clear conversation context (fresh session, same folder/settings)")
    )
}

/// Top-level `/stop-all` — hard-stop every bound session (admin tier; TS ACTION_TIER['stop-all']).
public func stopAllCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(name: "stop-all", description: LocalizedText(ko: "모든 에이전트 세션을 중지합니다", en: "Stop all agent sessions"))
}

/// `/setup` — A4D guild channel structure (admin; TS `setDefaultMemberPermissions(Administrator)`).
public func setupCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "setup",
        description: LocalizedText(ko: "에이전트 제어 채널과 세션 카테고리를 생성합니다 (채널이 이미 있으면 불필요)", en: "Create the agent control channel and sessions category (unnecessary if the channels already exist)"),
        requiresAdministrator: true
    )
}

/// `/doc path:` — share a markdown file into a document thread (drive tier; TS `/doc`).
/// Free-text path (no autocomplete — avoids per-keystroke FS listing cost).
public func docCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "doc",
        description: LocalizedText(ko: "마크다운 문서를 스레드에 공유합니다", en: "Share a markdown document into a thread"),
        options: [
            .init(
                name: "path",
                description: LocalizedText(ko: "마크다운 파일 경로 (절대 경로 또는 세션 폴더 기준 상대 경로)", en: "Path to the markdown file (absolute, or relative to the session folder)"),
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
        description: LocalizedText(ko: "이 서버의 역할 등급과 기본값을 설정합니다", en: "Configure role tiers and defaults for this server"),
        requiresAdministrator: true
    )
}

/// `/update` — check registry for a newer stable version (admin; W16-h).
public func updateCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "update",
        description: LocalizedText(ko: "새 discord-agent-bridge 버전을 확인합니다", en: "Check for a new discord-agent-bridge version"),
        requiresAdministrator: true
    )
}

/// `/redmine` — configure Redmine notification integration (drive tier; anyone can run, D7).
public func redmineCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(name: "redmine", description: LocalizedText(ko: "레드마인 알림 연동을 설정합니다", en: "Configure Redmine notification integration"))
}

/// `/redmine-issue-select` — pick a matching Redmine issue from a dropdown (drive tier; anyone can run, D7).
public func redmineIssueSelectCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(name: "redmine-issue-select", description: LocalizedText(ko: "조건에 맞는 레드마인 이슈를 선택합니다", en: "Select a matching Redmine issue"))
}

/// `/orchestration` — install project-scoped issue-orchestration rules, skills, and subagents
/// into this session channel's project `.claude/` folder (Claude only).
public func orchestrationCommandSpec() -> SlashCommandSpec {
    SlashCommandSpec(
        name: "orchestration",
        description: LocalizedText(ko: "이 세션의 프로젝트 폴더에 이슈 오케스트레이션 규칙·스킬·서브에이전트를 설치합니다 (Claude 전용)", en: "Install issue-orchestration rules, skills, and subagents into this project's folder (Claude only)")
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
        redmineCommandSpec(),
        redmineIssueSelectCommandSpec(),
        orchestrationCommandSpec(),
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
