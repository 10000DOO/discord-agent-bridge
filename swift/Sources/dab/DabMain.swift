import DiscordAgentBridge
import DiscordBM
import Foundation
import NIOCore

@main
struct DabMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
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

        guard let token = DiscordToken.resolve() else {
            fputs(DiscordToken.usage + "\n", stderr)
            exit(1)
        }

        let bot = await BotGatewayManager(
            token: token,
            intents: [.guilds, .guildMessages, .messageContent]
        )

        print("dab: connecting to Discord gateway…")
        print("dab: !claude <prompt> → Claude sidecar (DAB_CWD / DAB_PERM_MODE)")

        // G-P1-08: process-wide UI language from config.locale (default ko).
        if let cfg = try? await ConfigStore.shared.load() {
            I18n.applyFromConfigLocale(cfg.locale)
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
        // W16-g: tool_use / tool_result → Discord work threads (+ diffs) via createThread.
        await ToolActivityHost.shared.setChannelFactory { channelId in
            turnThreadChannel(client: client, channelId: channelId)
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
            _ = try? await client.createMessage(
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
            }
            group.addTask {
                for await event in await bot.events {
                    await EventHandler(event: event, client: bot.client).handleAsync()
                }
            }
        }
    }
}

struct EventHandler: GatewayEventHandler {
    let event: Gateway.Event
    let client: any DiscordClient

    func onReady(_ payload: Gateway.Ready) async throws {
        let user = payload.user
        print("ready: username=\(user.username) id=\(user.id) app=\(payload.application.id)")
        // G-P1-07: remember bot user id for Manage Channels checks on subsequent GuildCreate.
        // READY only carries UnavailableGuild stubs; full guilds arrive as GuildCreate (boot + join).
        await BotGatewayIdentity.shared.setUserId(user.id.rawValue)
        print("dab: auto-provision will run on GuildCreate for \(payload.guilds.count) guild stub(s)")
        await registerAgentCommand(appId: payload.application.id)
        await restoreSessionBindings()
        // W16-h: version check schedule (posts to control channels when a newer stable exists).
        await startAutoUpdater(client: client)
    }

    /// G-P1-07: auto-provision channel structure on every guild the bot is in (fires after Ready
    /// for existing guilds, and again when the bot is invited). Manage-Channels-guarded + non-throwing.
    func onGuildCreate(_ payload: Gateway.GuildCreate) async throws {
        if payload.unavailable == true { return }
        let guildId = payload.id.rawValue
        let botId = await BotGatewayIdentity.shared.getUserId()
        let canManage = botCanManageChannels(guild: payload, botUserId: botId)
        // Never throws — autoProvisionGuild swallows create failures so one guild never kills ready.
        await runAutoProvisionGuild(client: client, guildId: guildId, manageChannels: canManage)
    }

    /// G5: on boot, load persisted sessions and repopulate the routing map so prefix-less messages
    /// reach the saved backend. Does NOT spawn any backend — resume is lazy on the first message.
    /// Skips archived bindings (TS resumeAll filters `archived == true`).
    private func restoreSessionBindings() async {
        await SessionStore.shared.load()
        let active = await SessionStore.shared.active()
        for (channelId, ps) in active {
            await SessionRegistry.shared.bind(
                channelId: channelId,
                SessionConfig(backend: ps.backend, model: ps.model, effort: ps.effort, permMode: ps.permMode)
            )
        }
        print("dab: restored \(active.count) session binding(s) from store")
    }

    /// Register slash commands (W11-d set). Dev: instant per-guild via `DAB_DEV_GUILD_ID`; else global (~1h).
    private func registerAgentCommand(appId: ApplicationSnowflake) async {
        let cmds = allCommandPayloads()
        do {
            if let g = ProcessInfo.processInfo.environment["DAB_DEV_GUILD_ID"], !g.isEmpty {
                _ = try await client.bulkSetGuildApplicationCommands(appId: appId, guildId: GuildSnowflake(g), payload: cmds)
                print("dab: registered \(cmds.map(\.name).joined(separator: ", ")) to guild \(g)")
            } else {
                _ = try await client.bulkSetApplicationCommands(appId: appId, payload: cmds)
                print("dab: registered \(cmds.map(\.name).joined(separator: ", ")) globally (propagation ~1h)")
            }
        } catch {
            print("dab: slash register failed: \(error)")
        }
    }

