import DiscordAgentBridge
import DiscordBM
import Foundation
import Dispatch
import NIOCore

// C11: name mirrors TS's sole production `createLogger('app', ...)` call (`src/app.ts:124`) —
// DabMain.swift is Swift's rough equivalent of app.ts's boot sequence + event handlers.
private let log = Logger(name: "app")

// TEMP-DIAG3: unbuffered direct-to-file diagnostic, bypassing whatever buffering `log` has.
private func tempDiagWrite(_ s: String) {
    let path = "/tmp/redmine-diag.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        if let data = "\(Date()) \(s)\n".data(using: .utf8) {
            fh.write(data)
        }
        try? fh.close()
    }
}

@main
struct DabMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // C12: CLI entry points, mirroring src/cli.ts's `--version`/`--setup` (`service <sub>`
        // is out of scope here — C13). Checked via `args.first` like the smoke-test
        // subcommands below, since argv[1] doubles as the fallback token position.
        if args.first == "--version" {
            print(readAppVersion())
            return
        }
        if args.first == "--setup" {
            printSetupGuidance()
            return
        }
        // C13: `dab service <status|restart>` — never boots the bot (mirrors cli.ts's
        // service dispatch). install/uninstall stay as swift/scripts/install.sh|uninstall.sh.
        if args.first == "service" {
            let ok = await runServiceCommand(Array(args.dropFirst()))
            exit(ok ? 0 : 1)
        }
        if args.first == "sidecar-smoke" {
            await runSidecarSmoke()
            return
        }
        if args.first == "codex-smoke" {
            await runCodexSmoke()
            return
        }
        if args.first == "grok-smoke" {
            await runGrokSmoke()
            return
        }
        if args.first == "attach-mcp" {
            await runAttachMcpStdio()
            return
        }

        // A present config.json is authoritative: surface decode/validation errors instead of
        // silently booting with an env/argv token. Env/argv remain first-run fallbacks only.
        let config: AppConfig?
        if await ConfigStore.shared.exists() {
            do {
                config = try await ConfigStore.shared.load()
            } catch {
                fputs("Failed to load config: \(error)\n", stderr)
                exit(1)
            }
        } else {
            config = nil
        }
        let token: String?
        if let config {
            token = DiscordToken.resolve(environment: [:], arguments: [], configToken: config.discord.token)
        } else {
            token = DiscordToken.resolve()
        }
        guard let token else {
            fputs(DiscordToken.usage + "\n", stderr)
            exit(1)
        }

        // Redmine API-key cipher secret: reuse env/file, or generate into ~/.dab/env once.
        // Best-effort — boot continues on failure; encrypt/decrypt stays fail-secure later.
        do {
            let ensured = try RedmineKeySecret.ensure()
            if ensured.generated {
                log.info("redmine: generated DAB_REDMINE_KEY_SECRET into ~/.dab/env")
            }
        } catch {
            log.warn("redmine: failed to ensure DAB_REDMINE_KEY_SECRET: \(error)")
        }

        let bot = await BotGatewayManager(
            token: token,
            intents: [.guilds, .guildMessages, .messageContent]
        )

        // M13: record this process's PID (TS app.ts:610-618) right after the client is created
        // and before the gateway login attempt — not after Ready fires (was in onReady, i.e.
        // after a successful login), so a hung/failed login still leaves a killable pid file.
        // Best-effort — never blocks boot.
        do {
            try writePidFile(baseDir: await ConfigStore.shared.dir, pid: ProcessInfo.processInfo.processIdentifier)
        } catch {
            log.warn("failed to write pid file: \(error)")
        }

        // [DAB-DIAG-PROC-EXIT]: tell an external kill (launchd/SIGTERM/SIGINT) apart from the
        // process exiting on its own — restart-storm diagnosis found no crash report, so the
        // next occurrence needs this in the log (docs/log-buffering-lost-info-logs.md).
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler {
            log.warn("[DAB-DIAG-PROC-EXIT] received SIGTERM — exiting")
            exit(0)
        }
        sigtermSource.resume()
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            log.warn("[DAB-DIAG-PROC-EXIT] received SIGINT — exiting")
            exit(0)
        }
        sigintSource.resume()

        log.info("connecting to Discord gateway…")
        log.info("!claude <prompt> → Claude sidecar (DAB_CWD / DAB_PERM_MODE)")

        // G-P1-08: process-wide UI language from config.locale (default ko).
        // C11: process-wide log level from config.logLevel, read once at boot (TS reads
        // config once before creating its single `app` logger; no hot-reload — matches).
        if let cfg = config {
            I18n.applyFromConfigLocale(cfg.locale)
            if let level = LogLevel(rawValue: cfg.logLevel) {
                currentLogLevel.withLock { $0 = level }
            }
            // C1: reconfigure CodexUsageService off its `nil, nil` defaults with the actual
            // configured codexHome/codexCliCommand (WO-2's `.configure` — `.shared` is a fixed
            // `static let`, so this is the only way to move it after construction).
            await CodexUsageService.shared.configure(
                codexHome: cfg.defaults.codexHome,
                codexCommand: cfg.defaults.codexCliCommand
            )
            // C1/WO-14: same reconfiguration for CodexSessionBridge.shared — without this, the
            // actual codex session spawn (not just usage polling) keeps ignoring config.json's
            // codexHome/codexCliCommand.
            await CodexSessionBridge.shared.configure(
                codexHome: cfg.defaults.codexHome,
                codexCliCommand: cfg.defaults.codexCliCommand
            )
        }

        // Wire the permission-button presenter once: the gate (library) posts Allow / Always-Allow /
        // Deny to the prompt's channel via the Discord client. Set before events flow.
        let client = bot.client
        await PermissionGate.shared.setPresenter { prompt in
            await postPermissionButtons(client: client, prompt: prompt)
        }
        // W16-d: host.file.share reverse RPC + /doc funnel through the same Discord poster.
        await DocumentShareHost.shared.setShareHandler { channelId, path in
            try await postDocumentShare(client: client, channelId: channelId, path: path)
        }
        // host.file.attach reverse RPC → confined path + channel attachment upload.
        await FileAttachHost.shared.setAttachHandler { channelId, path, name in
            try await postFileAttach(client: client, channelId: channelId, path: path, name: name)
        }
        // WO-5 (design_orchestration_module_agents.md): host.orchestration.order/.report reverse
        // RPC — bot-authored turn drive + a per-guild channel provisioner for the module
        // channel's first-order creation. Same "no in-library default, wired once at boot" seam
        // shape as FileAttachHost/DocumentShareHost above.
        await OrchestrationHost.shared.setRunTurnHandler {
            channelId, guildId, backend, promptText, postPrompt, announceExtras, actorId, roleTier in
            await runInjectedTurn(
                client: client, channelId: channelId, guildId: guildId, backend: backend,
                promptText: promptText, postPrompt: postPrompt, announceExtras: announceExtras,
                actorId: actorId, roleTier: roleTier
            )
        }
        await OrchestrationHost.shared.setProvisionerFactory { guildId in
            resolveGuildProvisioner(client: client, guildId: guildId)
        }
        // W16-g: tool_use / tool_result → Discord work threads (+ diffs) via createThread.
        await ToolActivityHost.shared.setChannelFactory { channelId in
            turnThreadChannel(client: client, channelId: channelId)
        }
        // C15: tool_use → status-channel notification (independent of render capabilities).
        await ToolActivityHost.shared.setNotifier { channelId, guildId, backend, event in
            await postStatusNotification(
                client: client, guildId: guildId, sessionChannelId: channelId, event: event, backend: backend
            )
        }
        // W11-g residual: mid-turn stream status embed edits (text / tool_use / progress).
        await StreamStatusHost.shared.setUpdater { channelId, messageId, guildId, spec in
            await editStreamControlMessage(
                client: client,
                channelId: ChannelSnowflake(channelId),
                messageId: MessageSnowflake(messageId),
                guildId: guildId,
                spec: spec
            )
        }
        // G-P1-01: turn idle watchdog (~3 min no activity → one channel notice).
        await IdleWatchdog.shared.setPoster { channelId, content in
            // C14: retry-wrapped (no guildId in scope here — onGone omitted, the live
            // channelDelete event / boot resumeAll already cover cleanup).
            _ = await createMessageWithRetry(
                client: client,
                channelId: ChannelSnowflake(channelId),
                payload: .init(content: content)
            )
        }
        // S3: table/mermaid → PNG when Chrome available + render.enabled.
        await ImageRenderHost.shared.configure(
            configLoad: { try? await ConfigStore.shared.load() }
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await bot.connect()
                log.warn("[DAB-DIAG-PROC-EXIT] bot.connect() returned")
            }
            group.addTask {
                for await event in await bot.events {
                    // messageCreate/interactionCreate are the high-frequency, potentially-slow
                    // events (turn runs, slash commands) — run them off the loop so one channel's
                    // long turn never blocks another channel's interaction (gateway-event-loop-
                    // serialized.md). Every other event (ready/guildCreate/role changes/channel
                    // delete) keeps its current sequential await: onReady seeds the bot user id
                    // that onGuildCreate reads, and that ordering must not change.
                    switch event.data {
                    case .messageCreate, .interactionCreate:
                        Task {
                            await EventHandler(event: event, client: bot.client).handleAsync()
                        }
                    default:
                        await EventHandler(event: event, client: bot.client).handleAsync()
                    }
                }
                log.warn("[DAB-DIAG-PROC-EXIT] event stream ended")
            }
        }
        log.warn("[DAB-DIAG-PROC-EXIT] main task group drained — process exiting")
    }
}

// C12: `dab --setup`. This build has no interactive terminal wizard (unlike the Node
// CLI's `@inquirer/prompts` flow) — the actual Swift deployment story is env-file based
// (see swift/scripts/install.sh), so this only points at the ways to provide a token
// instead of inventing a new config-writing subsystem. Never boots the bot afterward.
func printSetupGuidance() {
    print("""
    dab setup
      This build has no interactive terminal wizard. Configure the bot token one of these ways, then run `dab` again:
        1. export DISCORD_BOT_TOKEN=your_bot_token
        2. Edit config.json → discord.token (~/.discord-agent-bridge/config.json, or $DAB_HOME)
        3. Pass the token as the first CLI argument: dab <token>
      Client ID / role setup happens later in Discord via /config.
    """)
}

struct EventHandler: GatewayEventHandler {
    let event: Gateway.Event
    let client: any DiscordClient

    func onReady(_ payload: Gateway.Ready) async throws {
        let user = payload.user
        log.info("ready: username=\(user.username) id=\(user.id) app=\(payload.application.id)")
        // G-P1-07: remember bot user id for Manage Channels checks on subsequent GuildCreate.
        // READY only carries UnavailableGuild stubs; full guilds arrive as GuildCreate (boot + join).
        await BotGatewayIdentity.shared.setUserId(user.id.rawValue)
        signalSuccessorReadyIfRequested()
        log.info("auto-provision will run on GuildCreate for \(payload.guilds.count) guild stub(s)")
        await registerAgentCommand(appId: payload.application.id, guildIds: payload.guilds.map(\.id.rawValue))
        await restoreSessionBindings()
        // M13: pid file is now written in main() right after the client is created, before the
        // login attempt (see there) — not here, after Ready already fired.
        // C10: eagerly reconnect every restored channel now, instead of waiting for its next
        // message — TS `resumeAll()` + `app.ts`'s boot attach loop (10003 detection + cleanup).
        let resumeSummary = await SessionLifecycle.shared.resumeAll(channelGone: { channelId in
            await self.channelConfirmedGone(channelId: channelId)
        })
        log.info(
            "resume-on-boot complete resumed=\(resumeSummary.resumed) "
                + "cleaned=\(resumeSummary.cleaned) total=\(resumeSummary.total)"
        )
        // WO-9: the `/command` command cache lives in this process, so a restart empties it — which
        // is exactly how a channel that has been talking for hours still opened an empty picker.
        // Refill it for every restored channel. Detached and sequential: boot must not wait on it,
        // and there is no reason to probe every backend at once.
        Task {
            for (channelId, ps) in await SessionStore.shared.active() {
                await warmSlashCatalog(channelId: channelId, backend: ps.backend)
            }
        }
        // W16-h: version check schedule (posts to control channels when a newer stable exists).
        await startAutoUpdater(client: client)
        // Provider binaries/SDKs use the same operator master switch, but only swap after every
        // active turn drains; persisted explicit model bindings are never rewritten.
        await startProviderRuntimeUpdater()
        // respawn hand-off의 predecessor가 onConfirmed에서 이미 clearPendingRestart+notify를 수행하므로,
        // 그 successor(DAB_SUCCESSOR_READY_FILE로 식별)까지 또 확인하면 확인 메시지가 중복 발송된다.
        if ProcessInfo.processInfo.environment["DAB_SUCCESSOR_READY_FILE"] == nil {
            await AutoUpdaterRegistry.shared.get()?.confirmPendingRestartIfNeeded()
        }
        // WO-10: resume per-guild Redmine pollers for guilds that already have a saved config.
        await restoreRedminePollers(client: client)
    }

    /// G-P1-07: auto-provision channel structure on every guild the bot is in (fires after Ready
    /// for existing guilds, and again when the bot is invited). Manage-Channels-guarded + non-throwing.
    func onGuildCreate(_ payload: Gateway.GuildCreate) async throws {
        if payload.unavailable == true { return }
        let guildId = payload.id.rawValue
        let botId = await BotGatewayIdentity.shared.getUserId()
        let canManage = botCanManageChannels(guild: payload, botUserId: botId)
        // (OK-2) cache owner + admin-flagged role ids so the message path can compute
        // isAdministrator without gateway-provided member.permissions (Q1).
        let adminRoleIds = Set(payload.roles.filter { $0.permissions.contains(.administrator) }.map(\.id.rawValue))
        await GuildAdminCache.shared.setGuild(guildId: guildId, ownerId: payload.owner_id.rawValue, adminRoleIds: adminRoleIds)
        // Never throws — autoProvisionGuild swallows create failures so one guild never kills ready.
        await runAutoProvisionGuild(client: client, guildId: guildId, manageChannels: canManage)
        // READY's first due-check can precede GuildCreate and find no control channels. Retry
        // only when that exact condition was recorded, after this guild's channel is persisted.
        if let updater = await AutoUpdaterRegistry.shared.get() {
            await updater.checkAfterControlChannelReady()
        }
    }

    /// Q1-b: keep GuildAdminCache current when a role's Administrator bit (or the role itself)
    /// changes, so the message path reflects it without a restart.
    func onGuildRoleCreate(_ payload: Gateway.GuildRole) async throws {
        await GuildAdminCache.shared.setRoleIsAdmin(
            guildId: payload.guild_id.rawValue,
            roleId: payload.role.id.rawValue,
            isAdmin: payload.role.permissions.contains(.administrator)
        )
    }

    func onGuildRoleUpdate(_ payload: Gateway.GuildRole) async throws {
        await GuildAdminCache.shared.setRoleIsAdmin(
            guildId: payload.guild_id.rawValue,
            roleId: payload.role.id.rawValue,
            isAdmin: payload.role.permissions.contains(.administrator)
        )
    }

    func onGuildRoleDelete(_ payload: Gateway.GuildRoleDelete) async throws {
        await GuildAdminCache.shared.removeRole(guildId: payload.guild_id.rawValue, roleId: payload.role_id.rawValue)
    }

    /// G5: on boot, load persisted sessions and repopulate the routing map so prefix-less messages
    /// reach the saved backend. Registry-only — does not itself touch any backend; the caller
    /// (`onReady`) follows up with `SessionLifecycle.resumeAll` (C10) to eagerly reconnect. A channel
    /// that eager-resume misses still falls back to the on-demand `softEnsureLive` on its first
    /// message. Skips archived bindings (TS resumeAll filters `archived == true`).
    private func restoreSessionBindings() async {
        let imported = await LegacyStateImport.runIfNeeded()
        if imported > 0 {
            log.info("imported \(imported) channel binding(s) from legacy state.json")
        }
        await SessionStore.shared.load()
        let active = await SessionStore.shared.active()
        for (channelId, ps) in active {
            await SessionRegistry.shared.bind(
                channelId: channelId,
                SessionConfig(backend: ps.backend, model: ps.model, effort: ps.effort, permMode: ps.permMode)
            )
        }
        log.info("restored \(active.count) session binding(s) from store")
    }

    /// C10: TS `wiring.ts`'s `resolveChannelResult` — true only when Discord confirms the channel is
    /// permanently gone (10003 Unknown Channel). Any other outcome (network hiccup, other API error)
    /// returns false so a transient failure can never trigger the boot loop's stale-binding cleanup.
    private func channelConfirmedGone(channelId: String) async -> Bool {
        guard let response = try? await client.getChannel(id: ChannelSnowflake(channelId)) else { return false }
        guard case .jsonError(let jsonError)? = response.httpResponse.asError() else { return false }
        return jsonError.code == .unknownChannel
    }

    /// Register slash commands (W11-d set). Dev: instant per-guild via `DAB_DEV_GUILD_ID`; else global (~1h).
    /// `guildIds`: every guild the bot belongs to (Ready.guilds) — used only for the post-register sweep below.
    private func registerAgentCommand(appId: ApplicationSnowflake, guildIds: [String]) async {
        let cmds = allCommandPayloads()
        let devGuildId = ProcessInfo.processInfo.environment["DAB_DEV_GUILD_ID"].flatMap { $0.isEmpty ? nil : $0 }
        do {
            if let g = devGuildId {
                _ = try await client.bulkSetGuildApplicationCommands(appId: appId, guildId: GuildSnowflake(g), payload: cmds)
                log.info("registered \(cmds.map(\.name).joined(separator: ", ")) to guild \(g)")
            } else {
                _ = try await client.bulkSetApplicationCommands(appId: appId, payload: cmds)
                log.info("registered \(cmds.map(\.name).joined(separator: ", ")) globally (propagation ~1h)")
            }
        } catch {
            log.error("slash register failed: \(error)")
        }
        // (OK-2 leftover) Q2: sweep guild-scoped commands left by a predecessor that registered
        // per-guild (e.g. the old TS bridge) — every boot, global-registration mode only.
        await sweepStaleGuildCommands(knownGuildIds: guildIds, devGuildId: devGuildId) { guildId in
            do {
                _ = try await client.bulkSetGuildApplicationCommands(appId: appId, guildId: GuildSnowflake(guildId), payload: [])
            } catch {
                log.warn("guild command cleanup failed for \(guildId): \(error)")
            }
        }
    }

    /// Every Discord-originated response is rendered under its guild's persisted locale.
    /// DMs are structurally hidden at registration time; retain the process default only as a
    /// defensive fallback for malformed/non-guild events and a guild without an override.
    private func responseLocale(guildId: String?) async -> AppLocale {
        guard let guildId, !guildId.isEmpty else { return I18n.getLocale() }
        let server = await ConfigStore.shared.loadServerConfig(guildId: guildId)
        return I18n.resolveServerLocale(server?.locale)
    }

    private func appLocale(fromDiscord locale: DiscordLocale) -> AppLocale {
        locale == .korean ? .ko : .en
    }

    private func autoDetectServerLocaleIfNeeded(_ payload: Interaction) async {
        guard payload.type == .applicationCommand else { return }
        guard let guildId = payload.guild_id?.rawValue, !guildId.isEmpty else { return }
        guard let discordLocale = payload.locale else { return }
        let existing = await ConfigStore.shared.loadServerConfig(guildId: guildId)
        guard existing?.locale == nil else { return }
        var next = existing ?? ServerConfig(guildId: guildId)
        next.version = existing?.version ?? CONFIG_VERSION
        next.guildId = guildId
        next.locale = appLocale(fromDiscord: discordLocale).rawValue
        do {
            try await ConfigStore.shared.saveServerConfig(next)
        } catch {
            log.warn("locale auto-detect save failed for guild \(guildId): \(error)")
        }
    }

    func onInteractionCreate(_ payload: Interaction) async throws {
        await autoDetectServerLocaleIfNeeded(payload)
        let locale = await responseLocale(guildId: payload.guild_id?.rawValue)
        try await I18n.withLocale(locale) {
            try await handleInteractionCreate(payload)
        }
    }

    private func handleInteractionCreate(_ payload: Interaction) async throws {
        // (A-ac) Application-command autocomplete (G-P1-03). Must answer with type 8 within ~3s;
        // never auth-deny text / never treat as a slash invoke (DiscordBM shares the data shape).
        if payload.type == .applicationCommandAutocomplete {
            await handleAutocomplete(payload)
            return
        }
        // (A0) Modal submits (dir:create / dir:manual) — owner-gated, re-renders folder step.
        if let modal = try? payload.data?.requireModalSubmit() {
            try await handleWizardModal(payload, modal: modal)
            return
        }
        // (A) Message components: permission buttons + agent-start wizard selects/buttons.
        if let comp = try? payload.data?.requireMessageComponent() {
            // (A1) Permission button click → resolve the gate. Only the session approver may decide.
            // W16-e: Always-Allow peeks the tool BEFORE resolve (entry is removed on settle), then
            // persists into global autoAllowClaudeTools (best-effort; turn is already allowed).
            if let (reqKey, action) = parseCustomId(comp.custom_id) {
                let userId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue
                // H2: resolve() below removes the pending entry, so the tool name for the
                // re-rendered embed must be peeked for EVERY action, not just always-allow.
                let toolName = await PermissionGate.shared.peekToolName(reqKey)
                let accepted = await PermissionGate.shared.resolve(reqKey: reqKey, action: action, byUserId: userId)
                if accepted {
                    if action == .always, let tool = toolName, !tool.isEmpty {
                        await persistAlwaysAllow(
                            tool: tool,
                            actorId: userId ?? "",
                            guildId: payload.guild_id?.rawValue ?? "dm",
                            channelId: payload.channel_id?.rawValue ?? ""
                        )
                    }
                    let decidedKey: String
                    switch action {
                    case .allow: decidedKey = "perm.decided.allow"
                    case .always: decidedKey = "perm.decided.always"
                    case .deny: decidedKey = "perm.decided.deny"
                    }
                    let decidedLabel = I18n.t(decidedKey)
                    // Replace the buttons with the outcome, keeping the same embed shape as the
                    // original prompt (TS permissionButtons.ts:149-167): title gets " — <decision>"
                    // appended, body reuses perm.request.body with `input` swapped for the decision
                    // label, color flips to stopped(deny)/idle(else). `content` (the approver
                    // mention, if any) is left untouched — omitting it from the update payload
                    // means Discord keeps whatever was already there.
                    let embed = discordEmbed(from: PermissionEmbedSpec(
                        title: "\(I18n.t("perm.request.title")) — \(decidedLabel)",
                        description: I18n.t("perm.request.body", ["tool": toolName ?? "", "input": decidedLabel]),
                        color: action == .deny ? DiscordColors.stopped : DiscordColors.idle
                    ))
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .updateMessage(.init(embeds: [embed], components: []))
                    )
                } else {
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .channelMessageWithSource(.init(content: I18n.t("perm.request.notAuthorized"), flags: [.ephemeral]))
                    )
                }
                return
            }
            // (A1b) H6: Chromium install prompt (render-setup:install|decline) — posted after
            // /setup. Host-wide decision, drive-tier (anyone may act on it), checked before the
            // wizard/config dispatch below since it shares no custom_id namespace with either.
            if let renderSetupAction = parseRenderSetupId(comp.custom_id) {
                try await handleRenderSetupComponent(client: client, payload: payload, action: renderSetupAction)
                return
            }
            // (A2a) Resume flow: dir:resume + resume.* (owner-gated; may list/spawn sidecar >3s).
            // cancel while a resume flow is active is routed here (shared custom_id with ChannelWizard).
            let resumeChannelId = payload.channel_id?.rawValue ?? ""
            let hasResumeFlow = await ResumeWizardRegistry.shared.get(channelId: resumeChannelId) != nil
            if isResumeWizardCustomId(comp.custom_id)
                || (comp.custom_id == "cancel" && hasResumeFlow)
            {
                try await handleResumeComponent(payload, comp: comp)
                return
            }
            // (A2b) "💾 프리셋으로 저장" — wizard already deleted at done; showModal is the ack.
            // Not owner-bound (ephemeral message is only visible to the driver).
            if comp.custom_id == "preset.save" {
                try await handlePresetSaveButton(payload)
                return
            }
            // (A2c) redmine:issue-select dropdown (WO-13, R10) — standalone flow, unrelated to
            // WizardRegistry ownership like redmine:config (modal submit dispatch above).
            if comp.custom_id == "redmine:issue-select" {
                try await handleRedmineIssueSelectComponent(payload, comp: comp)
                return
            }
            // (A2d) Redmine issue start/cancel buttons (WO-14, R7/R8) on the card posted by
            // the poller (R6) or redmine:issue-select (R10).
            if isRedmineIssueCustomId(comp.custom_id), let redmineIssue = parseRedmineIssueId(comp.custom_id) {
                try await handleRedmineIssueComponent(
                    payload,
                    comp: comp,
                    action: redmineIssue.action,
                    issueId: redmineIssue.issueId,
                    targetChannelId: redmineIssue.targetChannelId
                )
                return
            }
            // (A2e) Orchestration start-spec card (WO-10) — separate `orch:` namespace + registry
            // so it never collides with the /agent start wizard on the same channel (8장 11번).
            if isOrchestrationWizardCustomId(comp.custom_id) {
                try await handleOrchestrationWizardComponent(payload, comp: comp)
                return
            }
            // (A2) W11-b2 wizard components (folder browser + select steps; owner-gated).
            if isWizardCustomId(comp.custom_id) {
                try await handleWizardComponent(payload, comp: comp)
                return
            }
            // (A3) W16-b /config panel components (role/string selects + Save; owner-gated).
            if isConfigPanelId(comp.custom_id) {
                try await handleConfigComponent(payload, comp: comp)
                return
            }
            // (A4) W16-h auto-update Yes/No buttons (admin gate).
            if let updateTarget = parseUpdateId(comp.custom_id) {
                try await handleUpdateComponent(payload, action: updateTarget.action, version: updateTarget.version)
                return
            }
            // (A4b) Turn-timeout retry prompt Yes/No (posted alongside the "turn timeout (no
            // terminal result)" error text; anyone may act on it — no owner/permission gate).
            if let timeoutAction = parseTurnTimeoutId(comp.custom_id) {
                try await handleTurnTimeoutComponent(payload, action: timeoutAction)
                return
            }
            // (A5) Interrupt "stop" button: interrupt:<guildId>:<channelId> (drive; does NOT unbind).
            if let interruptTarget = parseInterruptId(comp.custom_id) {
                try await handleInterruptComponent(
                    payload,
                    guildId: interruptTarget.guildId,
                    channelId: interruptTarget.channelId
                )
                return
            }
            return
        }

        // (B) Slash — agent/mode/model/effort/stop/clear/stop-all/setup/doc/config/update
        // (TS ACTION_TIER: drive except stop-all + setup + config + update admin).
        guard let cmd = try? payload.data?.requireApplicationCommand() else { return }
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? "dm"
        let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        // Names register bare now; a stale client may still send the legacy `dab-update` form, and
        // `bareCommandName` strips it so both land on the same case below.
        let commandName = bareCommandName(cmd.name)
        let authAction: AuthAction = (commandName == "stop-all" || commandName == "setup" || commandName == "config" || commandName == "update")
            ? .admin : .drive
        // G-P0-05: per-project ACL from store narrows (nil = no extra gate).
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        // First-admin bootstrap: a guild with NO admin roles/users yet lets /setup through
        // unconditionally so whoever runs it first can claim admin without touching Discord's own
        // role UI. Fires at most once per guild — adminUserIds is no longer empty afterward.
        let setupBootstrap: Bool
        if commandName == "setup", let bootstrapGuildId = payload.guild_id?.rawValue {
            setupBootstrap = await Authorizer(config: .shared).isSetupBootstrapEligible(guildId: bootstrapGuildId)
        } else {
            setupBootstrap = false
        }
        let isDiscordAdministrator = await hasDiscordAdministrator(
            payload,
            guildId: payload.guild_id?.rawValue,
            userId: actorId
        )
        let decision = setupBootstrap
            ? AuthResult(allowed: true, tier: .admin)
            : await Authorizer(config: .shared).authorize(
                AuthInput(
                    userId: actorId,
                    roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                    action: authAction,
                    guildId: payload.guild_id?.rawValue,
                    channelId: channelId,
                    isAdministrator: isDiscordAdministrator
                ),
                projectAuth: projectAuth
            )
        guard decision.allowed else {
            await AuditLog.shared.record(AuditEntry(
                actorId: actorId,
                roleTier: decision.tier?.rawValue ?? "none",
                guildId: guildId,
                channelId: channelId,
                action: authAction.rawValue,
                outcome: decision.reason,
                status: "denied"
            ))
            try await respondEphemeral(
                payload,
                I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"])
            )
            return
        }
        let tier = decision.tier?.rawValue ?? "execute"
        let stubCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let life = SessionLifecycle.shared
        let noSession = I18n.t("router.noSession")

        switch commandName {
        case "stop":
            // Stopping the live bridge can be slow; ack before it starts so Discord's
            // three-second interaction token never expires (mirrors /agent start's defer).
            let stopDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard stopDeferred != nil else { return }
            _ = await life.stopChannel(
                channelId: channelId, actorId: actorId, guildId: guildId, roleTier: tier
            )
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("cmd.stop.done"))
            )

        case "stop-all":
            // Loops stopChannel over every active channel — same slow-teardown risk as /stop.
            let stopAllDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard stopAllDeferred != nil else { return }
            let count = await life.stopAll(actorId: actorId, guildId: guildId, roleTier: tier)
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("cmd.stopAll.done", ["count": "\(count)"]))
            )

        case "clear":
            // The live bridge stop this triggers can be slow; ack before it starts so Discord's
            // three-second interaction token never expires (mirrors /agent start's defer).
            let clearDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard clearDeferred != nil else { return }
            // Read before the clear: the role survives it, but the backend is needed below for the
            // lead's role-marker turn, so one lookup covers both.
            let priorBinding = await SessionStore.shared.binding(channelId: channelId)
            let wasLead = priorBinding?.orchestrationRole == "orchestrator"
            // PLAN §14.6: keep config, wipe backendSessionId + live bridges (not full unbind).
            let ok = await life.clearChannel(
                channelId: channelId, actorId: actorId, guildId: guildId,
                roleTier: tier, defaultCwd: stubCwd
            )
            // Clearing a lead wipes its memory of the set it opened, so its modules get the same
            // wipe — otherwise they answer the next order out of a conversation the lead no longer
            // has. Their channels stay (unlike `/orchestration` re-run, which orphans them).
            var clearedModules = 0
            if ok && wasLead {
                clearedModules = await life.clearOrchestrationModules(
                    orchestratorChannelId: channelId, actorId: actorId, roleTier: tier
                ).count
                // Fresh lead context has issued no orders yet — carrying the old tally over would
                // refuse them against a cap the previous context filled.
                await OrchestrationHost.shared.resetRoundTrips(orchestratorChannelId: channelId)
            }
            // clear keeps the binding but drops the live bridges, so the channel would sit bound
            // with no open session until its next message — /model and /effort would then have
            // nothing live to apply to. Reopen now (same soft ensure the /agent resume paths use),
            // and do it BEFORE the done reply so a user acting on that reply always finds a live
            // session instead of racing the in-flight start. Skipped for a lead: its role-marker
            // turn below opens the session anyway, so a soft ensure here would only start one that
            // turn immediately takes over.
            if ok && !wasLead {
                _ = await life.softEnsureLive(channelId: channelId)
            }
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: ok
                    ? (clearedModules > 0
                        ? I18n.t("cmd.clear.doneWithModules", ["count": "\(clearedModules)"])
                        : I18n.t("cmd.clear.done"))
                    : noSession)
            )
            // The store keeps `orchestrationRole`, but the fresh session only learns it's the lead
            // from this marker — CLAUDE.md's role index maps it to `.claude/roles/ORCHESTRATOR.md`
            // (OrchestrationProjectBundle.swift). Without it a cleared lead behaves like an
            // ordinary session and never picks its role manual back up. Same
            // promptText/postPrompt/announceExtras as `/orchestration`'s own first turn, and after
            // the reply for the same reason: the turn is slow, the ack is not.
            // Module channels need no equivalent turn — `order()` re-adds their `[역할] Agent:{module}`
            // preamble on the next order, so their role costs nothing until they're actually used.
            if ok, wasLead, let leadBackend = priorBinding?.backend {
                await runInjectedTurn(
                    client: client, channelId: channelId, guildId: guildId, backend: leadBackend,
                    promptText: "[역할] 오케스트레이터", postPrompt: true, announceExtras: false,
                    actorId: actorId, roleTier: tier
                )
            }

        case "model":
            guard let value = try? cmd.requireOption(named: "value").requireString(), !value.isEmpty else {
                try await respondEphemeral(payload, I18n.t("cmd.model.missingValue"))
                return
            }
            // C4-c: only Claude/.custom sessions expose a live setModel (TS
            // sessionOrchestrator.ts:389 `if (typeof session.setModel !== 'function') return
            // 'unsupported'` — codex/grok never do), so report unsupported up front instead of
            // letting updateBinding persist a model field the backend never reads.
            let modelStoreRow = await SessionStore.shared.binding(channelId: channelId)
            let modelRegRow = await SessionRegistry.shared.binding(channelId: channelId)
            guard let modelBackend = modelStoreRow?.backend ?? modelRegRow?.backend else {
                try await respondEphemeral(payload, noSession)
                return
            }
            guard modelBackend == .claude || modelBackend == .custom else {
                try await respondEphemeral(payload, I18n.t("cmd.model.unsupported"))
                return
            }
            let modelResult = await life.updateBinding(
                channelId: channelId, patch: BindingPatch(model: value),
                actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
            )
            // Claude live session: updateBinding also fires session.setModel (W11-g).
            let modelMessage: String
            switch modelResult {
            // Persist the alias the autocomplete submitted; confirm it as the concrete wire id.
            case .ok: modelMessage = I18n.t("cmd.model.switched", ["model": modelDisplayText(value)])
            case .noBinding: modelMessage = noSession
            case .invalidEffort, .applyFailed, .persistFailed: modelMessage = I18n.t("cmd.model.failed")
            }
            try await respondEphemeral(payload, modelMessage)

        case "effort":
            guard let value = try? cmd.requireOption(named: "value").requireString(), !value.isEmpty else {
                try await respondEphemeral(payload, I18n.t("cmd.effort.missingValue"))
                return
            }
            // C4-c: Grok sessions never expose live effort switching (TS acpSession.ts —
            // setModel/setEffort intentionally absent); Claude/.custom/Codex do.
            let effortStoreRow = await SessionStore.shared.binding(channelId: channelId)
            let effortRegRow = await SessionRegistry.shared.binding(channelId: channelId)
            guard let effortBackend = effortStoreRow?.backend ?? effortRegRow?.backend else {
                try await respondEphemeral(payload, noSession)
                return
            }
            guard effortBackend != .grok else {
                try await respondEphemeral(payload, I18n.t("cmd.effort.unsupported"))
                return
            }
            let effortResult = await life.updateBinding(
                channelId: channelId, patch: BindingPatch(effort: value),
                actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
            )
            let effortMessage: String
            switch effortResult {
            case .ok: effortMessage = I18n.t("cmd.effort.switched", ["effort": value])
            case .noBinding: effortMessage = noSession
            case .invalidEffort, .applyFailed, .persistFailed: effortMessage = I18n.t("cmd.effort.failed")
            }
            try await respondEphemeral(payload, effortMessage)

        case "mode":
            guard let sub = cmd.options?.first else { return }
            switch sub.name {
            case "backend":
                guard let raw = try? sub.requireOption(named: "backend").requireString() else {
                    try await respondEphemeral(payload, I18n.t("cmd.mode.unknownBackend"))
                    return
                }
                guard let backend = Backend(rawValue: raw) else {
                    try await respondEphemeral(payload, I18n.t("cmd.mode.unavailable", ["backend": raw]))
                    return
                }
                // Require an existing binding (no cwd/owner to carry over otherwise).
                let storeRow = await SessionStore.shared.binding(channelId: channelId)
                let regRow = await SessionRegistry.shared.binding(channelId: channelId)
                guard storeRow != nil || regRow != nil else {
                    try await respondEphemeral(payload, noSession)
                    return
                }
                let currentBackend = storeRow?.backend ?? regRow!.backend
                // Same backend: immediate rebind (fresh context) — R6.
                if currentBackend == backend {
                    // rebindBackend stops the live bridge before rebinding — slow, same as /clear.
                    let modeDeferred = try? await client.createInteractionResponse(
                        id: payload.id,
                        token: payload.token,
                        payload: .deferredChannelMessageWithSource(isEphemeral: true)
                    )
                    guard modeDeferred != nil else { return }
                    let ok = await life.rebindBackend(
                        channelId: channelId, backend: backend,
                        actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
                    )
                    _ = try? await client.updateOriginalInteractionResponse(
                        appId: payload.application_id,
                        token: payload.token,
                        payload: .init(content: ok
                            ? I18n.t("cmd.mode.switched", ["backend": backend.rawValue])
                            : noSession)
                    )
                    if ok, let ch = payload.channel_id {
                        _ = await createMessageWithRetry(
                            client: client,
                            channelId: ch,
                            payload: .init(content:
                                I18n.t("cmd.mode.freshContext", ["backend": backend.rawValue])
                            ),
                            onGone: {
                                await SessionLifecycle.shared.stopChannel(
                                    channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                                )
                            }
                        )
                    }
                    return
                }
                // Different backend: DO NOT stop the running session (R1/R4). Open reconfigure
                // popup (model → effort → perm); stop+rebind only on perm.start confirm.
                // loadWizardOptionSource warms every backend's catalog, incl. a live Claude sidecar
                // probe that can cold-start it (same as /agent start) — ack before that starts.
                let modeWizardDeferred = try? await client.createInteractionResponse(
                    id: payload.id,
                    token: payload.token,
                    payload: .deferredChannelMessageWithSource(isEphemeral: true)
                )
                guard modeWizardDeferred != nil else { return }
                let ownerId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
                let cwd = storeRow?.cwd ?? stubCwd
                let permMode = storeRow?.permMode ?? regRow?.permMode ?? "default"
                let optionSource = await loadWizardOptionSource()
                // G-P1-06: same favorites confinement as /agent start (reconfigure rarely uses folder).
                let globalConfig = try? await ConfigStore.shared.load()
                let favorites = globalConfig?.favorites ?? []
                // C3: registered permission profile names for the perm step's quick-select.
                let profileNames = Array((globalConfig?.profiles ?? [:]).keys)
                let browser = DirectoryBrowser(
                    allowedRoots: browseRoots(fromFavorites: favorites),
                    startPath: cwd,
                    nativePanel: false
                )
                let wizard = ChannelWizard(
                    guildId: guildId,
                    channelId: channelId,
                    ownerId: ownerId,
                    browser: browser,
                    options: optionSource,
                    // Omit model/effort → seed NEW backend defaults; carry cwd/perm/profile from binding.
                    entry: WizardEntry(backend: backend, cwd: cwd, permMode: permMode, profile: storeRow?.permissionProfile),
                    profileNames: profileNames
                )
                await WizardRegistry.shared.put(wizard, channelId: channelId)
                let (embeds, components) = discordPayload(from: wizard.render())
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(embeds: embeds, components: components)
                )
            case "perm":
                // G-P1-04 / TS switchPerm: known config.profiles name → profile + bundled
                // permissionMode; otherwise raw permMode (existing permissionProfile kept).
                guard let value = try? sub.requireOption(named: "value").requireString(), !value.isEmpty else {
                    try await respondEphemeral(payload, I18n.t("cmd.perm.missingValue"))
                    return
                }
                let profiles = (try? await ConfigStore.shared.load())?.profiles ?? [:]
                let resolved = resolveModePerm(value: value, profiles: profiles)
                let permResult = await life.updateBinding(
                    channelId: channelId, patch: resolved.bindingPatch,
                    actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
                )
                try await respondEphemeral(
                    payload,
                    permResult == .ok ? I18n.t("cmd.perm.switched", ["perm": resolved.display]) : noSession
                )
            default:
                try await respondEphemeral(payload, I18n.t("cmd.unknownSubcommand", ["name": sub.name]))
            }

        case "agent":
            guard let sub = cmd.options?.first else { return }
            switch sub.name {
            case "start":
                // Starting a new wizard on an occupied channel would replace its persisted
                // owner. Only the current owner or a server admin may perform that transfer.
                if let owner = await SessionStore.shared.binding(channelId: channelId)?.ownerId,
                   !owner.isEmpty,
                   owner != actorId,
                   decision.tier != .admin
                {
                    try await respondEphemeral(payload, I18n.t("session.ownerOrAdminRequired"))
                    return
                }
                // The live provider catalog can cold-start a local CLI. Acknowledge before
                // that work so Discord's three-second interaction token never expires.
                let deferred = try? await client.createInteractionResponse(
                    id: payload.id,
                    token: payload.token,
                    payload: .deferredChannelMessageWithSource(isEphemeral: true)
                )
                guard deferred != nil else { return }
                try await presentAgentStartWizard(
                    client: client, payload: payload, guildId: guildId, channelId: channelId,
                    actorId: actorId, stubCwd: stubCwd
                )
            case "close":
                // Stopping the live bridge can be slow; ack before it starts (same reason as /clear).
                let closeDeferred = try? await client.createInteractionResponse(
                    id: payload.id,
                    token: payload.token,
                    payload: .deferredChannelMessageWithSource(isEphemeral: true)
                )
                guard closeDeferred != nil else { return }
                // WO-7 (design_orchestration_module_agents.md, R8): stopChannel below hard-removes
                // the store binding, so the orchestration role must be captured before that call —
                // otherwise there is no way to tell a lead ("orchestrator") channel close from an
                // ordinary one by the time cleanup runs.
                let priorSession = await SessionStore.shared.binding(channelId: channelId)
                // W14: real stop (backend + unbind) — was unbind-only and leaked processes.
                _ = await life.stopChannel(
                    channelId: channelId, actorId: actorId, guildId: guildId, roleTier: tier
                )
                // Reply BEFORE delete so the ephemeral ack lands (TS slashCommands.close).
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("cmd.close.done"))
                )
                // G-P0-04: A4D dedicated session channel best-effort delete (never control/status/category).
                if let realGuildId = payload.guild_id?.rawValue {
                    let provisioner = resolveGuildProvisioner(client: client, guildId: realGuildId)
                    let serverConfig = await ConfigStore.shared.loadServerConfig(guildId: realGuildId)
                    // WO-7/R8: closing the lead channel tears down its whole set (module channels +
                    // category) first, then the existing single-channel delete below removes the
                    // lead channel itself — both stages run after the reply above.
                    if priorSession?.orchestrationRole == "orchestrator" {
                        _ = await life.closeOrchestrationSet(
                            orchestratorChannelId: channelId,
                            guildId: realGuildId,
                            actorId: actorId,
                            roleTier: tier,
                            provisioner: provisioner
                        )
                        await OrchestrationHost.shared.resetRoundTrips(orchestratorChannelId: channelId)
                    }
                    var chName: String?
                    var parentId: String?
                    if let ch = try? await client.getChannel(id: ChannelSnowflake(channelId)).decode() {
                        chName = ch.name
                        parentId = ch.parent_id?.rawValue
                    }
                    await deleteSessionChannel(
                        provisioner: provisioner,
                        channelId: channelId,
                        channelName: chName,
                        parentId: parentId,
                        serverChannels: serverConfig?.channels,
                        orchestrationCategoryIds: Set(serverConfig?.orchestration?.values.map(\.categoryId) ?? [])
                    )
                }
            case "resume":
                // G-P1-05: store→registry re-bind + status intro + soft ensure (no full turn).
                if let session = await life.resumeBinding(channelId: channelId) {
                    // Ack first (TS cmd.resume.rebound) so soft ensure latency never blocks Discord.
                    try await respondEphemeral(payload, I18n.t("cmd.resume.rebound"))
                    await postResumeChannelIntro(
                        client: client,
                        channelId: channelId,
                        session: session
                    )
                    // Soft reconnect when a backend id exists; otherwise next message starts fresh.
                    if session.backendSessionId != nil {
                        _ = await life.softEnsureLive(channelId: channelId)
                    }
                } else {
                    try await respondEphemeral(payload, I18n.t("cmd.resume.none"))
                }
            case "stats":
                let lines = formatStatsLines(bindings: await life.listActiveBindings())
                let count = lines.count == 1 && lines[0] == "(none)" ? 0 : lines.count
                let meta = await SessionStore.shared.getUpdateMeta()
                let dismissed = meta.dismissedVersion.map { I18n.t("stats.dismissedSuffix", ["version": $0]) } ?? ""
                let activeHeading = I18n.t("stats.active", ["n": "\(count)"])
                let content =
                    "**\(activeHeading)**\n" + lines.joined(separator: "\n")
                    + I18n.t("stats.versionLine", ["version": readAppVersion(), "dismissed": dismissed])
                // W11-g + G-P1-09: Claude OAuth + Grok weekly + Codex rate-limit embeds.
                var embeds: [Embed] = []
                let claudeUsage = await ClaudeUsageService.shared.getUsage()
                if let spec = buildUsageEmbed(usage: claudeUsage, ctxUsage: nil) {
                    embeds.append(discordEmbed(from: spec))
                }
                let grokUsage = await GrokUsageService.shared.getUsage()
                if let spec = buildUsageEmbed(usage: grokUsage, ctxUsage: nil) {
                    embeds.append(discordEmbed(from: spec))
                }
                let codexUsage = await CodexUsageService.shared.getUsage()
                if let spec = buildUsageEmbed(
                    usage: codexUsage,
                    ctxUsage: nil,
                    extras: UsageEmbedExtras(title: I18n.t("usage.title.codex"))
                ) {
                    embeds.append(discordEmbed(from: spec))
                }
                if embeds.isEmpty {
                    try await respondEphemeral(payload, content)
                } else {
                    try await respondEphemeral(payload, content, embeds: embeds)
                }
            default:
                try await respondEphemeral(payload, I18n.t("cmd.unknownSubcommand", ["name": sub.name]))
            }

        case "setup":
            // W16-c: A4D channel structure (control + status + sessions category). Admin only.
            // alreadyDone: skip create when all four stored ids still exist.
            guard let realGuildId = payload.guild_id?.rawValue else {
                try await respondEphemeral(payload, I18n.t("auth.denied", ["reason": "DM"]))
                return
            }
            let provisioner = resolveGuildProvisioner(client: client, guildId: realGuildId)
            let store = ConfigStore.shared
            let existing = await store.loadServerConfig(guildId: realGuildId)?.channels
            if await isGuildChannelsAlreadyDone(existing: existing, provisioner: provisioner) {
                if setupBootstrap {
                    await registerSetupBootstrapAdmin(guildId: realGuildId, userId: actorId)
                }
                let control = existing?.controlChannelId ?? ""
                try await respondEphemeral(
                    payload,
                    I18n.t("cmd.setup.alreadyDone", ["control": "<#\(control)>"])
                )
                return
            }
            // Creating the channel structure is a handful of sequential Discord API calls;
            // ack before they start (same reason as /clear/doc — Discord rate limiting can
            // easily push this past the 3s window).
            let setupDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard setupDeferred != nil else { return }
            do {
                let channels = try await ensureGuildChannels(provisioner: provisioner, configStore: store)
                if setupBootstrap {
                    await registerSetupBootstrapAdmin(guildId: realGuildId, userId: actorId)
                }
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("cmd.setup.done", ["control": "<#\(channels.controlChannelId)>"]))
                )
                // H6: offer the Chromium install prompt in the fresh control channel.
                await maybePromptRenderSetup(client: client, channelId: channels.controlChannelId)
            } catch {
                log.error("/setup failed guild=\(realGuildId): \(error)")
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("cmd.setup.unavailable"))
                )
            }

        case "config":
            // W16-b: ephemeral settings panel (role tiers + defaults). Admin only.
            guard let realGuildId = payload.guild_id?.rawValue else {
                try await respondEphemeral(payload, I18n.t("auth.denied", ["reason": "DM"]))
                return
            }
            guard isDiscordAdministrator else {
                try await respondEphemeral(payload, I18n.t("cmd.config.denied"))
                return
            }
            let store = ConfigStore.shared
            let global: AppConfig
            do {
                global = try await store.load()
            } catch {
                try await respondEphemeral(
                    payload,
                    I18n.t("config.loadFailed", ["error": "\(error)"])
                )
                return
            }
            let server = await store.loadServerConfig(guildId: realGuildId)
            let defaults = configPanelDefaults(global: global, server: server)
            // File-facing mode may be grok-build; select options use Backend raw values.
            var panelDefaults = defaults
            if panelDefaults.backend == "grok-build" {
                panelDefaults.backend = Backend.grok.rawValue
            }
            let ownerId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
            let backends = Backend.allCases.map(\.rawValue)
            // Catalog snapshot for model/effort/perm selects. For Claude/.custom this probes the
            // sidecar (ClaudeCatalog.models → ensureClient) and can cold-start it exactly like
            // /agent start's wizard warm-up — ack before that starts.
            let configDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard configDeferred != nil else { return }
            let backendEnum = Backend(rawValue: panelDefaults.backend) ?? .claude
            let catalog = providerCatalog(for: backendEnum)
            let configuredModel = backendEnum == .codex
                ? global.defaults.codexModel
                : global.defaults.claudeModel
            var models = await catalog.models(configured: configuredModel.isEmpty ? nil : configuredModel)
            if !panelDefaults.model.isEmpty {
                // Preselect the row that names this model (config.json's bare `opus` → the SDK's
                // `opus[1m]` row); only a genuinely unknown id gets a row minted for it.
                if let same = modelRowMatching(panelDefaults.model, in: models) {
                    panelDefaults.model = same.value
                } else {
                    models.insert(
                        ModelChoice(value: panelDefaults.model, label: modelDisplayText(panelDefaults.model)),
                        at: 0
                    )
                }
            }
            if models.isEmpty {
                // Degraded only (sidecar down AND nothing configured): the alias is all we have.
                let v = panelDefaults.model.isEmpty ? "opus" : panelDefaults.model
                models = [ModelChoice(value: v, label: v)]
            }
            let modelLevels = models.first(where: { $0.value == panelDefaults.model })?.supportedEffortLevels
            var efforts = catalog.effortChoices(modelLevels: modelLevels)
            if !panelDefaults.effort.isEmpty,
               !efforts.contains(where: { $0.value == panelDefaults.effort }) {
                efforts.insert(ModelChoice(value: panelDefaults.effort, label: panelDefaults.effort), at: 0)
            }
            if efforts.isEmpty {
                let e = panelDefaults.effort.isEmpty ? "high" : panelDefaults.effort
                efforts = [ModelChoice(value: e, label: e)]
            }
            let permModes = await catalog.permissionChoices()
            let panel = ConfigPanel(options: ConfigPanelOptions(
                guildId: realGuildId,
                ownerId: ownerId,
                configStore: store,
                defaults: panelDefaults,
                backends: backends,
                isKnownBackend: { Backend(rawValue: $0) != nil },
                models: models,
                efforts: efforts,
                permModes: permModes.isEmpty
                    ? [
                        .init(value: "default", label: "default"),
                        .init(value: "acceptEdits", label: "acceptEdits"),
                        .init(value: "plan", label: "plan"),
                    ]
                    : permModes
            ))
            await ConfigPanelRegistry.shared.put(panel, guildId: realGuildId, channelId: channelId)
            let view = panel.render()
            let (embeds, roleRows, defaultRows) = discordPayload(from: view)
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(
                    content: I18n.t("cmd.config.opened"),
                    embeds: embeds,
                    components: roleRows
                )
            )
            if !defaultRows.isEmpty {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(components: defaultRows, flags: [.ephemeral])
                )
            }

        case "doc":
            // W16-d: share markdown into a 📄 thread (drive tier). Needs a bound session for cwd.
            guard let docPath = try? cmd.requireOption(named: "path").requireString(), !docPath.isEmpty else {
                try await respondEphemeral(payload, I18n.t("cmd.doc.missingPath"))
                return
            }
            let regBound = await SessionRegistry.shared.binding(channelId: channelId) != nil
            let storeSession = await SessionStore.shared.binding(channelId: channelId)
            let hasBinding = regBound || (storeSession.map { !$0.archived } ?? false)
            guard hasBinding else {
                try await respondEphemeral(payload, I18n.t("router.noSession"))
                return
            }
            // Headless Chromium rendering can be slow; ack before it starts (same reason as /clear).
            let docDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard docDeferred != nil else { return }
            do {
                let res = try await postDocumentShare(client: client, channelId: channelId, path: docPath)
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: formatDocShareReply(path: docPath, result: res))
                )
            } catch {
                log.error("/doc failed channel=\(channelId) code=document_share_error")
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("doc.error.shareFailed"))
                )
            }

        case "update":
            // W16-h: admin version check; if available, show Yes/No prompt ephemerally.
            guard let updater = await AutoUpdaterRegistry.shared.get() else {
                try await respondEphemeral(payload, I18n.t("update.notReady"))
                return
            }
            // checkNow fetches the version registry over the network; ack before it starts
            // (same reason as /clear/doc — a slow remote fetch must not eat the 3s window).
            let updateDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard updateDeferred != nil else { return }
            // post:false — we reply here with embed+buttons instead of fanning out to control channels.
            let result = await updater.checkNow(post: false)
            let text = formatUpdateCheckReply(result)
            if result.kind == .available, let latest = result.latestVersion {
                let (embedSpec, rows) = buildUpdatePrompt(version: latest, currentVersion: result.currentVersion)
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: text,
                        embeds: [discordEmbed(from: embedSpec)],
                        components: discordActionRows(from: rows)
                    )
                )
            } else {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: text)
                )
            }

        case "orchestration":
            // WO-10 (R10/D15/D16): show the start spec card only — no side effects until [시작].
            // Project-scoped install: session channels only, `.claude/` local to the bound cwd
            // (design_orchestration_project_scoped_command.md §4.8). Filesystem work + a session
            // restart can take a moment — defer ephemeral first (3s window), as the old install did.
            let orchDeferred = try? await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard orchDeferred != nil else { return }
            let orchServerConfig = await ConfigStore.shared.loadServerConfig(guildId: guildId)
            if isControlPlaneChannel(
                channelId: channelId,
                serverChannels: orchServerConfig?.channels,
                redmineReportChannelId: orchServerConfig?.redmine?.reportChannelId
            ) {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("orchestration.wrongChannel"))
                )
                return
            }
            guard let orchBinding = await SessionStore.shared.binding(channelId: channelId) else {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: noSession)
                )
                return
            }
            // D16: the card only ever offers Claude models — reject a non-Claude-bound lead
            // channel up front (2-2 scope: Claude-only; this guard didn't exist before WO-10).
            guard orchestrationCardAllowed(backend: orchBinding.backend) else {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("orchestration.wizard.backendNotClaude"))
                )
                return
            }
            // R10/D15: seed leads from the current binding, modules from the saved set (falling
            // back to the lead values) — the card always opens, but re-runs reuse last picks.
            let orchOptionSource = await loadWizardOptionSource()
            let orchExistingSet = orchServerConfig?.orchestration?[channelId]
            let orchestratorModel = orchBinding.model ?? providerDefaultModelSelection
            let orchestratorEffort = orchBinding.effort ?? orchOptionSource.defaultEffort(for: .claude)
            let orchWizard = OrchestrationWizard(
                options: orchOptionSource,
                initial: OrchestrationSpec(
                    orchestratorModel: orchestratorModel,
                    orchestratorEffort: orchestratorEffort,
                    moduleModel: orchExistingSet?.moduleModel ?? orchestratorModel,
                    moduleEffort: orchExistingSet?.moduleEffort ?? orchestratorEffort
                )
            )
            await OrchestrationWizardRegistry.shared.put(orchWizard, channelId: channelId)
            let (orchEmbeds, orchComponents) = discordPayload(from: orchWizard.render())
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(embeds: orchEmbeds, components: orchComponents)
            )

        case "redmine":
            // WO-12: opens the 3-field config modal. showModal is this interaction's only ack —
            // must NOT be preceded by any defer (8장/dir:create precedent, DabMain.swift:1600).
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .modal(.init(
                    custom_id: "redmine:config",
                    title: I18n.t("redmine.config.title"),
                    textInputs: [
                        .init(
                            custom_id: "url",
                            style: .short,
                            label: I18n.t("redmine.config.urlLabel"),
                            required: true,
                            placeholder: "https://redmine.example.com"
                        ),
                        .init(
                            custom_id: "apiKey",
                            style: .short,
                            label: I18n.t("redmine.config.apiKeyLabel"),
                            required: true
                        ),
                        .init(
                            custom_id: "project",
                            style: .short,
                            label: I18n.t("redmine.config.projectLabel"),
                            required: false
                        ),
                    ]
                ))
            )

        case "command":
            // WO-7: the picked command opens a paragraph modal for the prompt; the composed
            // `"/{command}\n{prompt}"` then rides the ordinary turn pipeline at submit.
            // C7: showModal is this interaction's ONLY ack — no defer above it, and no backend or
            // store lookup either (§3-5-4, dir:create precedent at DabMain.swift:2163). The
            // "still available?" check (C8) waits for the submit, where a defer IS allowed.
            let runValue = (try? cmd.requireOption(named: "command").requireString()) ?? ""
            switch slashRunOpenDecision(commandValue: runValue) {
            case .noSession:
                try await respondEphemeral(payload, I18n.t("run.noSession"))
            case .nameTooLong:
                try await respondEphemeral(payload, I18n.t("run.nameTooLong", ["command": runValue]))
            case .openModal(let runCustomId, let runCommand):
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .modal(.init(
                        custom_id: runCustomId,
                        title: slashRunModalTitle(command: runCommand),
                        textInputs: [
                            .init(
                                custom_id: "prompt",
                                style: .paragraph,
                                label: I18n.t("run.modal.label"),
                                required: false,
                                placeholder: I18n.t("run.modal.placeholder")
                            ),
                        ]
                    ))
                )
            }

        case "command-list":
            // WO-10: the whole backend catalog in one ephemeral embed, because `/command`'s picker
            // is capped at 25 by Discord and the built-ins sit well past that (`compact` 62nd).
            //
            // A slash handler MAY defer — autocomplete may not (C17) — so unlike the picker this
            // path is allowed to wait on the backend, and it warms the very cache the picker reads.
            let helpDeferred = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
            guard helpDeferred != nil else { return }
            // Unbound → claude, exactly like handleAutocomplete's fallback. Never a silent guess:
            // the body names the backend it listed.
            let helpBackend = await SessionRegistry.shared.binding(channelId: channelId)?.backend ?? .claude
            // ORDER MATTERS — warm BEFORE reading, never the other way round.
            // `autocompleteSlashCommands` claims the channel's fill slot itself
            // (`AutocompleteSlashCatalogCache.commands` → `filling.insert`), so a read placed first
            // makes the warm-up below a no-op that returns instantly, and a channel whose session
            // has not spawned yet then stays stuck on "still loading" for every invocation.
            // Reversing these two lines is the natural-looking refactor that breaks it; the fix is
            // pinned by `warmingBeforeReadingFillsTheList` / `readingBeforeWarmingLosesTheFillSlot`.
            await warmSlashCatalog(channelId: channelId, backend: helpBackend)
            let helpCommands = autocompleteSlashCommands(channelId: channelId, backend: helpBackend)
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id, token: payload.token,
                payload: .init(embeds: [Embed(
                    description: slashHelpDescription(backend: helpBackend, commands: helpCommands)
                )])
            )

        case "redmine-issue-select":
            // WO-13: R9 dropdown — same status/assignee filter as the poller (R5), but `since`
            // is nil (D5, WO-5) since this command has no "last checked" concept.
            guard let redmine = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine else {
                try await respondEphemeral(payload, I18n.t("redmine.issueSelect.needsSetup"))
                return
            }
            do {
                let apiKey = try RedmineApiKeyCipher.decrypt(redmine.apiKeyEncrypted)
                let redmineClient = RedmineClient()
                let issues = try await redmineClient.fetchIssues(
                    baseURL: redmine.url,
                    apiKey: apiKey,
                    projectId: redmine.projectId
                )
                let statuses = try await redmineClient.fetchStatuses(baseURL: redmine.url, apiKey: apiKey)
                // Same status policy as the 5-minute poller: 신규 | New | 진행 | Doing (+ bilingual forms).
                let resolvedStatusIds = RedmineStatusResolver.resolveTargetIds(statuses: statuses)
                let matched = RedmineIssueFilter.match(issues: issues, resolvedStatusIds: resolvedStatusIds, since: nil)
                guard !matched.isEmpty else {
                    try await respondEphemeral(payload, I18n.t("redmine.issueSelect.empty"))
                    return
                }
                // WO-13b (9장 Q6): Discord select menus cap options at 25 — split into several
                // messages instead of silently truncating so every matched issue stays selectable.
                let chunks = RedmineIssueChunker.chunk(matched)
                let firstBatch: (index: Int, total: Int)? = chunks.count > 1 ? (1, chunks.count) : nil
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("redmine.issueSelect.prompt"),
                        flags: [.ephemeral],
                        components: [Interaction.ActionRow(components: [
                            .stringSelect(redmineIssueSelectMenu(for: chunks[0], batch: firstBatch)),
                        ])]
                    ))
                )
                // NOT ephemeral on the overflow pages (unlike the first page above, which acks via
                // createInteractionResponse and is unaffected) — DiscordBM's `ExecuteWebhook.validate()`
                // rejects `.ephemeral` in `createFollowupMessage` client-side (found live; same issue
                // fixed in `handleRedmineConfigModal`/`handleRedmineIssueComponent`).
                for (offset, chunk) in chunks.dropFirst().enumerated() {
                    let menu = redmineIssueSelectMenu(for: chunk, batch: (offset + 2, chunks.count))
                    _ = try? await client.createFollowupMessage(
                        appId: payload.application_id,
                        token: payload.token,
                        payload: .init(
                            content: I18n.t("redmine.issueSelect.prompt"),
                            components: [Interaction.ActionRow(components: [.stringSelect(menu)])]
                        )
                    )
                }
            } catch {
                try await respondEphemeral(payload, I18n.t("redmine.issueSelect.fetchFailed", ["error": "\(error)"]))
            }

        default:
            return
        }
    }

    /// One select-menu message-worth of chunked issue options (WO-13b, 9장 Q6). `batch` is nil for
    /// the common case (<=25 matched issues, single dropdown, placeholder unchanged from WO-13) and
    /// `(index, total)` when the caller has split the results across multiple messages.
    private func redmineIssueSelectMenu(
        for issues: [RedmineIssueDTO],
        batch: (index: Int, total: Int)?
    ) -> Interaction.ActionRow.StringSelectMenu {
        let options = issues.map {
            Interaction.ActionRow.StringSelectMenu.Option(label: "#\($0.id) \($0.subject)", value: String($0.id))
        }
        let placeholder = batch.map {
            I18n.t("redmine.issueSelect.placeholder.paged", ["index": "\($0.index)", "total": "\($0.total)"])
        } ?? I18n.t("redmine.issueSelect.placeholder.single")
        return Interaction.ActionRow.StringSelectMenu(
            custom_id: "redmine:issue-select",
            options: options,
            placeholder: placeholder
        )
    }

    /// First-admin bootstrap follow-up: commits the /setup actor as this guild's first admin.
    /// Called only when `setupBootstrap` fired (guild had no admin roles/users yet). Best-effort —
    /// a write failure is logged but does not block the /setup success reply (it already ran).
    private func registerSetupBootstrapAdmin(guildId: String, userId: String) async {
        do {
            try await ConfigStore.shared.addServerAdminUserId(guildId: guildId, userId: userId)
        } catch {
            log.warn("setup bootstrap admin registration failed guild=\(guildId) user=\(userId): \(error)")
        }
    }

    /// W16-h: approve → install.sh + restart; dismiss → persist dismissedVersion. Admin-only.
    private func handleUpdateComponent(
        _ payload: Interaction,
        action: UpdateAction,
        version: String
    ) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? "dm"
        let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(
                userId: actorId,
                roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                action: .admin,
                guildId: payload.guild_id?.rawValue,
                channelId: channelId,
                isAdministrator: payload.member?.permissions?.contains(.administrator) ?? false
            ),
            projectAuth: projectAuth
        )
        guard decision.allowed else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(content: UpdateLabels.denied, flags: [.ephemeral]))
            )
            return
        }
        // Ack first (deferUpdate keeps the prompt message), then drive the updater.
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )
        guard let updater = await AutoUpdaterRegistry.shared.get() else { return }
        let decidedRow = discordActionRows(from: [buildUpdateDecidedRow(action: action)])
        let ctx = UpdateDecisionCtx(
            actorId: actorId,
            guildId: guildId,
            channelId: channelId,
            applicationId: payload.application_id.rawValue,
            interactionToken: payload.token,
            ack: { [client] text in
                // Public channel followup — update status is operator-visible (not ephemeral).
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: text)
                )
            },
            disableButtons: { [client] in
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(components: decidedRow)
                )
            }
        )
        switch action {
        case .approve:
            await updater.approve(version, ctx: ctx)
        case .dismiss:
            await updater.dismiss(version, ctx: ctx)
        }
    }

    /// Turn-timeout retry prompt Yes/No: only disables the buttons (+ confirm gets a follow-up
    /// notice). No auth gate (anyone may click), no auto-resend — the channel's session binding
    /// was already invalidated by `DabSessionBridge.finishTurn` when this prompt was posted, so
    /// the user's next message alone starts a fresh session.
    private func handleTurnTimeoutComponent(
        _ payload: Interaction,
        action: TurnTimeoutAction
    ) async throws {
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )
        let decidedRow = discordActionRows(from: [buildTurnTimeoutDecidedRow(action: action)])
        _ = try? await client.updateOriginalInteractionResponse(
            appId: payload.application_id,
            token: payload.token,
            payload: .init(components: decidedRow)
        )
        if action == .confirm, let channelId = payload.channel_id {
            _ = await createMessageWithRetry(
                client: client,
                channelId: channelId,
                payload: .init(content: I18n.t("turnTimeout.newSessionReady"))
            )
        }
    }

    /// W14-b: guild channel delete → same hard-stop path as `/stop` (skip DMs; no binding → no-op).
    func onChannelDelete(_ payload: DiscordChannel) async throws {
        // Guild channels only (DM channels host no session) — TS client.ts isDMBased skip.
        guard let guildId = payload.guild_id else { return }
        let channelId = payload.id.rawValue
        _ = await SessionLifecycle.shared.stopChannel(
            channelId: channelId,
            actorId: "system",
            guildId: guildId.rawValue,
            roleTier: "execute"
        )
        log.info("channelDelete → stop channel=\(channelId) guild=\(guildId.rawValue)")
    }

    private func respondEphemeral(
        _ payload: Interaction,
        _ text: String,
        embeds: [Embed]? = nil
    ) async throws {
        _ = try await client.createInteractionResponse(
            id: payload.id,
            token: payload.token,
            payload: .channelMessageWithSource(.init(content: text, embeds: embeds, flags: [.ephemeral]))
        )
    }

    /// G-P1-03: `/model` · `/effort` autocomplete from providerCatalog, plus `/run` (WO-6) from the
    /// channel's backend command catalog — all keyed off the channel binding backend, else claude.
    /// Best-effort respond — Discord's ~3s window has no defer.
    private func handleAutocomplete(_ payload: Interaction) async {
        let empty: Payloads.InteractionResponse = .autocompleteResult(.init(choices: []))
        guard let cmd = try? payload.data?.requireApplicationCommand() else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token, payload: empty
            )
            return
        }
        let channelId = payload.channel_id?.rawValue ?? ""
        let query = focusedAutocompleteQuery(cmd)
        let binding = await SessionRegistry.shared.binding(channelId: channelId)
        // Channel binding backend wins; unbound → claude (TS-ish default vocabulary).
        let backend = binding?.backend ?? .claude
        let catalog = providerCatalog(for: backend)

        let suggestions: [AutocompleteChoice]
        // Autocomplete carries the prefixed name too — route on the bare one.
        switch bareCommandName(cmd.name) {
        case "model":
            let models = await autocompleteModels(backend: backend, catalog: catalog)
            suggestions = filterAutocompleteChoices(models, query: query)
        case "effort":
            let models = await autocompleteModels(backend: backend, catalog: catalog)
            let modelId = binding?.model ?? models.first?.value
            let levels = modelId.flatMap { id in
                models.first(where: { $0.value == id })?.supportedEffortLevels
            }
            let efforts = catalog.runtimeEffortChoices(modelLevels: levels)
            suggestions = filterAutocompleteChoices(efforts, query: query)
        case "command":
            // C17: cached read only — this path must never await the backend inside the ~3s budget.
            suggestions = slashCatalogSuggestions(channelId: channelId, backend: backend, query: query)
        default:
            suggestions = []
        }

        let choices = suggestions.map {
            ApplicationCommand.Option.Choice(name: $0.name, value: .string($0.value))
        }
        _ = try? await client.createInteractionResponse(
            id: payload.id,
            token: payload.token,
            payload: .autocompleteResult(.init(choices: choices))
        )
    }

    /// Interactions usually carry the computed Administrator permission. The cache additionally
    /// preserves the guild-owner bypass when that field is unavailable or Discord omits it.
    private func hasDiscordAdministrator(
        _ payload: Interaction,
        guildId: String?,
        userId: String
    ) async -> Bool {
        if payload.member?.permissions?.contains(.administrator) == true {
            return true
        }
        guard let guildId else { return false }
        return await GuildAdminCache.shared.isAdministrator(
            guildId: guildId,
            userId: userId,
            roleIds: payload.member?.roles.map(\.rawValue) ?? []
        )
    }

    /// W16-b: drive the open `/config` panel. Owner-gated. Roles batch until Save;
    /// backend/model/effort/permMode/locale auto-save; 🔔 notifications sub-panel.
    private func handleConfigComponent(_ payload: Interaction, comp: Interaction.MessageComponent) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue
        let clicker = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        guard let guildId else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            return
        }
        guard await hasDiscordAdministrator(payload, guildId: guildId, userId: clicker) else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("cmd.config.denied"),
                    flags: [.ephemeral]
                ))
            )
            return
        }
        guard let panel = await ConfigPanelRegistry.shared.get(guildId: guildId, channelId: channelId),
              panel.ownerId == clicker
        else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            return
        }

        let input = ConfigPanelInput(
            id: comp.custom_id,
            value: comp.values?.first,
            values: comp.values
        )
        let result = await panel.handle(input)
        switch result {
        case .saved(let summary):
            await ConfigPanelRegistry.shared.remove(guildId: guildId, channelId: channelId)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(content: summary, flags: [.ephemeral]))
            )
        case .autosaved(let notice):
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(content: notice, flags: [.ephemeral]))
            )
        case .notifPanel(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    embeds: embeds,
                    flags: [.ephemeral],
                    components: rows
                ))
            )
        case .notifUpdated(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: rows))
            )
        case .renderPanel(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    embeds: embeds,
                    flags: [.ephemeral],
                    components: rows
                ))
            )
        case .accessPanel(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    embeds: embeds,
                    flags: [.ephemeral],
                    components: rows
                ))
            )
        case .accessUpdated(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: rows))
            )
        case .renderUpdated(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: rows))
            )
        case .renderInstall:
            // H7: reuses the same install flow as the render-setup:install button (TS
            // components.ts:78-83 calls the identical `handleRenderSetup(..., 'install')`
            // for both) — progress bar + i18n done/failed, edited into this same message.
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            await performRenderSetupInstall(client: client, appId: payload.application_id, token: payload.token)
        case .pending, .ignored:
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
        }
    }

    /// W11-b2 residual: dir:resume + resume.* flow (owner-gated). Binds current channel (A4D create residual).
    private func handleResumeComponent(_ payload: Interaction, comp: Interaction.MessageComponent) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? ""
        let clicker = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""

        if comp.custom_id == "dir:resume" {
            guard let wizard = await WizardRegistry.shared.get(channelId: channelId) else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("wizard.sessionMissing"),
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            guard wizard.ownerId == clicker else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("wizard.notOwner"),
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            let flow = buildResumeWizard(
                guildId: guildId,
                channelId: channelId,
                ownerId: clicker,
                cwd: wizard.browserCwd(),
                defaultBackend: wizard.current().backend
            )
            await ResumeWizardRegistry.shared.put(flow, channelId: channelId)
            let (embeds, components) = discordPayload(from: flow.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: components))
            )
            return
        }

        // resume.* or cancel while flow is active
        guard let flow = await ResumeWizardRegistry.shared.get(channelId: channelId) else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("wizard.resumeSessionMissing"),
                    flags: [.ephemeral]
                ))
            )
            return
        }
        guard flow.ownerId == clicker else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("wizard.notOwner"),
                    flags: [.ephemeral]
                ))
            )
            return
        }

        // A queued resume action can wait behind another click's slow work (e.g.
        // "resume.backend.next" cold-starting a backend sidecar to list sessions) — defer it
        // before queueing so Discord's 3-second acknowledgement deadline is never at risk, no
        // matter which custom_id is clicked (mirrors handleWizardComponent, DabMain.swift:1653-1658).
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )

        // Same-channel resume interactions can now arrive nearly simultaneously (the gateway
        // event loop dispatches messageCreate/interactionCreate per channel in parallel,
        // docs/gateway-event-loop-serialized.md §8) — queue so two clicks never interleave
        // ResumeWizard.handle/render (mirrors WizardRegistry.enqueue, DabMain.swift:1646).
        await ResumeWizardRegistry.shared.enqueue(channelId: channelId) {
            // A previously queued job on this channel may have completed/cancelled the flow
            // while this job waited its turn — re-fetch at execution time instead of trusting
            // the instance captured above (mirrors handleWizardComponent's WizardRegistry
            // re-fetch, DabMain.swift:1653).
            guard let flow = await ResumeWizardRegistry.shared.get(channelId: channelId) else { return }
            let value = comp.values?.first
            let step = await flow.handle(WizardInput(id: comp.custom_id, value: value))

            // Always deferred above, so the reply always follows up via
            // updateOriginalInteractionResponse (mirrors handleWizardComponent).
            func sendStepUpdate(content: String? = nil, embeds: [Embed] = [], components: [Interaction.ActionRow] = []) async {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(content: content, embeds: embeds, components: components)
                )
            }

            switch step {
            case .done:
                await ResumeWizardRegistry.shared.remove(channelId: channelId)
                await WizardRegistry.shared.remove(channelId: channelId)
                let bound = flow.sessionChannelId() ?? channelId
                await sendStepUpdate(content: I18n.t("resume.done", ["channel": "<#\(bound)>"]))
                // G-P1-05 / TS postResumeIntro: status embed on bound channel + soft ensure.
                if let session = await SessionStore.shared.binding(channelId: bound) {
                    await postResumeChannelIntro(
                        client: client,
                        channelId: bound,
                        session: session
                    )
                    if session.backendSessionId != nil {
                        _ = await SessionLifecycle.shared.softEnsureLive(channelId: bound)
                    }
                }
            case .empty:
                await ResumeWizardRegistry.shared.remove(channelId: channelId)
                await sendStepUpdate(content: I18n.t("resume.none"))
            case .cancelled:
                await ResumeWizardRegistry.shared.remove(channelId: channelId)
                await WizardRegistry.shared.remove(channelId: channelId)
                let (embeds, _) = discordPayload(from: flow.render())
                await sendStepUpdate(embeds: embeds)
            default:
                let (embeds, components) = discordPayload(from: flow.render())
                await sendStepUpdate(embeds: embeds, components: components)
            }
        }
    }

    /// Build ResumeWizard with live list/resume wiring (Claude sidecar · store best-effort).
    private func buildResumeWizard(
        guildId: String,
        channelId: String,
        ownerId: String,
        cwd: String,
        defaultBackend: Backend
    ) -> ResumeWizard {
        ResumeWizard(options: ResumeWizardOptions(
            guildId: guildId,
            channelId: channelId,
            ownerId: ownerId,
            cwd: cwd,
            backends: Backend.allCases,
            defaultBackend: defaultBackend,
            listResumableFor: { backend, dir in
                await listResumableForBackend(backend, cwd: dir)
            },
            resume: { params in
                try await bindResumedSession(params)
            }
        ))
    }

    /// WO-10: orchestration start-spec card routing (drop down 4 + [시작]/[취소]; no owner gate —
    /// the card is posted on the same ephemeral response as `/orchestration`, so only the
    /// invoker can even see or click it). Mirrors `handleResumeComponent`'s shape: defer →
    /// enqueue on the card's own registry → re-fetch the still-live instance inside the job →
    /// branch on the click.
    private func handleOrchestrationWizardComponent(_ payload: Interaction, comp: Interaction.MessageComponent) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        guard await OrchestrationWizardRegistry.shared.get(channelId: channelId) != nil else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("orchestration.wizard.sessionMissing"),
                    flags: [.ephemeral]
                ))
            )
            return
        }

        // A queued click can wait behind a slow one (orch:start runs install + indexing) — defer
        // before queueing so Discord's 3-second ack deadline is never at risk (mirrors
        // handleResumeComponent/handleWizardComponent, DabMain.swift:1802-1806/1959-1963).
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )

        await OrchestrationWizardRegistry.shared.enqueue(channelId: channelId) {
            // A previously queued job may have completed/cancelled the card while this job
            // waited its turn — re-fetch at execution time (mirrors handleWizardComponent's
            // WizardRegistry re-fetch, DabMain.swift:1972).
            guard let wizard = await OrchestrationWizardRegistry.shared.get(channelId: channelId) else { return }
            await wizard.handle(customId: comp.custom_id, values: comp.values ?? [])

            func sendCard() async {
                let (embeds, components) = discordPayload(from: wizard.render())
                _ = try? await self.client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(embeds: embeds, components: components)
                )
            }

            guard comp.custom_id == "orch:start" else {
                if comp.custom_id == "orch:cancel" {
                    await OrchestrationWizardRegistry.shared.remove(channelId: channelId)
                }
                await sendCard()
                return
            }
            guard let spec = wizard.confirmed else {
                // Defensive — `handle` always sets `confirmed` on `orch:start`. Re-render rather
                // than silently drop the click.
                await sendCard()
                return
            }
            await OrchestrationWizardRegistry.shared.remove(channelId: channelId)

            // WO-1's provisioning block, relocated behind [시작] so [취소]/an unopened card leaves
            // zero side effects (R10). Everything from here down used to run unconditionally right
            // after the old case "orchestration": guards.
            let guildId = payload.guild_id?.rawValue ?? ""
            let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
            guard let binding = await SessionStore.shared.binding(channelId: channelId) else {
                _ = try? await self.client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(content: I18n.t("router.noSession"))
                )
                return
            }
            let cwd = binding.cwd
            let backend = binding.backend
            // A re-run on a channel that is already a lead resets it to a fresh context below
            // (`enableOrchestrationMode`), so the module channels the previous run opened are
            // orphaned — the new lead has no memory of them. Tear them down here rather than
            // leaving dead channels under the category this run is about to reuse.
            let wasOrchestrator = binding.orchestrationRole == "orchestrator"

            // Persist the card's module spec into the set BEFORE provisioning, so a category
            // that's created fresh below is saved with the module spec already attached
            // (ensureOrchestrationCategory only ever reads/creates `categoryId`, never touches
            // moduleModel/moduleEffort — GuildChannels.swift:177).
            var nextServer = await ConfigStore.shared.loadServerConfig(guildId: guildId) ?? ServerConfig(guildId: guildId)
            var sets = nextServer.orchestration ?? [:]
            var set = sets[channelId] ?? OrchestrationSet(categoryId: "")
            set.moduleModel = spec.moduleModel
            set.moduleEffort = spec.moduleEffort
            sets[channelId] = set
            nextServer.orchestration = sets
            do {
                try await ConfigStore.shared.saveServerConfig(nextServer)
            } catch {
                log.warn("orchestration module spec save failed channel=\(channelId) err=\(error)")
            }

            // R10.1: install + role-persist must both succeed BEFORE the channel is touched
            // (renamed/moved into the category) — otherwise a failed install/enable leaves a
            // channel that *looks* like an orchestrator (name + category) but never actually
            // saved the role, and role-gated tools like send_order reject it forever.
            let report = OrchestrationInstaller.installProject(root: URL(fileURLWithPath: cwd))
            guard report.errors.isEmpty else {
                _ = try? await self.client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(content: I18n.t(
                        "orchestration.project.installFailed",
                        ["errors": report.errors.joined(separator: "\n")]
                    ))
                )
                return
            }
            let enabled = await SessionLifecycle.shared.enableOrchestrationMode(
                channelId: channelId, actorId: actorId, guildId: guildId, roleTier: "execute", defaultCwd: cwd
            )
            guard enabled else {
                _ = try? await self.client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(content: I18n.t("orchestration.project.installFailed", ["errors": "session reset failed"]))
                )
                return
            }

            let provisioner = resolveGuildProvisioner(client: self.client, guildId: guildId)
            // Before reusing the category, clear the previous run's module channels out of it
            // (see `wasOrchestrator` above). Runs after `enableOrchestrationMode` so a failed
            // reset leaves the old set intact instead of half-destroyed.
            let closedModules: Int
            if wasOrchestrator {
                closedModules = await SessionLifecycle.shared.stopOrchestrationModules(
                    orchestratorChannelId: channelId, guildId: guildId,
                    actorId: actorId, roleTier: "execute", provisioner: provisioner
                ).count
                // The restarted lead has issued no orders yet — carrying the old tally over would
                // refuse them against a cap the previous run filled.
                await OrchestrationHost.shared.resetRoundTrips(orchestratorChannelId: channelId)
            } else {
                closedModules = 0
            }
            let categorySummary: String
            do {
                let category = try await ensureOrchestrationCategory(
                    provisioner: provisioner,
                    configStore: ConfigStore.shared,
                    orchestratorChannelId: channelId,
                    folderPath: cwd
                )
                let channelName = orchestratorChannelName(cwd)
                do {
                    // The production adapter's setParent/renameChannel are themselves
                    // best-effort — they swallow the underlying Discord error and never throw
                    // (GuildChannelProvisionerAdapter.swift:82-102, WO-1 설계 §3단계). This
                    // do/catch is still the honest local tracking a test fake (or a future
                    // stricter adapter) can surface a real failure through — strictly more
                    // correct than `try?`, even though today's adapter never exercises the catch.
                    try await provisioner.setParent(id: channelId, parentId: category.id)
                    try await provisioner.renameChannel(id: channelId, name: channelName)
                    categorySummary = I18n.t(
                        "orchestration.category.moved",
                        ["category": category.name, "channel": channelName]
                    )
                } catch {
                    log.warn("orchestration channel move/rename failed channel=\(channelId) err=\(error)")
                    categorySummary = I18n.t("orchestration.category.failed")
                }
            } catch {
                log.warn("orchestration category provisioning failed channel=\(channelId) err=\(error)")
                categorySummary = I18n.t("orchestration.category.failed")
            }
            // R10 step 5: apply the card's lead model/effort to the lead binding itself (module
            // channels get their spec straight from the set when they're created on-demand, WO-2/4).
            let appliedResult = await SessionLifecycle.shared.updateBinding(
                channelId: channelId,
                patch: BindingPatch(model: spec.orchestratorModel, effort: spec.orchestratorEffort),
                actorId: actorId, guildId: guildId, roleTier: "execute", defaultCwd: cwd
            )

            var lines = [categorySummary, I18n.t("orchestration.project.installed", ["cwd": cwd])]
            if closedModules > 0 {
                lines.insert(I18n.t("orchestration.restart.modulesClosed", ["n": "\(closedModules)"]), at: 0)
            }
            if let backupPath = report.backupPath {
                lines.append(I18n.t("orchestration.project.backedUp", ["path": backupPath]))
            }
            // Category/install/index already succeeded and the session is live at this point —
            // a failed patch here means only the lead model/effort didn't take, not that the
            // whole command failed, so say exactly that instead of a blanket "applied" claim
            // (mirrors the /model /effort ok-vs-failed branching, DabMain.swift:721-726/751-754).
            lines.append(orchestrationAppliedSpecLine(appliedResult, spec: spec))
            lines.append(I18n.t("orchestration.project.freshContextNotice"))
            _ = try? await self.client.updateOriginalInteractionResponse(
                appId: payload.application_id, token: payload.token,
                payload: .init(content: lines.joined(separator: "\n"))
            )

            // Session's first turn must carry the role preamble (CLAUDE.md's role table,
            // OrchestrationProjectBundle.swift) so it knows it's the orchestrator — same
            // postPrompt/announceExtras pairing `order()` uses for a module channel's first turn.
            await runInjectedTurn(
                client: self.client, channelId: channelId, guildId: guildId, backend: backend,
                promptText: "[역할] 오케스트레이터", postPrompt: true, announceExtras: false,
                actorId: actorId, roleTier: "execute"
            )
        }
    }

    /// W11-b2: drive the channel's agent-start wizard from a select/button click (dir:* + choice steps).
    /// Owner gate: only the user who opened the wizard may advance it.
    /// dir:create / dir:manual open modals (showModal = ack). dir:panel defers then native pick.
    /// dir:resume is handled by `handleResumeComponent` (routed before this).
    private func handleWizardComponent(_ payload: Interaction, comp: Interaction.MessageComponent) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let clicker = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        guard let wizard = await WizardRegistry.shared.get(channelId: channelId) else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("wizard.sessionMissing"),
                    flags: [.ephemeral]
                ))
            )
            return
        }
        guard wizard.ownerId == clicker else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("wizard.notOwner"),
                    flags: [.ephemeral]
                ))
            )
            return
        }

        // Modal openers must NOT be preceded by deferUpdate (showModal is the ack).
        switch comp.custom_id {
        case "dir:create":
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .modal(.init(
                    custom_id: "dir:create",
                    title: I18n.t("dir.create.title"),
                    textInputs: [
                        .init(
                            custom_id: "name",
                            style: .short,
                            label: I18n.t("dir.create.label"),
                            required: true,
                            placeholder: I18n.t("dir.create.placeholder")
                        ),
                    ]
                ))
            )
            return
        case "dir:manual":
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .modal(.init(
                    custom_id: "dir:manual",
                    title: I18n.t("dir.manual.title"),
                    textInputs: [
                        .init(
                            custom_id: "path",
                            style: .short,
                            label: I18n.t("dir.manual.label"),
                            required: true,
                            placeholder: I18n.t("dir.manual.placeholder")
                        ),
                    ]
                ))
            )
            return
        case "dir:panel":
            try await handleFolderPanel(payload, wizard: wizard, channelId: channelId)
            return
        default:
            break
        }

        // A queued wizard action can wait behind another click or provision a channel. Defer it
        // before queueing so Discord's 3-second acknowledgement deadline is never at risk.
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )
        await WizardRegistry.shared.enqueue(channelId: channelId) {
            // M18: an earlier queued job on this channel (e.g. a prior click that already
            // completed/cancelled the wizard) may have removed it while this job waited its
            // turn — re-fetch from the registry at EXECUTION time instead of trusting the
            // instance captured when this job was dispatched (TS components.ts:243-249 does the
            // same `host.wizards.get(wKey)` fetch inside the queued job). Shadows the outer
            // `wizard` so everything below always drives the still-live instance.
            guard let wizard = await WizardRegistry.shared.get(channelId: channelId) else { return }
            let value = comp.values?.first
            let step = await wizard.handle(WizardInput(id: comp.custom_id, value: value))

            switch step {
            case .done:
                await WizardRegistry.shared.remove(channelId: channelId)
                if wizard.isReconfigure() {
                    // Backend-switch confirm: stop live session then rebind same channel (TS switchSession).
                    if let p = wizard.startParams {
                        let model = modelForPersistedBinding(p.model)
                        let effort = p.effort.isEmpty ? nil : p.effort
                        let perm = p.permMode.isEmpty ? nil : p.permMode
                        let ok = await SessionLifecycle.shared.reconfigureBinding(
                            channelId: p.channelId,
                            backend: p.backend,
                            model: model,
                            effort: effort,
                            permMode: perm,
                            actorId: clicker,
                            guildId: p.guildId.isEmpty ? (payload.guild_id?.rawValue ?? "") : p.guildId,
                            defaultCwd: p.cwd
                        )
                        // WO-9: the channel now answers to a DIFFERENT backend, and its old command
                        // list was dropped on sight (C26) — refill with the new one now so the next
                        // `/command` is not empty-handed. Detached: it opens a session (seconds).
                        if ok {
                            Task { await warmSlashCatalog(channelId: p.channelId, backend: p.backend) }
                        }
                        let text = ok
                            ? I18n.t("cmd.mode.switched", ["backend": p.backend.rawValue])
                            : I18n.t("wizard.recfg.noSession")
                        _ = try? await client.updateOriginalInteractionResponse(
                            appId: payload.application_id, token: payload.token,
                            payload: .init(content: text, embeds: [], components: [])
                        )
                        if ok, let ch = payload.channel_id {
                            let gid = p.guildId.isEmpty ? (payload.guild_id?.rawValue ?? "") : p.guildId
                            _ = await createMessageWithRetry(
                                client: client,
                                channelId: ch,
                                payload: .init(content:
                                    I18n.t("cmd.mode.freshContext", ["backend": p.backend.rawValue])
                                ),
                                onGone: {
                                    await SessionLifecycle.shared.stopChannel(
                                        channelId: p.channelId, actorId: "system", guildId: gid, roleTier: "execute"
                                    )
                                }
                            )
                        }
                    } else {
                        _ = try? await client.updateOriginalInteractionResponse(
                            appId: payload.application_id, token: payload.token,
                            payload: .init(content: I18n.t("wizard.recfg.noSelection"), embeds: [], components: [])
                        )
                    }
                } else if let p = wizard.startParams {
                    // W11-b2 A4D: create proj-<folder> under sessions category when /setup ran;
                    // bind registry+store to the new channel id (fallback: wizard channel).
                    let guildId = p.guildId.isEmpty ? (payload.guild_id?.rawValue ?? "") : p.guildId
                    let sessionsCategoryId = await ConfigStore.shared
                        .loadServerConfig(guildId: guildId)?.channels?.sessionsCategoryId
                    let provisioner: (any GuildChannelProvisioner)? = guildId.isEmpty
                        ? nil
                        : resolveGuildProvisioner(client: client, guildId: guildId)
                    let bindChannelId = await resolveSessionChannelId(
                        provisioner: provisioner,
                        folderPath: p.cwd,
                        sessionsCategoryId: sessionsCategoryId,
                        fallbackChannelId: p.channelId
                    )
                    guard await bindFromWizard(p, channelId: bindChannelId) else {
                        _ = try? await client.updateOriginalInteractionResponse(
                            appId: payload.application_id,
                            token: payload.token,
                            payload: .init(
                                content: I18n.t("wizard.recfg.saveFailed"),
                                embeds: [],
                                components: []
                            )
                        )
                        return
                    }
                    // WO-9: a fresh binding has no session yet, so its `/command` picker would be
                    // empty until something else opened one. Open it now and cache the list, so the
                    // FIRST picker open shows real commands. Detached — this takes seconds and the
                    // wizard still owes Discord a reply.
                    Task { await warmSlashCatalog(channelId: bindChannelId, backend: p.backend) }

                    let sessionCaps = await resolveSessionCapabilities(
                        backend: p.backend, guildId: guildId
                    )
                    let status = SessionStatus(
                        mode: p.backend.rawValue,
                        cwd: p.cwd,
                        sessionId: nil,
                        permMode: p.permMode.isEmpty ? "default" : p.permMode,
                        usagePanel: sessionCaps.usagePanel
                    )
                    let statusEmbed = discordEmbed(from: buildStatusEmbed(status))

                    // Save-as-preset only for a NORMAL launch (not fromPreset; reconfigure already returned).
                    let fromPreset = wizard.launchedFromPreset()
                    var saveRows: [Interaction.ActionRow] = []
                    if !fromPreset {
                        let draft = PresetDraft(
                            backend: p.backend.rawValue,
                            model: modelForPersistedBinding(p.model),
                            effort: p.effort.isEmpty ? nil : p.effort,
                            permMode: p.permMode.isEmpty ? nil : p.permMode,
                            profile: p.profile
                        )
                        let draftKey = PresetDraftRegistry.key(guildId: guildId, channelId: channelId)
                        await PresetDraftRegistry.shared.set(draft, key: draftKey)
                        saveRows = [
                            Interaction.ActionRow(components: [
                                .button(Interaction.ActionRow.Button(
                                    style: .secondary,
                                    label: I18n.t("preset.save.button"),
                                    custom_id: "preset.save"
                                )),
                            ]),
                        ]
                    }

                    // Ephemeral wizard reply: link to session channel (TS cmd.start.channelCreated).
                    let replyText: String
                    if bindChannelId != p.channelId {
                        replyText = I18n.t("cmd.start.channelCreated", ["channel": "<#\(bindChannelId)>"])
                    } else {
                        let extra = [
                            isProviderDefaultModelSelection(p.model) ? nil : "model=\(modelDisplayText(p.model))",
                            p.effort.isEmpty ? nil : "effort=\(p.effort)",
                            p.permMode.isEmpty ? nil : "perm=\(p.permMode)",
                        ].compactMap { $0 }.joined(separator: " ")
                        replyText = I18n.t("wizard.recfg.bound", ["backend": p.backend.rawValue, "cwd": p.cwd])
                            + (extra.isEmpty ? "" : " (\(extra))")
                    }
                    _ = try? await client.updateOriginalInteractionResponse(
                        appId: payload.application_id, token: payload.token,
                        payload: .init(
                            content: replyText,
                            embeds: [],
                            components: saveRows.isEmpty ? [] : saveRows
                        )
                    )
                    // Intro + status embed on the bound session channel (TS postSessionIntro).
                    // W16-g residual: best-effort pin so status stays at the top of the channel.
                    _ = await postSessionStatusIntro(
                        client: client,
                        channelId: ChannelSnowflake(bindChannelId),
                        content: sessionStatusIntroContent,
                        embed: statusEmbed
                    )
                    // redmine-issue-session-start.md WO-11: fires only for a wizard opened from the
                    // Redmine session-pick dropdown's "new session" branch — a plain /agent start
                    // wizard never has an entry here, so get(channelId:) is nil and this is a no-op.
                    // Lookup key is the wizard's original channel (channelId), not the freshly
                    // created session channel (bindChannelId) — the registry entry was written
                    // keyed on the channel where the 착수 button was clicked.
                    if let issueId = await PendingRedmineStartRegistry.shared.get(channelId: channelId) {
                        await PendingRedmineStartRegistry.shared.remove(channelId: channelId)
                        // RedmineClient has no single-issue lookup (list-only), so mirror
                        // handleRedmineIssueSelectComponent's fetch-all-then-filter pattern.
                        if let redmine = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine {
                            do {
                                let apiKey = try RedmineApiKeyCipher.decrypt(redmine.apiKeyEncrypted)
                                let issues = try await RedmineClient().fetchIssues(
                                    baseURL: redmine.url,
                                    apiKey: apiKey,
                                    projectId: redmine.projectId
                                )
                                if let issue = issues.first(where: { $0.id == issueId }) {
                                    // Fire-and-forget: wizard interaction is already settled;
                                    // don't block the handler on the kickoff turn.
                                    let kickClient = client
                                    let kickChannel = bindChannelId
                                    let kickGuild = guildId
                                    let kickBackend = p.backend
                                    let kickActor = clicker
                                    Task {
                                        await runRedmineKickoffPrompt(
                                            client: kickClient,
                                            channelId: kickChannel,
                                            guildId: kickGuild,
                                            backend: kickBackend,
                                            issue: issue,
                                            actorId: kickActor,
                                            roleTier: "execute"
                                        )
                                    }
                                } else {
                                    log.info("redmine kickoff skipped: issue not found id=\(issueId) channel=\(bindChannelId)")
                                }
                            } catch {
                                log.error("redmine kickoff issue refetch failed id=\(issueId) channel=\(bindChannelId) err=\(error)")
                            }
                        } else {
                            log.info("redmine kickoff skipped: no redmine config guild=\(guildId) issue=\(issueId)")
                        }
                    }
                } else {
                    _ = try? await client.updateOriginalInteractionResponse(
                        appId: payload.application_id, token: payload.token,
                        payload: .init(content: I18n.t("wizard.start.noSelection"), embeds: [], components: [])
                    )
                }
            case .cancelled:
                await WizardRegistry.shared.remove(channelId: channelId)
                let (embeds, _) = discordPayload(from: wizard.render())
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(embeds: embeds, components: [])
                )
            default:
                let (embeds, components) = discordPayload(from: wizard.render())
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id, token: payload.token,
                    payload: .init(embeds: embeds, components: components)
                )
            }
        }
    }

    /// dir:panel — deferUpdate, open host osascript picker, jump browser, re-render.
    private func handleFolderPanel(
        _ payload: Interaction,
        wizard: ChannelWizard,
        channelId: String
    ) async throws {
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )
        guard await FolderPanelBusy.shared.tryBegin(channelId) else {
            _ = try? await client.createFollowupMessage(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("dir.panel.busy"), flags: [.ephemeral])
            )
            return
        }
        defer {
            Task { await FolderPanelBusy.shared.end(channelId) }
        }
        _ = try? await client.createFollowupMessage(
            appId: payload.application_id,
            token: payload.token,
            payload: .init(
                content: I18n.t("dir.panel.wait"),
                flags: [.ephemeral]
            )
        )
        do {
            let picked = try await openMacFolderPanel(startDir: wizard.browserCwd())
            if picked == nil {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("dir.panel.cancelled"), flags: [.ephemeral])
                )
                return
            }
            guard let path = picked, wizard.browserGoTo(path) else {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: I18n.t("dir.manual.invalid", ["path": picked ?? ""]),
                        flags: [.ephemeral]
                    )
                )
                return
            }
            let (embeds, components) = discordPayload(from: wizard.render())
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(embeds: embeds, components: components)
            )
            _ = try? await client.createFollowupMessage(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(
                    content: I18n.t("dir.manual.done", ["path": wizard.browserCwd()]),
                    flags: [.ephemeral]
                )
            )
        } catch let err as FolderPanelError {
            let text: String
            switch err {
            case .timeout:
                text = I18n.t("dir.panel.timeout")
            case .failed(let msg):
                text = I18n.t("dir.panel.error", ["err": msg])
            }
            _ = try? await client.createFollowupMessage(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: text, flags: [.ephemeral])
            )
        } catch {
            _ = try? await client.createFollowupMessage(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("dir.panel.error", ["err": "\(error)"]), flags: [.ephemeral])
            )
        }
    }

    /// "💾 프리셋으로 저장" button → name modal (showModal is the ack). Draft keyed by command channel.
    private func handlePresetSaveButton(_ payload: Interaction) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? ""
        let key = PresetDraftRegistry.key(guildId: guildId, channelId: channelId)
        guard await PresetDraftRegistry.shared.get(key: key) != nil else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("preset.save.none"),
                    flags: [.ephemeral]
                ))
            )
            return
        }
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .modal(.init(
                custom_id: "preset.name",
                title: I18n.t("preset.save.title"),
                textInputs: [
                    .init(
                        custom_id: "name",
                        style: .short,
                        label: I18n.t("preset.save.label"),
                        required: true,
                        placeholder: I18n.t("preset.save.placeholder")
                    ),
                ]
            ))
        )
    }

    /// Modal submits for dir:create / dir:manual / preset.name.
    private func handleWizardModal(_ payload: Interaction, modal: Interaction.ModalSubmit) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let clicker = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""

        // preset.name: wizard is already gone; draft lives in PresetDraftRegistry.
        if modal.custom_id == "preset.name" {
            try await handlePresetNameModal(payload, modal: modal)
            return
        }

        // redmine:config (WO-12): standalone /redmine command modal, unrelated to WizardRegistry
        // ownership — must not fall through to the wizard-owner gate below.
        if modal.custom_id == "redmine:config" {
            try await handleRedmineConfigModal(payload, modal: modal)
            return
        }

        // run:{command} (WO-7): the standalone /command modal. Same reason as redmine:config —
        // no WizardRegistry involvement, so it must not fall into the wizard-owner gate below.
        if let runCommand = parseSlashRunModalCustomId(modal.custom_id) {
            try await handleSlashRunModal(payload, modal: modal, command: runCommand)
            return
        }

        guard let wizard = await WizardRegistry.shared.get(channelId: channelId),
              wizard.ownerId == clicker
        else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("wizard.sessionMissing"),
                    flags: [.ephemeral]
                ))
            )
            return
        }

        switch modal.custom_id {
        case "dir:create":
            let name = (try? modal.components.requireComponent(customId: "name").requireTextInput().value)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch wizard.browserCreate(name, enter: true) {
            case .ok:
                let (embeds, components) = discordPayload(from: wizard.render())
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("dir.create.done", ["name": name]),
                        embeds: embeds,
                        flags: [.ephemeral],
                        components: components
                    ))
                )
            case .invalidName, .escaped:
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("dir.create.invalid"),
                        flags: [.ephemeral]
                    ))
                )
            case .failed(let err):
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("dir.create.failed", ["error": "\(err)"]),
                        flags: [.ephemeral]
                    ))
                )
            }
        case "dir:manual":
            let input = (try? modal.components.requireComponent(customId: "path").requireTextInput().value)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if input.isEmpty || !(input as NSString).isAbsolutePath {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("dir.manual.notabs"),
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            if !wizard.browserGoTo(input) {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("dir.manual.invalid", ["path": input]),
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            let (embeds, components) = discordPayload(from: wizard.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("dir.manual.done", ["path": wizard.browserCwd()]),
                    embeds: embeds,
                    flags: [.ephemeral],
                    components: components
                ))
            )
        default:
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(content: I18n.t("wizard.unknownModal"), flags: [.ephemeral]))
            )
        }
    }

    /// `/command` modal submit (WO-7): compose `"/{command}\n{prompt}"` and push it through the
    /// SAME turn pipeline a typed message uses (`runInjectedTurn`). All three backends take slash
    /// commands as ordinary prompt text (§3-5-2 실측), so there is no separate send path to build.
    ///
    /// Unlike the opener, a submit MAY ack first — so this is where the C8 re-check lives: the
    /// command name rode here inside `custom_id`, and `/mode backend …` may have changed what
    /// this channel can run since the picker was drawn. The check is a cache read, not a probe, so
    /// it stays instant.
    ///
    /// Authorization already happened on the `/command` interaction that opened this modal (drive
    /// tier), and Discord only ever delivers the submit from that same user — the same trust chain
    /// `dir:create`/`redmine:config` rely on, hence the `"execute"` tier those paths also pass.
    private func handleSlashRunModal(_ payload: Interaction, modal: Interaction.ModalSubmit, command: String) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? "dm"
        let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        // Deliberately NOT trimmed here: `slashRunPromptText` clips only the outer whitespace and
        // keeps every interior newline, which is the whole point of using a modal (§3-5-1).
        let typed = (try? modal.components.requireComponent(customId: "prompt").requireTextInput().value)
        let prompt = typed.flatMap { $0 } ?? ""
        // Unbound channel → claude, exactly like handleAutocomplete's fallback.
        let backend = await SessionRegistry.shared.binding(channelId: channelId)?.backend ?? .claude
        guard slashRunCommandStillAvailable(channelId: channelId, backend: backend, command: command) else {
            try await respondEphemeral(payload, I18n.t("run.unavailable", ["command": command]))
            return
        }
        try await respondEphemeral(payload, I18n.t("run.started", ["command": command]))
        // postPrompt: true — the composed text is posted to the channel so the ⏳/✅ decoration has
        // an anchor and the channel can see what was run (mirrors runRedmineKickoffPrompt).
        // announceExtras: true — this is a human driving a turn, so it keeps the full
        // mention/usage-panel UX a typed message gets, unlike the bot-authored Redmine kickoff.
        await runInjectedTurn(
            client: client, channelId: channelId, guildId: guildId, backend: backend,
            promptText: slashRunPromptText(command: command, prompt: prompt),
            postPrompt: true, announceExtras: true,
            actorId: actorId, roleTier: "execute"
        )
    }

    /// redmine:config modal submit (WO-12c): extract the 3 fields → ack immediately (channel
    /// creation + config save can cross Discord's 3s window, same reason as /update/doc — a
    /// slow remote fetch/write must not eat it) → encrypt the API key (fail-secure — R11/8장) →
    /// ensure `#redmine-report` → persist `RedmineSection` → (re)start this guild's poller →
    /// report the outcome (success or failure) via createFollowupMessage. Unrelated to
    /// WizardRegistry, so it responds directly rather than via the queued-job path
    /// `handleWizardModal`'s other cases use.
    private func handleRedmineConfigModal(_ payload: Interaction, modal: Interaction.ModalSubmit) async throws {
        tempDiagWrite("handleRedmineConfigModal ENTERED")
        let guildId = payload.guild_id?.rawValue ?? ""
        // Trailing "/" would double up when RedmineClient appends "/issues.json" etc. — normalize
        // here so it never reaches storage either with or without one.
        var url = (try? modal.components.requireComponent(customId: "url").requireTextInput().value)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while url.hasSuffix("/") { url.removeLast() }
        let apiKey = (try? modal.components.requireComponent(customId: "apiKey").requireTextInput().value)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let project = (try? modal.components.requireComponent(customId: "project").requireTextInput().value)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        tempDiagWrite("fields extracted url=\(url) apiKeyLen=\(apiKey.count)")

        let redmineConfigDeferred = try? await client.createInteractionResponse(
            id: payload.id,
            token: payload.token,
            payload: .deferredChannelMessageWithSource(isEphemeral: true)
        )
        tempDiagWrite("defer result=\(redmineConfigDeferred != nil)")
        guard redmineConfigDeferred != nil else {
            tempDiagWrite("RETURNING EARLY: defer was nil")
            return
        }

        let apiKeyEncrypted: Data
        do {
            apiKeyEncrypted = try RedmineApiKeyCipher.encrypt(apiKey)
            tempDiagWrite("encrypt ok")
        } catch {
            tempDiagWrite("encrypt failed: \(error)")
            // Fail-secure (WO-1 금지 사항, 8장): never fall back to storing the plaintext key.
            // Edits the original deferred (already-ephemeral) response — createFollowupMessage's
            // ExecuteWebhook model rejects an explicit `.ephemeral` flag client-side (found live:
            // DiscordBM ValidationError "flags: Can only contain suppressEmbeds/.../isComponentsV2"),
            // so this mirrors /stop's/​/clear's updateOriginalInteractionResponse pattern instead.
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(
                    content: I18n.t("redmine.session.cipherUnavailable")
                )
            )
            return
        }

        do {
            let provisioner = resolveGuildProvisioner(client: client, guildId: guildId)
            tempDiagWrite("ensuring channel...")
            let channel = try await ensureRedmineReportChannel(provisioner: provisioner, configStore: .shared)
            tempDiagWrite("channel ok id=\(channel.id)")
            try await ConfigStore.shared.saveRedmineConfig(
                guildId: guildId,
                section: RedmineSection(
                    url: url,
                    apiKeyEncrypted: apiKeyEncrypted,
                    projectId: project.isEmpty ? nil : project,
                    reportChannelId: channel.id,
                    lastCheckedAt: nil
                )
            )
            tempDiagWrite("config saved, starting poller...")
            await startRedminePoller(client: client, guildId: guildId)
            tempDiagWrite("poller started, sending followup... appId=\(payload.application_id) tokenLen=\(payload.token.count)")
            do {
                let resp = try await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: I18n.t("redmine.session.configSaved", ["channel": channel.name])
                    )
                )
                tempDiagWrite("followup HTTP response: \(resp)")
            } catch {
                tempDiagWrite("followup send THREW: \(error)")
            }
            tempDiagWrite("DONE")
        } catch {
            tempDiagWrite("step failed: \(error)")
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("redmine.session.configSaveFailed", ["error": "\(error)"]))
            )
        }
    }

    /// redmine:issue-select dropdown callback (WO-13, R10). No get-issue-by-id endpoint exists
    /// (WO-3 only lists), so the chosen issue is found by re-running the same fetchIssues query
    /// used to build the dropdown. Responding with a non-ephemeral channelMessageWithSource both
    /// acks the click and posts the card as a normal, publicly-visible message in one step — the
    /// same shape R6/the poller uses, so its start/cancel buttons (WO-14) work identically after.
    private func handleRedmineIssueSelectComponent(
        _ payload: Interaction,
        comp: Interaction.MessageComponent
    ) async throws {
        guard let issueIdString = comp.values?.first, let issueId = Int(issueIdString) else { return }
        let guildId = payload.guild_id?.rawValue ?? ""
        guard let redmine = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine else {
            try await respondEphemeral(payload, I18n.t("redmine.session.configNotFound"))
            return
        }
        do {
            let apiKey = try RedmineApiKeyCipher.decrypt(redmine.apiKeyEncrypted)
            let issues = try await RedmineClient().fetchIssues(
                baseURL: redmine.url,
                apiKey: apiKey,
                projectId: redmine.projectId
            )
            guard let issue = issues.first(where: { $0.id == issueId }) else {
                try await respondEphemeral(payload, I18n.t("redmine.session.issueGone"))
                return
            }
            let embed = discordEmbed(from: buildRedmineIssueEmbed(issue))
            let components = discordActionRows(from: [buildRedmineIssueButtons(issueId: issue.id)])
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(embeds: [embed], components: components))
            )
        } catch {
            try await respondEphemeral(payload, I18n.t("redmine.session.issueFetchFailed", ["error": "\(error)"]))
        }
    }

    /// 착수/취소 button callback (WO-14/WO-9, R7/R8) on a redmine issue card (poller R6 or
    /// redmine:issue-select R10). `.cancel` keeps its original defer-ack → decidedRow shape (no
    /// auth — 2장 Out). `.start` (3-3 D5) checks the `.drive` gate BEFORE any ack, mirroring
    /// handleUpdateComponent's check-then-ack order (1265-1276행) — a denial must not touch the
    /// card at all (not even deferredUpdateMessage), so other users can still click it.
    ///
    /// Existing-session pick → confirm/abort (docs/redmine-session-confirm-kickoff.md):
    /// `.sessionPick` only shows the confirm UI; kickoff runs on `.sessionConfirm` in the background.
    private func handleRedmineIssueComponent(
        _ payload: Interaction,
        comp: Interaction.MessageComponent,
        action: RedmineIssueAction,
        issueId: Int,
        targetChannelId: String? = nil
    ) async throws {
        switch action {
        case .cancel:
            // R8: never touch the Redmine-side issue — only disable both buttons on this card.
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            let decidedRow = discordActionRows(from: [buildRedmineIssueDecidedRow(action: .cancel, issueId: issueId)])
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(components: decidedRow)
            )
        case .start:
            // WO-9 (3-3 D5): gate first, before touching the card.
            let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
            let guildId = payload.guild_id?.rawValue ?? ""
            let isAdmin = await hasDiscordAdministrator(payload, guildId: payload.guild_id?.rawValue, userId: actorId)
            let decision = await Authorizer(config: .shared).authorize(
                AuthInput(
                    userId: actorId,
                    roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                    action: .drive,
                    guildId: payload.guild_id?.rawValue,
                    channelId: nil,
                    isAdministrator: isAdmin
                ),
                projectAuth: nil
            )
            guard decision.allowed else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"]),
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            // Read title/description off the card's own embed (no extra Redmine round-trip
            // needed just to log this).
            let embed = payload.message?.embeds.first
            log.info(
                "redmine issue start requested id=\(issueId) title=\(embed?.title ?? "-") description=\(embed?.description?.prefix(200) ?? "-")"
            )
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            let decidedRow = discordActionRows(from: [buildRedmineIssueDecidedRow(action: .start, issueId: issueId)])
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(components: decidedRow)
            )
            // R1/R6/R7: every active session in this guild + a trailing "신규 세션" sentinel,
            // chunked to Discord's 25-option cap — posted as separate followups (the card itself
            // was already disabled above, not replaced). NOT ephemeral — found live: DiscordBM's
            // `ExecuteWebhook.validate()` hard-codes flags to {suppressEmbeds, suppressNotifications,
            // isComponentsV2} only, so `.ephemeral` here throws a client-side ValidationError that a
            // bare `try?` swallowed silently (the modal-submit completion message hit the exact same
            // wall — fixed there via `updateOriginalInteractionResponse` instead, which isn't
            // possible here since there can be >1 page of new messages).
            let sessions = await redmineSessionSelectOptions(client: client, guildId: guildId)
            let menus = buildRedmineSessionSelectMenus(sessions: sessions, issueId: issueId)
            for menu in menus {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: I18n.t("redmine.session.selectPrompt"),
                        components: [Interaction.ActionRow(components: [.stringSelect(menu)])]
                    )
                )
            }
        case .sessionPick:
            // WO-10 (R2/R3/R4/R5): comp.values carries the picked option — either
            // newSessionSentinel ("__new__", WO-5) or an existing session's channelId.
            guard let selection = comp.values?.first else { return }
            let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
            let guildId = payload.guild_id?.rawValue ?? ""
            let cardChannelId = payload.channel_id?.rawValue ?? ""
            let isAdmin = await hasDiscordAdministrator(payload, guildId: payload.guild_id?.rawValue, userId: actorId)

            if selection == newSessionSentinel {
                // "신규 세션" (3-2 시퀀스②): the card's channel isn't a session channel yet, so
                // projectAuth stays nil — same shape as the .start gate above (3-3 D5).
                let decision = await Authorizer(config: .shared).authorize(
                    AuthInput(
                        userId: actorId,
                        roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                        action: .drive,
                        guildId: payload.guild_id?.rawValue,
                        channelId: nil,
                        isAdministrator: isAdmin
                    ),
                    projectAuth: nil
                )
                guard decision.allowed else {
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .channelMessageWithSource(.init(
                            content: I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"]),
                            flags: [.ephemeral]
                        ))
                    )
                    return
                }
                // Mirrors /agent start's owner-transfer guard (772-779행) — the card's channel is
                // never a session channel itself, so this binding is almost always nil and the
                // check trivially passes, but it must stay (WO-10 금지 — don't drop it just
                // because it's usually a no-op here).
                if let owner = await SessionStore.shared.binding(channelId: cardChannelId)?.ownerId,
                   !owner.isEmpty,
                   owner != actorId,
                   decision.tier != .admin
                {
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .channelMessageWithSource(.init(
                            content: I18n.t("session.ownerOrAdminRequired"),
                            flags: [.ephemeral]
                        ))
                    )
                    return
                }
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .deferredUpdateMessage()
                )
                await PendingRedmineStartRegistry.shared.put(issueId, channelId: cardChannelId)
                let stubCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
                try await presentAgentStartWizard(
                    client: client,
                    payload: payload,
                    guildId: guildId,
                    channelId: cardChannelId,
                    actorId: actorId,
                    stubCwd: stubCwd
                )
            } else {
                // Existing session: authorize + show confirm UI only (kickoff waits for .sessionConfirm).
                // docs/redmine-session-confirm-kickoff.md — replaces the dropdown message in place.
                let chosenChannelId = selection
                let targetProjectAuth = await SessionStore.shared.binding(channelId: chosenChannelId)?.projectAuth
                let decision = await Authorizer(config: .shared).authorize(
                    AuthInput(
                        userId: actorId,
                        roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                        action: .drive,
                        guildId: payload.guild_id?.rawValue,
                        channelId: chosenChannelId,
                        isAdministrator: isAdmin
                    ),
                    projectAuth: targetProjectAuth
                )
                guard decision.allowed else {
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .channelMessageWithSource(.init(
                            content: I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"]),
                            flags: [.ephemeral]
                        ))
                    )
                    return
                }
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .deferredUpdateMessage()
                )
                guard await SessionStore.shared.binding(channelId: chosenChannelId) != nil else {
                    _ = try? await client.updateOriginalInteractionResponse(
                        appId: payload.application_id,
                        token: payload.token,
                        payload: .init(content: I18n.t("redmine.session.notFound"), components: [])
                    )
                    return
                }
                let confirmRows = discordActionRows(
                    from: [buildRedmineSessionConfirmRow(issueId: issueId, targetChannelId: chosenChannelId)]
                )
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: I18n.t("redmine.session.confirmDeliver", ["issueId": "\(issueId)", "channel": chosenChannelId]),
                        components: confirmRows
                    )
                )
            }
        case .sessionConfirm:
            // Confirm after existing-session pick: ack immediately, kickoff in background.
            guard let chosenChannelId = targetChannelId, !chosenChannelId.isEmpty else { return }
            let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
            let guildId = payload.guild_id?.rawValue ?? ""
            let isAdmin = await hasDiscordAdministrator(payload, guildId: payload.guild_id?.rawValue, userId: actorId)
            let targetProjectAuth = await SessionStore.shared.binding(channelId: chosenChannelId)?.projectAuth
            let decision = await Authorizer(config: .shared).authorize(
                AuthInput(
                    userId: actorId,
                    roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                    action: .drive,
                    guildId: payload.guild_id?.rawValue,
                    channelId: chosenChannelId,
                    isAdministrator: isAdmin
                ),
                projectAuth: targetProjectAuth
            )
            guard decision.allowed else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"]),
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            guard let targetBackend = await SessionStore.shared.binding(channelId: chosenChannelId)?.backend else {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("redmine.session.notFound"), components: [])
                )
                return
            }
            guard let redmine = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine else {
                _ = try? await client.updateOriginalInteractionResponse(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: I18n.t("redmine.session.configNotFound"), components: [])
                )
                return
            }
            // Resolve the interaction before the (potentially long) turn so Discord doesn't
            // look hung and the user sees "요청했어요" right away.
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("redmine.session.requested", ["channel": chosenChannelId]), components: [])
            )
            let roleTier = decision.tier?.rawValue ?? "execute"
            let appClient = client
            Task {
                do {
                    let apiKey = try RedmineApiKeyCipher.decrypt(redmine.apiKeyEncrypted)
                    let issues = try await RedmineClient().fetchIssues(
                        baseURL: redmine.url,
                        apiKey: apiKey,
                        projectId: redmine.projectId
                    )
                    guard let issue = issues.first(where: { $0.id == issueId }) else {
                        log.info("redmine kickoff skipped: issue not found id=\(issueId) channel=\(chosenChannelId)")
                        _ = await createMessageWithRetry(
                            client: appClient,
                            channelId: ChannelSnowflake(chosenChannelId),
                            payload: .init(content: I18n.t("redmine.session.issueGoneNotice", ["issueId": "\(issueId)"])),
                            onGone: nil
                        )
                        return
                    }
                    await runRedmineKickoffPrompt(
                        client: appClient,
                        channelId: chosenChannelId,
                        guildId: guildId,
                        backend: targetBackend,
                        issue: issue,
                        actorId: actorId,
                        roleTier: roleTier
                    )
                } catch {
                    log.error("redmine kickoff issue refetch failed id=\(issueId) channel=\(chosenChannelId) err=\(error)")
                    _ = await createMessageWithRetry(
                        client: appClient,
                        channelId: ChannelSnowflake(chosenChannelId),
                        payload: .init(content: I18n.t("redmine.session.issueFetchFailedNotice", ["error": "\(error)"])),
                        onGone: nil
                    )
                }
            }
        case .sessionAbort:
            // Cancel confirm step — no auth required (mirrors card .cancel: local UI only).
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            _ = try? await client.updateOriginalInteractionResponse(
                appId: payload.application_id,
                token: payload.token,
                payload: .init(content: I18n.t("redmine.session.deliverCancelled"), components: [])
            )
        }
    }

    /// Persist draft under the typed name via ConfigStore.addServerPreset.
    private func handlePresetNameModal(_ payload: Interaction, modal: Interaction.ModalSubmit) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? ""
        let key = PresetDraftRegistry.key(guildId: guildId, channelId: channelId)
        guard let draft = await PresetDraftRegistry.shared.get(key: key) else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("preset.save.none"),
                    flags: [.ephemeral]
                ))
            )
            return
        }
        let name = (try? modal.components.requireComponent(customId: "name").requireTextInput().value)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty || name.count > 100 {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("preset.save.invalidName"),
                    flags: [.ephemeral]
                ))
            )
            return
        }
        do {
            try await ConfigStore.shared.addServerPreset(
                guildId: guildId,
                preset: Preset(
                    name: name,
                    backend: draft.backend,
                    model: draft.model,
                    effort: draft.effort,
                    permMode: draft.permMode,
                    profile: draft.profile
                )
            )
            await PresetDraftRegistry.shared.remove(key: key)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("preset.saved", ["name": name]),
                    flags: [.ephemeral]
                ))
            )
        } catch {
            // Keep draft so a retry can still save.
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("preset.save.failed", ["error": "\(error)"]),
                    flags: [.ephemeral]
                ))
            )
        }
    }

    /// Atomically replace a live binding after the wizard selection is durably saved.
    /// `channelId` defaults to wizard params (same channel); A4D start passes a newly created
    /// session channel id when available.
    private func bindFromWizard(_ p: WizardStartParams, channelId: String? = nil) async -> Bool {
        let model = modelForPersistedBinding(p.model)
        let effort = p.effort.isEmpty ? nil : p.effort
        let perm = p.permMode.isEmpty ? nil : p.permMode
        let bindId = channelId ?? p.channelId
        // G-P0-05: carry binding-resident projectAuth across REPLACE (TS start()).
        let existing = await SessionStore.shared.binding(channelId: bindId)
        let record = PersistedSession(
            backend: p.backend,
            backendSessionId: nil,
            cwd: p.cwd,
            guildId: p.guildId,
            ownerId: p.ownerId.isEmpty ? nil : p.ownerId,
            model: model,
            effort: effort,
            permMode: perm,
            // C3: the wizard's perm step now collects a quick-select profile — its choice (or
            // nil for raw mode) is the source of truth here, same as model/effort/permMode above
            // (was `existing?.permissionProfile`, which never let a freshly-picked profile persist).
            permissionProfile: p.profile,
            projectAuth: existing?.projectAuth,
            createdAt: existing?.createdAt,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            archived: false
        )
        return await SessionLifecycle.shared.replaceBinding(channelId: bindId, with: record)
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        let locale = await responseLocale(guildId: payload.guild_id?.rawValue)
        try await I18n.withLocale(locale) {
            try await handleMessageCreate(payload)
        }
    }

    private func handleMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        // Ignore bots / webhooks
        if payload.author?.bot == true { return }
        if payload.webhook_id != nil { return }

        let channelId = payload.channel_id.rawValue
        let binding = await SessionRegistry.shared.binding(channelId: channelId)
        let hasAttachments = !payload.attachments.isEmpty
        switch routeDecision(content: payload.content, binding: binding, hasAttachments: hasAttachments, isDM: payload.guild_id == nil) {
        case .ignore:
            return
        case .usage(let label):
            _ = await createMessageWithRetry(
                client: client,
                channelId: payload.channel_id,
                payload: .init(content: "Usage: `\(label) <prompt>`"),
                onGone: {
                    await SessionLifecycle.shared.stopChannel(
                        channelId: channelId, actorId: "system", guildId: payload.guild_id?.rawValue ?? "dm", roleTier: "execute"
                    )
                }
            )
        case .prefixClaude(let text):
            await runAndReply(.claude, payload, text: text, binding: nil)
        case .prefixCodex(let text):
            await runAndReply(.codex, payload, text: text, binding: nil)
        case .prefixGrok(let text):
            await runAndReply(.grok, payload, text: text, binding: nil)
        case .prefixCustom(let text):
            await runAndReply(.custom, payload, text: text, binding: nil)
        case .bound(let backend, let text):
            await runAndReply(backend, payload, text: text, binding: binding)
        }
    }

    /// Run one turn on the chosen backend's bridge and post the reply (or a ⚠️ notice).
    private func runAndReply(_ backend: Backend, _ payload: Gateway.MessageCreate, text: String, binding: SessionConfig?) async {
        let channelId = payload.channel_id.rawValue
        let actorId = payload.author?.id.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? "dm"

        // Deny-by-default authorization gate (W13-a). This is the single funnel all four execute
        // routes (prefix*/bound) converge on (D4). The gateway message event does not carry a
        // pre-computed member.permissions (unlike interactions), so isAdministrator is computed
        // from GuildAdminCache (OK-2 fix) — owner id / admin-flagged role ids captured on
        // GuildCreate and kept current via onGuildRoleCreate/Update/Delete (Q1-b). DMs (no
        // guild_id) stay false — dmPolicy is authoritative there.
        // G-P0-05: store projectAuth intersects (narrows only) when present on the binding.
        var isAdmin = false
        if let gid = payload.guild_id?.rawValue {
            isAdmin = await GuildAdminCache.shared.isAdministrator(
                guildId: gid,
                userId: actorId,
                roleIds: payload.member?.roles?.map(\.rawValue) ?? []
            )
        }
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(userId: actorId, roleIds: payload.member?.roles?.map(\.rawValue) ?? [], action: .drive, guildId: payload.guild_id?.rawValue, channelId: channelId, isAdministrator: isAdmin),
            projectAuth: projectAuth
        )
        let tier = decision.tier?.rawValue ?? "none"
        guard decision.allowed else {
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "drive", mode: backend.rawValue, outcome: decision.reason, status: "denied"))
            _ = await createMessageWithRetry(
                client: client,
                channelId: payload.channel_id,
                payload: .init(content: I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"])),
                onGone: {
                    await SessionLifecycle.shared.stopChannel(
                        channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                    )
                }
            )
            return
        }

        // G-P0-01: download Discord attachments into the session workspace (confined), then
        // pass paths to the backend (Claude: session.send files; Codex/Grok: text hints).
        let turnFiles: [TurnFile]
        if payload.attachments.isEmpty {
            turnFiles = []
        } else {
            let cwd = await resolveTurnCwd(channelId: channelId)
            let incoming = payload.attachments.map {
                IncomingAttachment(url: $0.url, name: $0.filename, contentType: $0.content_type)
            }
            do {
                turnFiles = try await downloadAttachments(cwd: cwd, attachments: incoming)
            } catch {
                log.error("attachment download failed channel=\(channelId) err=\(error)")
                _ = await createMessageWithRetry(
                    client: client,
                    channelId: payload.channel_id,
                    payload: .init(content: I18n.t("cmd.attachment.failed", ["error": "\(error)"])),
                    onGone: {
                        await SessionLifecycle.shared.stopChannel(
                            channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                        )
                    }
                )
                return
            }
        }

        log.info("\(backend.rawValue) channel=\(channelId) prompt=\(text.prefix(80)) files=\(turnFiles.count)")
        // G-P0-02: ⏳ working indicator on the user message as soon as the turn is accepted
        // (before runTurn / control message). Best-effort — missing Add Reactions never blocks.
        await addTurnReaction(
            client: client,
            channelId: payload.channel_id,
            messageId: payload.id,
            emoji: TurnReactions.working
        )
        // Capabilities gate (TS RendererDispatcher): toolThreads/fileDiff/streaming/usagePanel.
        let caps = await resolveSessionCapabilities(backend: backend, guildId: guildId)
        await ToolActivityHost.shared.setCapabilities(channelId: channelId, caps)
        // C15: guildId/backend for the status-channel tool_use notifier (see setNotifier above).
        await ToolActivityHost.shared.setNotifyContext(channelId: channelId, guildId: guildId, backend: backend)
        // Live stream status embed: yellow "응답 중…" + Stop button (W11-g residual).
        // Mid-turn text/tool/progress edits via StreamStatusHost; finalize collapses to done.
        // streaming=false → skip begin (notes no-op); interrupt control message still posts.
        let controlMsgId = await postInterruptControlMessage(
            client: client, channelId: payload.channel_id, guildId: guildId
        )
        if caps.streaming, let controlMsgId {
            await StreamStatusHost.shared.begin(
                channelId: channelId,
                guildId: guildId,
                messageId: controlMsgId.rawValue
            )
        }
        // G-P1-01: arm idle watchdog for this turn (StreamStatusHost notes reset; stop on end).
        await IdleWatchdog.shared.arm(channelId: channelId)
        // WO-5 (docs/claude-turn-timeout-delay.md): push-based delivery, no "is this the last
        // result" judgment. `pushChain` serializes `deliverTurnPush` calls fired from Claude's
        // `onAnswer` (possibly more than once — a background-subagent follow-up `.result` fires it
        // again) so they post in order, and so the one-shot completion decoration below waits for
        // at least the first one to actually finish instead of racing ahead of it.
        let pushCtx = TurnDeliveryContext(
            client: client, channelId: payload.channel_id, guildId: guildId, backend: backend,
            caps: caps, actorId: actorId, roleTier: tier, permMode: binding?.permMode
        )
        let pushChain = LockedBox<Task<Void, Never>?>(nil)
        // RV follow-up (docs/claude-turn-timeout-delay.md 10장): track whether any push actually
        // reached Discord (pushFailed → completion reaction shows ❌ even if the AI itself
        // succeeded) and the most recent tool count (restores the completion embed's "🛠️ N").
        let pushFailed = LockedBox<Bool>(false)
        let lastToolCount = LockedBox<Int>(0)
        let onAnswer: @Sendable (TurnResult) -> Void = { turn in
            lastToolCount.withLock { $0 = turn.tools.reduce(0) { $0 + $1.count } }
            pushChain.withLock { prev in
                let previous = prev
                prev = Task {
                    _ = await previous?.value
                    if await !deliverTurnPush(turn, ctx: pushCtx) {
                        pushFailed.withLock { $0 = true }
                    }
                }
            }
        }
        do {
            switch backend {
            case .claude, .custom:
                // custom: Claude sidecar path + shell-env overlay inside DabSessionBridge (W16-f).
                let cfg = binding ?? SessionConfig(backend: backend)
                try await DabSessionBridge.shared.runTurn(
                    channelId: channelId,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    ownerId: payload.author?.id.rawValue,
                    text: text,
                    config: cfg,
                    files: turnFiles,
                    onAnswer: onAnswer
                )
            case .codex:
                let turn = try await CodexSessionBridge.shared.runTurn(
                    channelId: channelId,
                    ownerId: payload.author?.id.rawValue,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    text: text,
                    config: binding,
                    files: turnFiles
                )
                lastToolCount.withLock { $0 = turn.tools.reduce(0) { $0 + $1.count } }
                if await !deliverTurnPush(turn, ctx: pushCtx) { pushFailed.withLock { $0 = true } }
            case .grok:
                let turn = try await GrokSessionBridge.shared.runTurn(
                    channelId: channelId,
                    ownerId: payload.author?.id.rawValue,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    text: text,
                    config: binding,
                    files: turnFiles
                )
                lastToolCount.withLock { $0 = turn.tools.reduce(0) { $0 + $1.count } }
                if await !deliverTurnPush(turn, ctx: pushCtx) { pushFailed.withLock { $0 = true } }
            }
            await pushChain.withLock { $0 }?.value
            // G-P1-01 / G-P0-02: one-shot completion decoration (emoji/stream/stop
            // button/IdleWatchdog) — fires once, right after the first answer went out.
            await finalizeTurnCompletion(
                client: client, channelId: payload.channel_id, messageId: payload.id,
                controlMsgId: controlMsgId, guildId: guildId, ok: !(pushFailed.withLock { $0 }),
                toolCount: lastToolCount.withLock { $0 }
            )
        } catch {
            await pushChain.withLock { $0 }?.value
            await finalizeTurnCompletion(
                client: client, channelId: payload.channel_id, messageId: payload.id,
                controlMsgId: controlMsgId, guildId: guildId, ok: false,
                toolCount: lastToolCount.withLock { $0 }
            )
            // Same chunking on error path so huge error text is not truncated.
            let msg = "⚠️ \(error.localizedDescription)"
            log.error("\(backend.rawValue) turn failed: \(error)")
            for chunk in DiscordText.chunkMessage(msg) {
                _ = await createMessageWithRetry(
                    client: client,
                    channelId: payload.channel_id,
                    payload: .init(content: chunk),
                    onGone: {
                        await SessionLifecycle.shared.stopChannel(
                            channelId: channelId, actorId: "system", guildId: guildId, roleTier: "execute"
                        )
                    }
                )
            }
            // "turn timeout (no terminal result)" (DabSessionBridge.finishTurn) already
            // invalidated this channel's session binding — offer a retry-prompt so the user
            // knows the next message starts a fresh session, without resending anything here.
            if let rpcErr = error as? SidecarRpcError, rpcErr.code == "internal", rpcErr.message == "turn timeout (no terminal result)" {
                _ = await createMessageWithRetry(
                    client: client,
                    channelId: payload.channel_id,
                    payload: .init(
                        content: I18n.t("turnTimeout.prompt"),
                        components: discordActionRows(from: [buildTurnTimeoutRetryRow()])
                    )
                )
            }
            // W16-g: status-channel error notification.
            let errEv = AgentEvent.error(message: error.localizedDescription, retryable: true)
            await postStatusNotification(
                client: client, guildId: guildId, sessionChannelId: channelId, event: errEv, backend: backend
            )
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "turn", mode: backend.rawValue, permMode: binding?.permMode, outcome: error.localizedDescription, status: "error"))
        }
    }

    /// Interrupt button click: drive-tier, SessionLifecycle.interruptChannel (keeps binding).
    private func handleInterruptComponent(
        _ payload: Interaction,
        guildId: String,
        channelId: String
    ) async throws {
        let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(
                userId: actorId,
                roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                action: .drive,
                guildId: payload.guild_id?.rawValue,
                channelId: channelId,
                isAdministrator: payload.member?.permissions?.contains(.administrator) ?? false
            ),
            projectAuth: projectAuth
        )
        guard decision.allowed else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(content: InterruptLabels.denied, flags: [.ephemeral]))
            )
            return
        }
        // Ack first (deferUpdate keeps the control message), then interrupt.
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .deferredUpdateMessage()
        )
        let tier = decision.tier?.rawValue ?? "execute"
        let ok = await SessionLifecycle.shared.interruptChannel(
            channelId: channelId,
            actorId: actorId,
            guildId: guildId,
            roleTier: tier
        )
        _ = try? await client.createFollowupMessage(
            appId: payload.application_id,
            token: payload.token,
            payload: .init(content: ok ? InterruptLabels.done : InterruptLabels.none, flags: [.ephemeral])
        )
    }
}