    func onInteractionCreate(_ payload: Interaction) async throws {
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
                let alwaysTool = action == .always ? await PermissionGate.shared.peekToolName(reqKey) : nil
                let accepted = await PermissionGate.shared.resolve(reqKey: reqKey, action: action, byUserId: userId)
                if accepted {
                    if action == .always, let tool = alwaysTool, !tool.isEmpty {
                        await persistAlwaysAllow(
                            tool: tool,
                            actorId: userId ?? "",
                            guildId: payload.guild_id?.rawValue ?? "dm",
                            channelId: payload.channel_id?.rawValue ?? ""
                        )
                    }
                    let label: String
                    switch action {
                    case .allow: label = "ALLOW"
                    case .always: label = "ALWAYS-ALLOW"
                    case .deny: label = "DENY"
                    }
                    // Replace the buttons with the outcome (idempotent, removes the buttons).
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .updateMessage(.init(content: "🔐 \(label) — <@\(userId ?? "")>", components: []))
                    )
                } else {
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .channelMessageWithSource(.init(content: "이 결정은 세션 승인자만 할 수 있어요 (또는 이미 처리됨/만료).", flags: [.ephemeral]))
                    )
                }
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
        let authAction: AuthAction = (cmd.name == "stop-all" || cmd.name == "setup" || cmd.name == "config" || cmd.name == "update")
            ? .admin : .drive
        // G-P0-05: per-project ACL from store narrows (nil = no extra gate).
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(
                userId: actorId,
                roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                action: authAction,
                guildId: payload.guild_id?.rawValue,
                channelId: channelId,
                isAdministrator: payload.member?.permissions?.contains(.administrator) ?? false
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

        switch cmd.name {
        case "stop":
            _ = await life.stopChannel(
                channelId: channelId, actorId: actorId, guildId: guildId, roleTier: tier
            )
            try await respondEphemeral(payload, I18n.t("cmd.stop.done"))

        case "stop-all":
            let count = await life.stopAll(actorId: actorId, guildId: guildId, roleTier: tier)
            try await respondEphemeral(payload, I18n.t("cmd.stopAll.done", ["count": "\(count)"]))

        case "clear":
            // PLAN §14.6: keep config, wipe backendSessionId + live bridges (not full unbind).
            let ok = await life.clearChannel(
                channelId: channelId, actorId: actorId, guildId: guildId,
                roleTier: tier, defaultCwd: stubCwd
            )
            try await respondEphemeral(
                payload,
                ok ? I18n.t("cmd.clear.done") : noSession
            )

        case "model":
            guard let value = try? cmd.requireOption(named: "value").requireString(), !value.isEmpty else {
                try await respondEphemeral(payload, "model 값이 필요합니다.")
                return
            }
            let ok = await life.updateBinding(
                channelId: channelId, patch: BindingPatch(model: value),
                actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
            )
            // Claude live session: updateBinding also fires session.setModel (W11-g).
            try await respondEphemeral(
                payload,
                ok ? I18n.t("cmd.model.switched", ["model": value]) : noSession
            )

        case "effort":
            guard let value = try? cmd.requireOption(named: "value").requireString(), !value.isEmpty else {
                try await respondEphemeral(payload, "effort 값이 필요합니다.")
                return
            }
            let ok = await life.updateBinding(
                channelId: channelId, patch: BindingPatch(effort: value),
                actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
            )
            try await respondEphemeral(
                payload,
                ok ? I18n.t("cmd.effort.switched", ["effort": value]) : noSession
            )

        case "mode":
            guard let sub = cmd.options?.first else { return }
            switch sub.name {
            case "backend":
                guard let raw = try? sub.requireOption(named: "backend").requireString(),
                      let backend = Backend(rawValue: raw)
                else {
                    try await respondEphemeral(payload, "알 수 없는 backend")
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
                    let ok = await life.rebindBackend(
                        channelId: channelId, backend: backend,
                        actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
                    )
                    try await respondEphemeral(
                        payload,
                        ok
                            ? I18n.t("cmd.mode.switched", ["backend": backend.rawValue])
                            : noSession
                    )
                    if ok, let ch = payload.channel_id {
                        _ = try? await client.createMessage(
                            channelId: ch,
                            payload: .init(content:
                                I18n.t("cmd.mode.freshContext", ["backend": backend.rawValue])
                            )
                        )
                    }
                    return
                }
                // Different backend: DO NOT stop the running session (R1/R4). Open reconfigure
                // popup (model → effort → perm); stop+rebind only on perm.start confirm.
                let ownerId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
                let cwd = storeRow?.cwd ?? stubCwd
                let permMode = storeRow?.permMode ?? regRow?.permMode ?? "default"
                let optionSource = await loadWizardOptionSource()
                // G-P1-06: same favorites confinement as /agent start (reconfigure rarely uses folder).
                let favorites = (try? await ConfigStore.shared.load())?.favorites ?? []
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
                    // Omit model/effort → seed NEW backend defaults; carry cwd/perm from binding.
                    entry: WizardEntry(backend: backend, cwd: cwd, permMode: permMode)
                )
                await WizardRegistry.shared.put(wizard, channelId: channelId)
                let (embeds, components) = discordPayload(from: wizard.render())
                _ = try await client.createInteractionResponse(
                    id: payload.id,
                    token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        embeds: embeds,
                        flags: [.ephemeral],
                        components: components
                    ))
                )
            case "perm":
                // G-P1-04 / TS switchPerm: known config.profiles name → profile + bundled
                // permissionMode; otherwise raw permMode (existing permissionProfile kept).
                guard let value = try? sub.requireOption(named: "value").requireString(), !value.isEmpty else {
                    try await respondEphemeral(payload, "perm 값이 필요합니다.")
                    return
                }
                let profiles = (try? await ConfigStore.shared.load())?.profiles ?? [:]
                let resolved = resolveModePerm(value: value, profiles: profiles)
                let ok = await life.updateBinding(
                    channelId: channelId, patch: resolved.bindingPatch,
                    actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
                )
                try await respondEphemeral(
                    payload,
                    ok ? I18n.t("cmd.perm.switched", ["perm": resolved.display]) : noSession
                )
            default:
                try await respondEphemeral(payload, "알 수 없는 서브커맨드: \(sub.name)")
            }

        case "agent":
            guard let sub = cmd.options?.first else { return }
            switch sub.name {
            case "start":
                // W11-b2: folder → [preset if any] → backend→model→effort→perm.
                // G-P1-06: config.favorites → browseRoots/allowedRoots; empty → unbounded (TS Fix 1).
                // Browser starts at DAB_CWD else home (clamped to first root when bounded).
                // nativePanel: package is macOS-only → always wire host picker (dir:panel).
                let ownerId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
                let optionSource = await loadWizardOptionSource()
                let favorites = (try? await ConfigStore.shared.load())?.favorites ?? []
                let roots = browseRoots(fromFavorites: favorites)
                let browser = DirectoryBrowser(
                    allowedRoots: roots,
                    startPath: stubCwd,
                    nativePanel: true
                )
                let serverPresets = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.presets ?? []
                let guildForPresets = guildId
                let wizard = ChannelWizard(
                    guildId: guildId,
                    channelId: channelId,
                    ownerId: ownerId,
                    browser: browser,
                    options: optionSource,
                    presets: serverPresets,
                    onDeletePreset: { name in
                        Task {
                            _ = try? await ConfigStore.shared.removeServerPreset(
                                guildId: guildForPresets, name: name
                            )
                        }
                    },
                    backendAvailable: { Backend(rawValue: $0) != nil }
                )
                await WizardRegistry.shared.put(wizard, channelId: channelId)
                let (embeds, components) = discordPayload(from: wizard.render())
                _ = try await client.createInteractionResponse(
                    id: payload.id,
                    token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        embeds: embeds,
                        flags: [.ephemeral],
                        components: components
                    ))
                )
            case "close":
                // W14: real stop (backend + unbind) — was unbind-only and leaked processes.
                _ = await life.stopChannel(
                    channelId: channelId, actorId: actorId, guildId: guildId, roleTier: tier
                )
                // Reply BEFORE delete so the ephemeral ack lands (TS slashCommands.close).
                try await respondEphemeral(payload, I18n.t("cmd.close.done"))
                // G-P0-04: A4D dedicated session channel best-effort delete (never control/status/category).
                if let realGuildId = payload.guild_id?.rawValue {
                    let serverChannels = await ConfigStore.shared
                        .loadServerConfig(guildId: realGuildId)?.channels
                    var chName: String?
                    var parentId: String?
                    if let ch = try? await client.getChannel(id: ChannelSnowflake(channelId)).decode() {
                        chName = ch.name
                        parentId = ch.parent_id?.rawValue
                    }
                    await deleteSessionChannel(
                        provisioner: resolveGuildProvisioner(client: client, guildId: realGuildId),
                        channelId: channelId,
                        channelName: chName,
                        parentId: parentId,
                        serverChannels: serverChannels
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
                let dismissed = meta.dismissedVersion.map { " · 무시 `\($0)`" } ?? ""
                let activeHeading = I18n.t("stats.active", ["n": "\(count)"])
                let content =
                    "**\(activeHeading)**\n" + lines.joined(separator: "\n")
                    + "\n**버전** `\(readAppVersion())`\(dismissed)"
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
                try await respondEphemeral(payload, "알 수 없는 서브커맨드: \(sub.name)")
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
                let control = existing?.controlChannelId ?? ""
                try await respondEphemeral(
                    payload,
                    I18n.t("cmd.setup.alreadyDone", ["control": "<#\(control)>"])
                )
                return
            }
            do {
                let channels = try await ensureGuildChannels(provisioner: provisioner, configStore: store)
                try await respondEphemeral(
                    payload,
                    I18n.t("cmd.setup.done", ["control": "<#\(channels.controlChannelId)>"])
                )
            } catch {
                print("dab: /setup failed guild=\(realGuildId): \(error)")
                try await respondEphemeral(payload, I18n.t("cmd.setup.unavailable"))
            }

        case "config":
            // W16-b: ephemeral settings panel (role tiers + defaults + dmPolicy). Admin only.
            guard let realGuildId = payload.guild_id?.rawValue else {
                try await respondEphemeral(payload, I18n.t("auth.denied", ["reason": "DM"]))
                return
            }
            let store = ConfigStore.shared
            let global: AppConfig
            do {
                global = try await store.load()
            } catch {
                try await respondEphemeral(
                    payload,
                    "config.json을 읽을 수 없어요. 설정 파일을 확인하세요: \(error)"
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
            // Catalog snapshot for model/effort/perm selects (fallback-safe; no live probe required).
            let backendEnum = Backend(rawValue: panelDefaults.backend) ?? .claude
            let catalog = providerCatalog(for: backendEnum)
            let configuredModel = backendEnum == .codex
                ? global.defaults.codexModel
                : global.defaults.claudeModel
            var models = await catalog.models(configured: configuredModel.isEmpty ? nil : configuredModel)
            if !panelDefaults.model.isEmpty,
               !models.contains(where: { $0.value == panelDefaults.model }) {
                models.insert(ModelChoice(value: panelDefaults.model, label: panelDefaults.model), at: 0)
            }
            if models.isEmpty {
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
            _ = try await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: I18n.t("cmd.config.opened"),
                    embeds: embeds,
                    flags: [.ephemeral],
                    components: roleRows
                ))
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
                try await respondEphemeral(payload, "path 값이 필요합니다.")
                return
            }
            let regBound = await SessionRegistry.shared.binding(channelId: channelId) != nil
            let storeSession = await SessionStore.shared.binding(channelId: channelId)
            let hasBinding = regBound || (storeSession.map { !$0.archived } ?? false)
            guard hasBinding else {
                try await respondEphemeral(payload, I18n.t("router.noSession"))
                return
            }
            do {
                let res = try await postDocumentShare(client: client, channelId: channelId, path: docPath)
                try await respondEphemeral(payload, formatDocShareReply(path: docPath, result: res))
            } catch {
                print("dab: /doc failed channel=\(channelId): \(error)")
                try await respondEphemeral(payload, "문서 공유에 실패했어요. 잠시 후 다시 시도하세요.")
            }

        case "update":
            // W16-h: admin version check; if available, show Yes/No prompt ephemerally.
            guard let updater = await AutoUpdaterRegistry.shared.get() else {
                try await respondEphemeral(payload, "업데이터가 아직 준비되지 않았어요. 잠시 후 다시 시도하세요.")
                return
            }
            // post:false — we reply here with embed+buttons instead of fanning out to control channels.
            let result = await updater.checkNow(post: false)
            let text = formatUpdateCheckReply(result)
            if result.kind == .available, let latest = result.latestVersion {
                let (embedSpec, rows) = buildUpdatePrompt(version: latest, currentVersion: result.currentVersion)
                _ = try await client.createInteractionResponse(
                    id: payload.id,
                    token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: text,
                        embeds: [discordEmbed(from: embedSpec)],
                        flags: [.ephemeral],
                        components: discordActionRows(from: rows)
                    ))
                )
            } else {
                try await respondEphemeral(payload, text)
            }

        default:
            return
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
            ack: { [client] text in
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: text, flags: [.ephemeral])
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
        print("dab: channelDelete → stop channel=\(channelId) guild=\(guildId.rawValue)")
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

    /// G-P1-03: `/model` · `/effort` autocomplete from providerCatalog (channel binding backend,
    /// else claude). Best-effort respond — Discord's ~3s window has no defer.
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
        switch cmd.name {
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

    /// Prefer persisted session ownerId; fall back to the message author (drive path).
    private func resolveOwnerId(channelId: String, messageAuthorId: String) async -> String {
        if let o = await SessionStore.shared.binding(channelId: channelId)?.ownerId, !o.isEmpty {
            return o
        }
        return messageAuthorId
    }

    /// W16-b: drive the open `/config` panel. Owner-gated. Roles batch until Save;
    /// backend/model/effort/permMode/dmPolicy auto-save; 🔔 notifications sub-panel.
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
        // Admin gate (same as /config open). Discord Administrator always widens.
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(
                userId: clicker,
                roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                action: .admin,
                guildId: guildId,
                channelId: channelId,
                isAdministrator: payload.member?.permissions?.contains(.administrator) ?? false
            ),
            projectAuth: projectAuth
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
        case .renderUpdated(let sub):
            let (embeds, rows) = discordPayload(from: sub)
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: rows))
            )
        case .renderInstall:
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .deferredUpdateMessage()
            )
            do {
                try await ConfigStore.shared.setChromiumDecision("accepted")
                let path = try await ImageRenderHost.shared.install()
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: "Chromium ready: `\(path)` — tables/mermaid will render as PNG.",
                        flags: [.ephemeral]
                    )
                )
            } catch {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: "Chromium install failed: \(error). System Chrome or `npx` required.",
                        flags: [.ephemeral]
                    )
                )
            }
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
                        content: "마법사 세션이 없습니다. `/agent start`로 다시 열어주세요.",
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            guard wizard.ownerId == clicker else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: "이 마법사는 연 사람만 조작할 수 있어요.",
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
                    content: "재개 마법사 세션이 없습니다. `/agent start` → 세션 재개로 다시 열어주세요.",
                    flags: [.ephemeral]
                ))
            )
            return
        }
        guard flow.ownerId == clicker else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: "이 마법사는 연 사람만 조작할 수 있어요.",
                    flags: [.ephemeral]
                ))
            )
            return
        }

        let value = comp.values?.first
        let step = await flow.handle(WizardInput(id: comp.custom_id, value: value))
        switch step {
        case .done:
            await ResumeWizardRegistry.shared.remove(channelId: channelId)
            await WizardRegistry.shared.remove(channelId: channelId)
            let bound = flow.sessionChannelId() ?? channelId
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(
                    content: I18n.t("resume.done", ["channel": "<#\(bound)>"]),
                    embeds: [],
                    components: []
                ))
            )
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
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(
                    content: I18n.t("resume.none"),
                    embeds: [],
                    components: []
                ))
            )
        case .cancelled:
            await ResumeWizardRegistry.shared.remove(channelId: channelId)
            await WizardRegistry.shared.remove(channelId: channelId)
            let (embeds, _) = discordPayload(from: flow.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: []))
            )
        default:
            let (embeds, components) = discordPayload(from: flow.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: components))
            )
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
                    content: "마법사 세션이 없습니다. `/agent start`로 다시 열어주세요.",
                    flags: [.ephemeral]
                ))
            )
            return
        }
        guard wizard.ownerId == clicker else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: "이 마법사는 연 사람만 조작할 수 있어요.",
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
                    title: "새 폴더 만들기",
                    textInputs: [
                        .init(
                            custom_id: "name",
                            style: .short,
                            label: "폴더 이름",
                            required: true,
                            placeholder: "예: my-project"
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
                    title: "경로 직접 입력",
                    textInputs: [
                        .init(
                            custom_id: "path",
                            style: .short,
                            label: "절대 경로",
                            required: true,
                            placeholder: "예: /Volumes/SourceCode/MyProject"
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

        let value = comp.values?.first
        let step = wizard.handle(WizardInput(id: comp.custom_id, value: value))

        switch step {
        case .done:
            await WizardRegistry.shared.remove(channelId: channelId)
            if wizard.isReconfigure() {
                // Backend-switch confirm: stop live session then rebind same channel (TS switchSession).
                if let p = wizard.startParams {
                    let model = p.model.isEmpty ? nil : p.model
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
                    let text = ok
                        ? "백엔드를 \(p.backend.rawValue) 로 바꿨어요."
                        : "전환 실패: 이 채널에 바인딩된 세션이 없습니다."
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .updateMessage(.init(content: text, embeds: [], components: []))
                    )
                    if ok, let ch = payload.channel_id {
                        _ = try? await client.createMessage(
                            channelId: ch,
                            payload: .init(content:
                                "⚠️ \(p.backend.rawValue) 로 바꾸면 이 채널은 새 대화로 시작돼요. 이전 맥락은 안 넘어갑니다."
                            )
                        )
                    }
                } else {
                    _ = try? await client.createInteractionResponse(
                        id: payload.id, token: payload.token,
                        payload: .updateMessage(.init(content: "전환 실패 (선택 없음).", embeds: [], components: []))
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
                await bindFromWizard(p, channelId: bindChannelId)

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
                        model: p.model.isEmpty ? nil : p.model,
                        effort: p.effort.isEmpty ? nil : p.effort,
                        permMode: p.permMode.isEmpty ? nil : p.permMode
                    )
                    let draftKey = PresetDraftRegistry.key(guildId: guildId, channelId: channelId)
                    await PresetDraftRegistry.shared.set(draft, key: draftKey)
                    saveRows = [
                        Interaction.ActionRow(components: [
                            .button(Interaction.ActionRow.Button(
                                style: .secondary,
                                label: "💾 프리셋으로 저장",
                                custom_id: "preset.save"
                            )),
                        ]),
                    ]
                }

                // Ephemeral wizard reply: link to session channel (TS cmd.start.channelCreated).
                let replyText: String
                if bindChannelId != p.channelId {
                    replyText = "세션 채널 생성됨: <#\(bindChannelId)>"
                } else {
                    let extra = [
                        p.model.isEmpty ? nil : "model=\(p.model)",
                        p.effort.isEmpty ? nil : "effort=\(p.effort)",
                        p.permMode.isEmpty ? nil : "perm=\(p.permMode)",
                    ].compactMap { $0 }.joined(separator: " ")
                    replyText = "이 채널이 \(p.backend.rawValue) 세션에 바인딩됨"
                        + (extra.isEmpty ? "" : " (\(extra))")
                        + ". cwd=\(p.cwd). 이제 접두사 없이 메시지를 보내면 됩니다."
                }
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .updateMessage(.init(
                        content: replyText,
                        embeds: [],
                        components: saveRows.isEmpty ? [] : saveRows
                    ))
                )
                // Intro + status embed on the bound session channel (TS postSessionIntro).
                // W16-g residual: best-effort pin so status stays at the top of the channel.
                _ = await postSessionStatusIntro(
                    client: client,
                    channelId: ChannelSnowflake(bindChannelId),
                    content: sessionStatusIntroContent,
                    embed: statusEmbed
                )
            } else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .updateMessage(.init(content: "시작 실패 (선택 없음).", embeds: [], components: []))
                )
            }
        case .cancelled:
            await WizardRegistry.shared.remove(channelId: channelId)
            let (embeds, _) = discordPayload(from: wizard.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: []))
            )
        default:
            let (embeds, components) = discordPayload(from: wizard.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .updateMessage(.init(embeds: embeds, components: components))
            )
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
                payload: .init(content: "이미 폴더 선택 창이 열려 있어요. Mac 화면을 확인하세요.", flags: [.ephemeral])
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
                content: "🖥️ Mac 화면에 폴더 선택 창을 열었어요. Mac에서 폴더를 선택하세요… (2분 내)",
                flags: [.ephemeral]
            )
        )
        do {
            let picked = try await openMacFolderPanel(startDir: wizard.browserCwd())
            if picked == nil {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(content: "폴더 선택을 취소했어요.", flags: [.ephemeral])
                )
                return
            }
            guard let path = picked, wizard.browserGoTo(path) else {
                _ = try? await client.createFollowupMessage(
                    appId: payload.application_id,
                    token: payload.token,
                    payload: .init(
                        content: "이동할 수 없는 경로예요: `\(picked ?? "")` (존재하지 않거나, 폴더가 아니거나, 허용 범위 밖).",
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
                    content: "경로로 이동했어요: `\(wizard.browserCwd())`\n`✅ 이 폴더로 시작`을 눌러 이 폴더에서 세션을 시작하세요.",
                    flags: [.ephemeral]
                )
            )
        } catch let err as FolderPanelError {
            let text: String
            switch err {
            case .timeout:
                text = "폴더 선택 창을 2분이 지나 닫았어요. Mac 앞에 있을 때 사용하세요."
            case .failed(let msg):
                text = "폴더 선택 창을 열지 못했어요: \(msg)"
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
                payload: .init(content: "폴더 선택 창을 열지 못했어요: \(error)", flags: [.ephemeral])
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
                    content: "저장할 최근 세션 설정이 없어요.",
                    flags: [.ephemeral]
                ))
            )
            return
        }
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .modal(.init(
                custom_id: "preset.name",
                title: "프리셋 저장",
                textInputs: [
                    .init(
                        custom_id: "name",
                        style: .short,
                        label: "프리셋 이름",
                        required: true,
                        placeholder: "예: claude-opus-plan"
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

        guard let wizard = await WizardRegistry.shared.get(channelId: channelId),
              wizard.ownerId == clicker
        else {
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: "마법사 세션이 없습니다. `/agent start`로 다시 열어주세요.",
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
                        content: "폴더를 만들었어요: \(name)",
                        embeds: embeds,
                        flags: [.ephemeral],
                        components: components
                    ))
                )
            case .invalidName, .escaped:
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: "폴더 이름이 올바르지 않아요. `/`, `..`, 절대 경로는 쓸 수 없어요.",
                        flags: [.ephemeral]
                    ))
                )
            case .failed(let err):
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: "폴더를 만들지 못했어요: \(err)",
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
                        content: "절대 경로를 입력하세요 (예: `/Users/...` 또는 `/Volumes/...`).",
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            if !wizard.browserGoTo(input) {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(
                        content: "이동할 수 없는 경로예요: `\(input)` (존재하지 않거나, 폴더가 아니거나, 허용 범위 밖).",
                        flags: [.ephemeral]
                    ))
                )
                return
            }
            let (embeds, components) = discordPayload(from: wizard.render())
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: "경로로 이동했어요: `\(wizard.browserCwd())`\n`✅ 이 폴더로 시작`을 눌러 이 폴더에서 세션을 시작하세요.",
                    embeds: embeds,
                    flags: [.ephemeral],
                    components: components
                ))
            )
        default:
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(content: "알 수 없는 모달입니다.", flags: [.ephemeral]))
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
                    content: "저장할 최근 세션 설정이 없어요.",
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
                    content: "프리셋 이름은 1~100자여야 해요.",
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
                    content: "프리셋을 저장했어요: \(name)",
                    flags: [.ephemeral]
                ))
            )
        } catch {
            // Keep draft so a retry can still save.
            _ = try? await client.createInteractionResponse(
                id: payload.id, token: payload.token,
                payload: .channelMessageWithSource(.init(
                    content: "프리셋 저장 실패: \(error)",
                    flags: [.ephemeral]
                ))
            )
        }
    }

    /// Registry bind + store upsert. `channelId` defaults to wizard params (same channel);
    /// A4D start path passes the newly created session channel id when available.
    private func bindFromWizard(_ p: WizardStartParams, channelId: String? = nil) async {
        let model = p.model.isEmpty ? nil : p.model
        let effort = p.effort.isEmpty ? nil : p.effort
        let perm = p.permMode.isEmpty ? nil : p.permMode
        let bindId = channelId ?? p.channelId
        // G-P0-05: carry binding-resident projectAuth across REPLACE (TS start()).
        let existing = await SessionStore.shared.binding(channelId: bindId)
        await SessionRegistry.shared.bind(
            channelId: bindId,
            SessionConfig(backend: p.backend, model: model, effort: effort, permMode: perm)
        )
        let record = PersistedSession(
            backend: p.backend,
            backendSessionId: nil,
            cwd: p.cwd,
            guildId: p.guildId,
            ownerId: p.ownerId.isEmpty ? nil : p.ownerId,
            model: model,
            effort: effort,
            permMode: perm,
            permissionProfile: existing?.permissionProfile,
            projectAuth: existing?.projectAuth,
            createdAt: existing?.createdAt,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            archived: false
        )
        try? await SessionStore.shared.upsert(channelId: bindId, record)
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        // Ignore bots / webhooks
        if payload.author?.bot == true { return }
        if payload.webhook_id != nil { return }

        let channelId = payload.channel_id.rawValue
        let binding = await SessionRegistry.shared.binding(channelId: channelId)
        let hasAttachments = !payload.attachments.isEmpty
        switch routeDecision(content: payload.content, binding: binding, hasAttachments: hasAttachments) {
        case .ignore:
            return
        case .usage(let label):
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: "Usage: `\(label) <prompt>`")
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
        // routes (prefix*/bound) converge on (D4). Message path grants NO Administrator promotion
        // (Q2) — the gateway message event does not carry member.permissions, so isAdministrator
        // stays false (fail-secure); only role tiers / dmPolicy apply.
        // G-P0-05: store projectAuth intersects (narrows only) when present on the binding.
        let projectAuth = await SessionStore.shared.binding(channelId: channelId)?.projectAuth
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(userId: actorId, roleIds: payload.member?.roles?.map(\.rawValue) ?? [], action: .drive, guildId: payload.guild_id?.rawValue, channelId: channelId, isAdministrator: false),
            projectAuth: projectAuth
        )
        let tier = decision.tier?.rawValue ?? "none"
        guard decision.allowed else {
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "drive", mode: backend.rawValue, outcome: decision.reason, status: "denied"))
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: I18n.t("auth.denied", ["reason": decision.reason ?? "unauthorized"]))
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
                print("dab: attachment download failed channel=\(channelId) err=\(error)")
                _ = try? await client.createMessage(
                    channelId: payload.channel_id,
                    payload: .init(content: "첨부 처리 실패: \(error)")
                )
                return
            }
        }

        print("dab: \(backend.rawValue) channel=\(channelId) prompt=\(text.prefix(80)) files=\(turnFiles.count)")
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
        do {
            let turn: TurnResult
            switch backend {
            case .claude, .custom:
                // custom: Claude sidecar path + shell-env overlay inside DabSessionBridge (W16-f).
                let cfg = binding ?? SessionConfig(backend: backend)
                turn = try await DabSessionBridge.shared.runTurn(
                    channelId: channelId,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    ownerId: payload.author?.id.rawValue,
                    text: text,
                    config: cfg,
                    files: turnFiles
                )
            case .codex:
                turn = try await CodexSessionBridge.shared.runTurn(
                    channelId: channelId,
                    ownerId: payload.author?.id.rawValue,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    text: text,
                    config: binding,
                    files: turnFiles
                )
            case .grok:
                turn = try await GrokSessionBridge.shared.runTurn(
                    channelId: channelId,
                    ownerId: payload.author?.id.rawValue,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    text: text,
                    config: binding,
                    files: turnFiles
                )
            }
            // G-P1-01: turn finished — cancel idle notice.
            await IdleWatchdog.shared.stop(channelId: channelId)
            // G-P0-02: ⏳ → ✅ on successful turn.
            await completeTurnReaction(
                client: client,
                channelId: payload.channel_id,
                messageId: payload.id,
                terminal: TurnReactions.done
            )
            await StreamStatusHost.shared.end(channelId: channelId)
            let toolCount = turn.tools.reduce(0) { $0 + $1.count }
            await finalizeInterruptControlMessage(
                client: client, channelId: payload.channel_id, messageId: controlMsgId,
                guildId: guildId, toolCount: toolCount
            )
            // W16-a + S3: deliverAnswer (chunkMessage; tables/mermaid → PNG when Chrome ready).
            let body = turn.text.isEmpty ? "(no text)" : turn.text
            let renderFn = await ImageRenderHost.shared.resolveRenderFn()
            let chId = payload.channel_id
            try await deliverAnswer(
                body,
                options: DeliverOptions(
                    renderImage: renderFn,
                    emit: { out in
                        try await emitDeliverPayload(client: client, channelId: chId, payload: out)
                    }
                )
            )
            // W11-g slice1: optional done-line footer (cost/tokens/duration) after answer chunks.
            if let usage = turn.usage, let line = buildResultLine(usage) {
                _ = try? await client.createMessage(channelId: payload.channel_id, payload: .init(content: line))
            }
            // W11-g slice2/4: usage embed — caps.usagePanel only (TS RendererDispatcher).
            var usageSnap: UsageResult? = nil
            if caps.usagePanel {
                switch backend {
                case .claude, .custom:
                    usageSnap = await ClaudeUsageService.shared.getUsage()
                case .grok:
                    usageSnap = await GrokUsageService.shared.getUsage()
                case .codex:
                    usageSnap = await CodexUsageService.shared.getUsage()
                }
                let usageTitle: String
                switch backend {
                case .claude, .custom: usageTitle = I18n.t("usage.title")
                case .grok: usageTitle = I18n.t("usage.title.grok")
                case .codex: usageTitle = I18n.t("usage.title.codex")
                }
                let embedExtras = UsageEmbedExtras(
                    meta: UsageSessionMeta(permMode: binding?.permMode),
                    title: usageTitle,
                    tools: turn.tools,
                    agents: turn.agents
                )
                if let spec = buildUsageEmbed(
                    usage: usageSnap,
                    ctxUsage: turn.contextUsage,
                    extras: embedExtras
                ) {
                    _ = try? await client.createMessage(
                        channelId: payload.channel_id,
                        payload: .init(embeds: [discordEmbed(from: spec)])
                    )
                } else if let ctx = turn.contextUsage {
                    // Fallback: plain context line when no panel fields (no OAuth / tools).
                    _ = try? await client.createMessage(
                        channelId: payload.channel_id,
                        payload: .init(content: formatContextUsageLine(ctx))
                    )
                }
            }
            // W11-g slice2: rate_limit notice (event fields; enrich with usage snapshot if any).
            // Always (not usagePanel-gated) — matches TS RendererDispatcher.rateLimit.
            if let rl = turn.rateLimit {
                let line = formatRateLimitLine(rl, usage: usageSnap)
                _ = try? await client.createMessage(
                    channelId: payload.channel_id,
                    payload: .init(content: line)
                )
            }
            // W11-g slice2: mentionOnComplete — ping session owner (binding) or message author.
            let ownerId = await resolveOwnerId(channelId: channelId, messageAuthorId: actorId)
            if let mention = mentionOnCompleteContent(ownerId: ownerId) {
                _ = try? await client.createMessage(
                    channelId: payload.channel_id,
                    payload: .init(content: mention)
                )
            }
            // W16-g: status-channel notification (result + rate_limit when present).
            let resultEv = AgentEvent.result(
                text: turn.text,
                costUsd: turn.usage?.costUsd,
                tokensIn: turn.usage?.tokensIn,
                tokensOut: turn.usage?.tokensOut,
                durationMs: turn.usage?.durationMs
            )
            await postStatusNotification(
                client: client, guildId: guildId, sessionChannelId: channelId, event: resultEv, backend: backend
            )
            if let rl = turn.rateLimit {
                let rlEv = AgentEvent.rateLimit(
                    resetAt: rl.resetAt, rateLimitType: rl.rateLimitType, utilization: rl.utilization
                )
                await postStatusNotification(
                    client: client, guildId: guildId, sessionChannelId: channelId, event: rlEv, backend: backend
                )
            }
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "turn", mode: backend.rawValue, permMode: binding?.permMode, status: "ok"))
        } catch {
            // G-P1-01: turn failed — cancel idle notice.
            await IdleWatchdog.shared.stop(channelId: channelId)
            // G-P0-02: ⏳ → ❌ on turn failure.
            await completeTurnReaction(
                client: client,
                channelId: payload.channel_id,
                messageId: payload.id,
                terminal: TurnReactions.error
            )
            await StreamStatusHost.shared.end(channelId: channelId)
            await finalizeInterruptControlMessage(
                client: client, channelId: payload.channel_id, messageId: controlMsgId,
                guildId: guildId
            )
            // Same chunking on error path so huge error text is not truncated.
            let msg = "⚠️ \(error.localizedDescription)"
            print("dab: \(backend.rawValue) turn failed: \(error)")
            for chunk in DiscordText.chunkMessage(msg) {
                _ = try? await client.createMessage(channelId: payload.channel_id, payload: .init(content: chunk))
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

/// Claude/custom → sidecar sessions.list; Codex/Grok → store best-effort (or empty).
func listResumableForBackend(_ backend: Backend, cwd: String) async -> [ResumableSession] {
    switch backend {
    case .claude, .custom:
        return await DabSessionBridge.shared.listResumableSessions(cwd: cwd)
    case .codex, .grok:
        let all = await SessionStore.shared.all()
        return listResumableFromStore(sessions: all, backend: backend, cwd: cwd)
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
        createdAt: existing?.createdAt,
        updatedAt: ISO8601DateFormatter().string(from: Date()),
        archived: existing?.archived ?? false
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
                files: [RawFile(data: buf, filename: name)],
                attachments: [Payloads.Attachment(index: 0, filename: name)]
            )
        )
        return
    }
    if let content = payload.content {
        _ = try await client.createMessage(
            channelId: channelId,
            payload: .init(content: content)
        )
    }
}

// MARK: - permission buttons

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
    let detail = prompt.detail.map { ": `\($0)`" } ?? ""
    let mention = prompt.approverId.map { " <@\($0)>" } ?? ""
    let content = "🔐 \(I18n.t("perm.request.title"))\(mention): **\(prompt.toolName)**\(detail)"
    _ = try? await client.createMessage(
        channelId: ChannelSnowflake(prompt.channelId),
        payload: .init(content: content, components: [row])
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
        fputs("dab: failed to persist always-allow tool \(tool): \(error)\n", stderr)
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