// MARK: - Turn workspace cwd (G-P0-01)

/// Session workspace for attachment download: persisted wizard cwd first, else DAB_CWD / home
/// (matches bridge `cwd` fallbacks so files land where agents can Read them).
func resolveTurnCwd(channelId: String) async -> String {
    if let c = await SessionStore.shared.binding(channelId: channelId)?.cwd, !c.isEmpty {
        return c
    }
    if let v = ProcessInfo.processInfo.environment["DAB_CWD"], !v.isEmpty {
        return v
    }
    return NSHomeDirectory()
}

// MARK: - Resume list + bind (W11-b2 residual)

/// Claude/custom → sidecar sessions.list; Codex → ~/.codex discovery (session_index.jsonl +
/// state sqlite, process-wide, not scoped to `cwd` — matches TS codex/index.ts:67-69); Grok →
/// ~/.grok discovery (session_search.sqlite, scoped to `cwd` — matches TS grok/agent/index.ts:76).
func listResumableForBackend(_ backend: Backend, cwd: String) async -> [ResumableSession] {
    switch backend {
    case .claude, .custom:
        return await DabSessionBridge.shared.listResumableSessions(cwd: cwd)
    case .codex:
        let codexHome = resolveCodexHome((try? await ConfigStore.shared.load())?.defaults.codexHome)
        return CodexDiscovery.listResumable(codexHome: codexHome)
    case .grok:
        return GrokDiscovery.listResumable(grokHome: resolveGrokHome(), cwd: cwd)
    }
}

/// G-P1-05 / TS `postResumeIntro`: status embed titled "세션 재개됨" + pin best-effort.
func postResumeChannelIntro(
    client: any DiscordClient,
    channelId: String,
    session: PersistedSession
) async {
    let caps = await resolveSessionCapabilities(backend: session.backend, guildId: session.guildId)
    let status = SessionStatus(
        mode: session.backend.rawValue,
        cwd: session.cwd,
        sessionId: session.backendSessionId,
        permMode: session.permMode ?? "default",
        usagePanel: caps.usagePanel
    )
    _ = await postSessionStatusIntro(
        client: client,
        channelId: ChannelSnowflake(channelId),
        content: sessionStatusIntroContent,
        embed: discordEmbed(from: buildResumeStatusEmbed(status))
    )
}

/// Bind registry + upsert store with `backendSessionId` on the **current** channel (A4D create residual).
func bindResumedSession(_ params: ResumeParams) async throws -> ResumeResult {
    // Prefer model/effort/perm from an existing store row when rebinding the same channel.
    // G-P0-05: carry binding-resident projectAuth across REPLACE (TS resume()).
    let existing = await SessionStore.shared.binding(channelId: params.channelId)
    let model = existing?.model
    let effort = existing?.effort
    let perm = existing?.permMode
    await SessionRegistry.shared.bind(
        channelId: params.channelId,
        SessionConfig(backend: params.backend, model: model, effort: effort, permMode: perm)
    )
    let record = PersistedSession(
        backend: params.backend,
        backendSessionId: params.sessionId,
        cwd: params.cwd,
        guildId: params.guildId,
        ownerId: params.ownerId.isEmpty ? nil : params.ownerId,
        model: model,
        effort: effort,
        permMode: perm,
        permissionProfile: existing?.permissionProfile,
        projectAuth: existing?.projectAuth,
        contextGenerationStartedAt: existing?.contextGenerationStartedAt,
        createdAt: existing?.createdAt,
        updatedAt: ISO8601DateFormatter().string(from: Date()),
        archived: existing?.archived ?? false,
        orchestrationRole: existing?.orchestrationRole,
        orchestratorChannelId: existing?.orchestratorChannelId,
        moduleName: existing?.moduleName
    )
    try await SessionStore.shared.upsert(channelId: params.channelId, record)
    return ResumeResult(channelId: params.channelId)
}

// MARK: - Autocomplete helpers (G-P1-03)

/// Focused option's partial string (empty when missing / not string). Discord autocomplete payload.
func focusedAutocompleteQuery(_ cmd: Interaction.ApplicationCommand) -> String {
    guard let focused = cmd.options?.first(where: { $0.focused == true }) else { return "" }
    return (try? focused.requireString()) ?? ""
}

/// 60s models cache so a typing burst does not re-probe the Claude sidecar (TS modelAutocompleteCacheMs).
/// Codex/Grok are cheap local reads but share the same path for simplicity.
private enum AutocompleteModelsCache {
    private struct Entry {
        var backend: Backend
        var choices: [ModelChoice]
        var fetchedAt: Date
    }
    private static let box = LockedBox<Entry?>(nil)
    static let ttl: TimeInterval = 60

    static func models(backend: Backend, catalog: any ProviderCatalog) async -> [ModelChoice] {
        let now = Date()
        if let hit = box.withLock({ $0 }),
           hit.backend == backend,
           now.timeIntervalSince(hit.fetchedAt) < ttl
        {
            return hit.choices
        }
        let choices = await catalog.models(configured: nil)
        box.withLock { $0 = Entry(backend: backend, choices: choices, fetchedAt: now) }
        return choices
    }
}

func autocompleteModels(backend: Backend, catalog: any ProviderCatalog) async -> [ModelChoice] {
    await AutocompleteModelsCache.models(backend: backend, catalog: catalog)
}

// MARK: - Capabilities (render gating)

/// Resolve render caps for a guild turn: backend defaults ← global config ← server ← DAB_CAPS.
func resolveSessionCapabilities(backend: Backend, guildId: String) async -> Capabilities {
    let globalCaps: CapabilitiesPartial?
    if let cfg = try? await ConfigStore.shared.load() {
        globalCaps = cfg.capabilities
    } else {
        globalCaps = nil
    }
    let serverCaps = guildId.isEmpty || guildId == "dm"
        ? nil
        : await ConfigStore.shared.loadServerConfig(guildId: guildId)?.capabilities
    return resolveCapabilities(
        backend: backend,
        global: globalCaps,
        server: serverCaps,
        env: ProcessInfo.processInfo.environment
    )
}

// MARK: - Usage / rate-limit posting (shared by turn-end delivery + H10 UsageActivityHost)

/// backend → (live usage snapshot, panel title). Shared by turn-end delivery
/// (runAndReply) and the H10 mid-turn UsageActivityHost notifier (postUsageActivity).
func usageSnapshotAndTitle(backend: Backend) async -> (usage: UsageResult?, title: String) {
    switch backend {
    case .claude, .custom:
        return (await ClaudeUsageService.shared.getUsage(), I18n.t("usage.title"))
    case .grok:
        return (await GrokUsageService.shared.getUsage(), I18n.t("usage.title.grok"))
    case .codex:
        return (await CodexUsageService.shared.getUsage(), I18n.t("usage.title.codex"))
    }
}

/// Session metadata shared by the ordinary turn-end panel and Claude/Custom's mid-turn panel.
/// The binding is the authority for cwd, creation time, and live permission; a non-repository or
/// unavailable git executable simply omits the branch segment.
func resolveUsageSessionMeta(channelId: String, fallbackPermMode: String?) async -> UsageSessionMeta {
    let binding = await SessionStore.shared.binding(channelId: channelId)
    let fallbackCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSHomeDirectory()
    return usageSessionMeta(
        binding: binding,
        fallbackCwd: fallbackCwd,
        fallbackPermMode: fallbackPermMode,
        gitBranchForCwd: bestEffortGitBranch
    )
}

private func bestEffortGitBranch(cwd: String) -> String? {
    guard !cwd.isEmpty else { return nil }
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    process.arguments = ["git", "rev-parse", "--abbrev-ref", "HEAD"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        guard terminated.wait(timeout: .now() + .milliseconds(1_000)) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let branch = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty
        else { return nil }
        return branch
    } catch {
        return nil
    }
}

/// Post the usage embed, or the plain context-usage line when the embed has no panel fields.
/// Shared by turn-end delivery and the H10 real-time notifier.
func postUsageEmbedOrFallback(
    client: any DiscordClient, channelId: ChannelSnowflake, guildId: String,
    usage: UsageResult?, ctxUsage: ContextUsageInfo?, extras: UsageEmbedExtras
) async {
    let onGone: @Sendable () async -> Void = {
        await SessionLifecycle.shared.stopChannel(
            channelId: channelId.rawValue, actorId: "system", guildId: guildId, roleTier: "execute"
        )
    }
    if let spec = buildUsageEmbed(usage: usage, ctxUsage: ctxUsage, extras: extras) {
        _ = await createMessageWithRetry(
            client: client, channelId: channelId,
            payload: .init(embeds: [discordEmbed(from: spec)]), onGone: onGone
        )
    } else if let ctx = ctxUsage {
        // Fallback: plain context line when no panel fields (no OAuth / tools).
        _ = await createMessageWithRetry(
            client: client, channelId: channelId,
            payload: .init(content: formatContextUsageLine(ctx)), onGone: onGone
        )
    }
}

/// Post the rate-limit line (never usagePanel-gated — TS RendererDispatcher.rateLimit). Shared by
/// turn-end delivery and the H10 real-time notifier.
func postRateLimitLine(
    client: any DiscordClient, channelId: ChannelSnowflake, guildId: String,
    rateLimit: RateLimitInfo, usage: UsageResult?
) async {
    _ = await createMessageWithRetry(
        client: client, channelId: channelId,
        payload: .init(content: formatRateLimitLine(rateLimit, usage: usage)),
        onGone: {
            await SessionLifecycle.shared.stopChannel(
                channelId: channelId.rawValue, actorId: "system", guildId: guildId, roleTier: "execute"
            )
        }
    )
}

/// H10: UsageActivityHost notifier — mid-turn context_usage/rate_limit → immediate post (TS
/// renderers/index.ts usage(ev)/rateLimit(ev), which never wait for turn completion).
func postUsageActivity(
    client: any DiscordClient, channelId: ChannelSnowflake, guildId: String,
    backend: Backend, permMode: String?, event: UsageActivityEvent
) async {
    switch event {
    case .contextUsage(let ctx, let tools, let agents):
        let (usage, title) = await usageSnapshotAndTitle(backend: backend)
        let extras = UsageEmbedExtras(
            meta: await resolveUsageSessionMeta(channelId: channelId.rawValue, fallbackPermMode: permMode),
            title: title, tools: tools, agents: agents
        )
        await postUsageEmbedOrFallback(
            client: client, channelId: channelId, guildId: guildId,
            usage: usage, ctxUsage: ctx, extras: extras
        )
    case .rateLimit(let rl):
        let (usage, _) = await usageSnapshotAndTitle(backend: backend)
        await postRateLimitLine(client: client, channelId: channelId, guildId: guildId, rateLimit: rl, usage: usage)
    }
}

// MARK: - turn reactions (G-P0-02 / TS messageRouter REACT_WORKING/DONE/ERROR)

/// Lifecycle emoji on the user's message: ⏳ while the AI works, then ✅/❌ on terminal.
enum TurnReactions {
    static let working = "⏳"
    static let done = "✅"
    static let error = "❌"
}

/// Best-effort add of a unicode reaction. Permission / network failures are swallowed.
func addTurnReaction(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake,
    emoji: String
) async {
    guard let reaction = try? Reaction.unicodeEmoji(emoji) else { return }
    _ = try? await client.addMessageReaction(
        channelId: channelId,
        messageId: messageId,
        emoji: reaction
    )
}

/// Best-effort remove of the bot's own reaction (clear ⏳ on completion).
func removeOwnTurnReaction(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake,
    emoji: String
) async {
    guard let reaction = try? Reaction.unicodeEmoji(emoji) else { return }
    _ = try? await client.deleteOwnMessageReaction(
        channelId: channelId,
        messageId: messageId,
        emoji: reaction
    )
}

/// Clear ⏳ and add the terminal reaction (✅ success / ❌ error). Best-effort.
func completeTurnReaction(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake,
    terminal: String
) async {
    await removeOwnTurnReaction(
        client: client,
        channelId: channelId,
        messageId: messageId,
        emoji: TurnReactions.working
    )
    await addTurnReaction(
        client: client,
        channelId: channelId,
        messageId: messageId,
        emoji: terminal
    )
}

// MARK: - interrupt / stream control message (W11-g residual)

/// Post yellow "응답 중…" embed + Stop button while a turn runs. Returns message id for finalize.
func postInterruptControlMessage(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    guildId: String
) async -> MessageSnowflake? {
    let ch = channelId.rawValue
    let btn = buildInterruptButton(guildId: guildId, channelId: ch)
    let button = Interaction.ActionRow.Button(
        style: .secondary,
        label: btn.label,
        custom_id: btn.customId
    )
    let row: Interaction.ActionRow = [.button(button)]
    let embed = discordEmbed(from: formatStreamEmbed())
    do {
        let resp = try await client.createMessage(
            channelId: channelId,
            payload: .init(embeds: [embed], components: [row])
        )
        return try resp.decode().id
    } catch {
        return nil
    }
}

/// Mid-turn edit of the stream control message (keeps interrupt button enabled).
func editStreamControlMessage(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake,
    guildId: String,
    spec: StreamEmbedSpec
) async {
    let ch = channelId.rawValue
    let btn = buildInterruptButton(guildId: guildId, channelId: ch)
    let button = Interaction.ActionRow.Button(
        style: .secondary,
        label: btn.label,
        custom_id: btn.customId
    )
    let row: Interaction.ActionRow = [.button(button)]
    _ = try? await client.updateMessage(
        channelId: channelId,
        messageId: messageId,
        payload: .init(
            // Clear any legacy plain-content body when upgrading mid-flight.
            content: "",
            embeds: [discordEmbed(from: spec)],
            components: [row]
        )
    )
}

/// Collapse the stream embed + disable the interrupt button after the turn ends.
/// `toolCount` optionally appends " · 🛠️ N" (W11-g slice4 HUD).
func finalizeInterruptControlMessage(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    messageId: MessageSnowflake?,
    guildId: String,
    toolCount: Int = 0
) async {
    guard let messageId else { return }
    let ch = channelId.rawValue
    let btn = buildInterruptButton(guildId: guildId, channelId: ch, disabled: true)
    let button = Interaction.ActionRow.Button(
        style: .secondary,
        label: btn.label,
        custom_id: btn.customId,
        disabled: true
    )
    let row: Interaction.ActionRow = [.button(button)]
    let embed = discordEmbed(from: formatStreamEmbed(toolCount: toolCount, finalized: true))
    _ = try? await client.updateMessage(
        channelId: channelId,
        messageId: messageId,
        payload: .init(content: "", embeds: [embed], components: [row])
    )
}

// MARK: - answer delivery (S3)

/// Map `DeliverPayload` → DiscordBM createMessage (text and/or PNG attachment).
func emitDeliverPayload(
    client: any DiscordClient,
    channelId: ChannelSnowflake,
    payload: DeliverPayload
) async throws {
    if let name = payload.fileName, let data = payload.fileData {
        var buf = ByteBufferAllocator().buffer(capacity: data.count)
        buf.writeBytes(data)
        _ = try await client.createMessage(
            channelId: channelId,
            payload: Payloads.CreateMessage(
                content: payload.content,
                allowed_mentions: .init(parse: []),
                files: [RawFile(data: buf, filename: name)],
                attachments: [Payloads.Attachment(index: 0, filename: name)]
            )
        )
        return
    }
    if let content = payload.content {
        _ = try await client.createMessage(
            channelId: channelId,
            payload: .init(content: content, allowed_mentions: .init(parse: []))
        )
    }
}

// MARK: - permission buttons

/// Library `PermissionEmbedSpec` → DiscordBM `Embed` (same pattern as `AutoUpdateWiring.swift`'s
/// `discordEmbed(from: UpdateEmbedSpec)`).
func discordEmbed(from spec: PermissionEmbedSpec) -> Embed {
    Embed(
        title: spec.title,
        description: spec.description,
        color: DiscordColor(value: spec.color) ?? DiscordColor(value: DiscordColors.permission)
    )
}

/// The gate's presenter sink: post Allow / Always-Allow / Deny (TS permissionButtons 3-button row).
/// custom_id carries the reqKey so the click routes back to the same pending ask.
func postPermissionButtons(client: any DiscordClient, prompt: PermissionPrompt) async {
    // TS styles: allow=success, always=primary, deny=danger.
    let allow = Interaction.ActionRow.Button(
        style: .success,
        label: I18n.t("perm.button.allow"),
        custom_id: buildCustomId(reqKey: prompt.reqKey, action: .allow)
    )
    let always = Interaction.ActionRow.Button(
        style: .primary,
        label: I18n.t("perm.button.always"),
        custom_id: buildCustomId(reqKey: prompt.reqKey, action: .always)
    )
    let deny = Interaction.ActionRow.Button(
        style: .danger,
        label: I18n.t("perm.button.deny"),
        custom_id: buildCustomId(reqKey: prompt.reqKey, action: .deny)
    )
    let row: Interaction.ActionRow = [.button(allow), .button(always), .button(deny)]
    // Swift-only extra (TS has no equivalent): ping the bound approver in `content`, alongside the
    // embed (Discord allows both in one message). Not an H1/H2 concern — kept as-is.
    let mention = prompt.approverId.map { "<@\($0)>" }
    let embed = discordEmbed(from: PermissionEmbedSpec(
        title: I18n.t("perm.request.title"),
        description: I18n.t("perm.request.body", ["tool": prompt.toolName, "input": prompt.detail ?? ""]),
        color: DiscordColors.permission
    ))
    // C14: retry-wrapped (PermissionPrompt carries no guildId — onGone omitted, same as the
    // idle watchdog poster above).
    _ = await createMessageWithRetry(
        client: client,
        channelId: ChannelSnowflake(prompt.channelId),
        payload: .init(content: mention, embeds: [embed], components: [row])
    )
}

/// Persist an Always-Allow grant into global `autoAllowClaudeTools` + audit (TS wiring onAlwaysAllow).
/// Best-effort: config write failure must not break the interaction (turn is already allowed).
func persistAlwaysAllow(tool: String, actorId: String, guildId: String, channelId: String) async {
    await AuditLog.shared.record(AuditEntry(
        actorId: actorId,
        roleTier: "execute",
        guildId: guildId,
        channelId: channelId,
        action: "always-allow",
        tool: tool,
        status: "allowed"
    ))
    do {
        _ = try await ConfigStore.shared.addAutoAllowClaudeTool(tool)
    } catch {
        log.warn("failed to persist always-allow tool \(tool): \(error)")
    }
}

// MARK: - codex-smoke

/// Spawns real `codex app-server` if available, sends `initialize`.
/// Missing CLI → exit 0 with message (CI-friendly). Auth/backend failures after spawn → exit 0 with note.
func runCodexSmoke() async {
    print("dab codex-smoke: resolving spawn…")
    let spawn = resolveCodexSpawn()
    print("  command: \(spawn.command) \(spawn.args.joined(separator: " "))")

    // Fail soft if codex not on PATH
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    which.arguments = ["which", spawn.command.contains("/") ? spawn.command : "codex"]
    // When command is an absolute path, probe isExecutable instead of which.
    if spawn.command.contains("/") {
        if !FileManager.default.isExecutableFile(atPath: spawn.command) {
            fputs("dab codex-smoke: codex not found at \(spawn.command) — skip (exit 0)\n", stderr)
            exit(0)
        }
    } else {
        which.standardOutput = FileHandle.nullDevice
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            if which.terminationStatus != 0 {
                fputs("dab codex-smoke: `codex` CLI not found on PATH — skip (exit 0)\n", stderr)
                fputs("  install Codex CLI and/or set CODEX_CMD\n", stderr)
                exit(0)
            }
        } catch {
            fputs("dab codex-smoke: cannot probe codex — skip (exit 0)\n", stderr)
            exit(0)
        }
    }

    let client: CodexAppServerClient
    do {
        client = try CodexAppServerClient(spawn: spawn, requestTimeoutMs: 15_000)
    } catch {
        fputs("dab codex-smoke: spawn failed: \(error)\n", stderr)
        // ENOENT-style failures are soft
        let msg = String(describing: error)
        if msg.contains("No such file") || msg.contains("not found") {
            fputs("dab codex-smoke: treating as codex missing — exit 0\n", stderr)
            exit(0)
        }
        exit(1)
    }

    print("dab codex-smoke: initialize…")
    do {
        let result = try await client.initialize()
        print("dab codex-smoke: initialize OK result=\(result)")
        await client.close()
        print("dab codex-smoke: PASS")
        exit(0)
    } catch let err as AppServerError {
        print("dab codex-smoke: initialize error: \(err.message)")
        print("dab codex-smoke: spawn worked; backend/auth may need `codex login` — acceptable for smoke")
        await client.close()
        exit(0)
    } catch {
        fputs("dab codex-smoke: initialize failed: \(error)\n", stderr)
        await client.close()
        exit(1)
    }
}

// MARK: - grok-smoke

/// Spawns real `grok agent stdio` if available, sends `initialize`.
/// Missing CLI → exit 0 with message (CI-friendly). Auth/backend failures after spawn → exit 0 with note.
func runGrokSmoke() async {
    print("dab grok-smoke: resolving spawn…")
    let spawn = resolveGrokSpawn()
    print("  command: \(spawn.command) \(spawn.args.joined(separator: " "))")

    if spawn.command.contains("/") {
        if !FileManager.default.isExecutableFile(atPath: spawn.command) {
            fputs("dab grok-smoke: grok not found at \(spawn.command) — skip (exit 0)\n", stderr)
            exit(0)
        }
    } else {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", spawn.command]
        which.standardOutput = FileHandle.nullDevice
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            if which.terminationStatus != 0 {
                fputs("dab grok-smoke: `\(spawn.command)` CLI not found on PATH — skip (exit 0)\n", stderr)
                fputs("  install Grok CLI and/or set GROK_CMD\n", stderr)
                exit(0)
            }
        } catch {
            fputs("dab grok-smoke: cannot probe grok — skip (exit 0)\n", stderr)
            exit(0)
        }
    }

    let client: GrokAcpClient
    do {
        client = try GrokAcpClient(spawn: spawn, requestTimeoutMs: 15_000)
    } catch {
        fputs("dab grok-smoke: spawn failed: \(error)\n", stderr)
        let msg = String(describing: error)
        if msg.contains("No such file") || msg.contains("not found") {
            fputs("dab grok-smoke: treating as grok missing — exit 0\n", stderr)
            exit(0)
        }
        exit(1)
    }

    print("dab grok-smoke: initialize…")
    do {
        let result = try await client.initialize()
        print("dab grok-smoke: initialize OK result=\(result)")
        await client.close()
        print("dab grok-smoke: PASS")
        exit(0)
    } catch let err as AcpClientError {
        print("dab grok-smoke: initialize error: \(err.message)")
        print("dab grok-smoke: spawn worked; backend/auth may need `grok login` — acceptable for smoke")
        await client.close()
        exit(0)
    } catch {
        fputs("dab grok-smoke: initialize failed: \(error)\n", stderr)
        await client.close()
        exit(1)
    }
}

// MARK: - attach-mcp (C5)
//
// Minimal stdio MCP server for attach_file / share_document — the "discord" server that
// `grok agent stdio` spawns as ITS OWN child per GrokSessionBridge's `mcpServers` config
// (command = this same `dab` binary, args = ["attach-mcp"]). Talks to GrokAttachGateway over
// loopback HTTP via DAB_ATTACH_URL/DAB_ATTACH_TOKEN (never logged). Mirrors
// scripts/dab-discord-attach-mcp.mjs 1:1, native instead of Node — Grok must not gain a hard
// Node dependency for a mainline (non-opt-in) backend feature (see H5 in the parity audit).

private let attachMcpTools: JSONValue = .array([
    .object([
        "name": .string("attach_file"),
        "description": .string(
            "Send a file from the workspace to the Discord channel for this session. Path must be inside the workspace. Create the file first if needed."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace-relative or absolute path inside workspace"),
                ]),
                "filename": .object([
                    "type": .string("string"),
                    "description": .string("Optional display name"),
                ]),
            ]),
            "required": .array([.string("path")]),
        ]),
    ]),
    .object([
        "name": .string("share_document"),
        "description": .string(
            "Post a markdown document from the workspace into a Discord thread. Path must be inside the workspace; only a confirmation is returned, never the document body."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the markdown file to share (inside the session workspace)"),
                ]),
            ]),
            "required": .array([.string("path")]),
        ]),
    ]),
])

func runAttachMcpStdio() async {
    let env = ProcessInfo.processInfo.environment
    let attachURL = env["DAB_ATTACH_URL"] ?? ""
    let token = env["DAB_ATTACH_TOKEN"] ?? ""
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let msg) = decoded
        else { continue }
        await handleAttachMcpMessage(msg, attachURL: attachURL, token: token)
    }
}

private func writeAttachMcpLine(_ obj: [String: JSONValue]) {
    guard let data = try? JSONEncoder().encode(JSONValue.object(obj)), let s = String(data: data, encoding: .utf8) else { return }
    print(s)
    fflush(stdout)
}

private func toolCallResult(id: JSONValue, text: String, isError: Bool) -> [String: JSONValue] {
    [
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ]),
    ]
}

private func handleAttachMcpMessage(_ msg: [String: JSONValue], attachURL: String, token: String) async {
    let id = msg["id"]
    let method = msg["method"]?.stringValue ?? ""
    switch method {
    case "initialize":
        guard let id else { return }
        writeAttachMcpLine([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("discord"), "version": .string("1.0.0")]),
            ]),
        ])
    case "notifications/initialized", "initialized", "$/cancelRequest":
        return  // notifications — no response
    case "ping":
        guard let id else { return }
        writeAttachMcpLine(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
    case "tools/list":
        guard let id else { return }
        writeAttachMcpLine(["jsonrpc": .string("2.0"), "id": id, "result": .object(["tools": attachMcpTools])])
    case "tools/call":
        guard let id else { return }
        let params = msg["params"]
        let name = params?["name"]?.stringValue ?? ""
        guard name == "attach_file" || name == "share_document" else {
            writeAttachMcpLine(toolCallResult(id: id, text: "Unknown tool: \(name)", isError: true))
            return
        }
        let args = params?["arguments"]?.objectValue ?? [:]
        let path = args["path"]?.stringValue ?? ""
        guard !path.isEmpty else {
            writeAttachMcpLine(toolCallResult(id: id, text: "\(name) requires a path.", isError: true))
            return
        }
        let filename = args["filename"]?.stringValue
        let result = await postAttachMcp(
            endpoint: name == "share_document" ? "/share" : "/attach",
            attachURL: attachURL, token: token, path: path, filename: filename
        )
        writeAttachMcpLine(toolCallResult(id: id, text: result.text, isError: !result.ok))
    default:
        if let id {
            writeAttachMcpLine([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .number(-32601), "message": .string("Method not found: \(method)")]),
            ])
        }
    }
}

/// One POST to the attach gateway → {ok, text}. Both attach_file and share_document route
/// through it (TS dab-discord-attach-mcp.mjs postJson/postAttach/postShare 1:1).
private func postAttachMcp(endpoint: String, attachURL: String, token: String, path: String, filename: String?) async -> (ok: Bool, text: String) {
    guard !attachURL.isEmpty, !token.isEmpty else {
        return (false, "Attach gateway is not configured (missing DAB_ATTACH_URL/TOKEN).")
    }
    let base = attachURL.hasSuffix("/") ? String(attachURL.dropLast()) : attachURL
    guard let url = URL(string: base + endpoint) else {
        return (false, "Attach gateway URL is invalid.")
    }
    var bodyObj: [String: JSONValue] = ["token": .string(token), "path": .string(path)]
    if endpoint == "/attach", let filename, !filename.isEmpty {
        bodyObj["filename"] = .string(filename)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(JSONValue.object(bodyObj))
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpOk = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let obj) = decoded else {
            return (false, "Attach gateway returned non-JSON response (HTTP \(httpOk ? "ok" : "error")).")
        }
        let text = obj["text"]?.stringValue ?? (httpOk ? "ok" : "failed")
        let ok = obj["ok"]?.boolValue ?? httpOk
        return (ok, text)
    } catch {
        return (false, "Failed to reach attach gateway: \(error.localizedDescription)")
    }
}

// MARK: - sidecar-smoke

/// Spawns real Node sidecar (if available), waits for ready, session.start.
/// SDK/login failures are OK — protocol handshake is the goal.
func runSidecarSmoke() async {
    print("dab sidecar-smoke: resolving spawn…")
    let spawn = resolveClaudeSidecarSpawn()
    print("  command: \(spawn.command) \(spawn.args.joined(separator: " "))")

    // Fail fast if node missing
    let nodeCheck = Process()
    nodeCheck.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    nodeCheck.arguments = ["which", "node"]
    nodeCheck.standardOutput = FileHandle.nullDevice
    nodeCheck.standardError = FileHandle.nullDevice
    do {
        try nodeCheck.run()
        nodeCheck.waitUntilExit()
        if nodeCheck.terminationStatus != 0 {
            fputs("dab sidecar-smoke: node not found — skip (exit 0 for CI)\n", stderr)
            exit(0)
        }
    } catch {
        fputs("dab sidecar-smoke: cannot probe node — skip\n", stderr)
        exit(0)
    }

    let client: ClaudeSidecarClient
    do {
        client = try ClaudeSidecarClient(spawn: spawn, requestTimeoutMs: 30_000)
    } catch {
        fputs("dab sidecar-smoke: spawn failed: \(error)\n", stderr)
        exit(1)
    }

    print("dab sidecar-smoke: waiting for sidecar.ready…")
    do {
        try await client.connect()
        print("dab sidecar-smoke: ready OK")
    } catch {
        fputs("dab sidecar-smoke: connect failed: \(error)\n", stderr)
        await client.close()
        exit(1)
    }

    print("dab sidecar-smoke: session.start…")
    do {
        let result = try await client.sessionStart(
            SessionStartParams(
                cwd: "/tmp",
                guildId: "smoke-guild",
                channelId: "smoke-channel",
                permMode: "default"
            )
        )
        print("dab sidecar-smoke: session.start OK session=\(result.session) backend=\(result.backendSessionId ?? "null")")
        do {
            try await client.sessionStop(session: result.session)
            print("dab sidecar-smoke: session.stop OK")
        } catch {
            print("dab sidecar-smoke: session.stop: \(error) (ignored)")
        }
        await client.close()
        print("dab sidecar-smoke: PASS")
        exit(0)
    } catch let err as SidecarRpcError {
        // Protocol worked; SDK may reject without Claude login
        print("dab sidecar-smoke: session.start RPC error code=\(err.code) message=\(err.message)")
        print("dab sidecar-smoke: protocol handshake OK (start failed at backend — acceptable)")
        await client.close()
        exit(0)
    } catch {
        fputs("dab sidecar-smoke: session.start failed: \(error)\n", stderr)
        await client.close()
        exit(1)
    }
}
