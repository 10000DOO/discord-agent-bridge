import DiscordAgentBridge
import DiscordBM
import Foundation

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

        // Wire the permission-button presenter once: the gate (library) posts Allow / Always-Allow /
        // Deny to the prompt's channel via the Discord client. Set before events flow.
        let client = bot.client
        await PermissionGate.shared.setPresenter { prompt in
            await postPermissionButtons(client: client, prompt: prompt)
        }

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
        await registerAgentCommand(appId: payload.application.id)
        await restoreSessionBindings()
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
            // (A2) W11-b2 wizard components (folder browser + select steps; owner-gated).
            if isWizardCustomId(comp.custom_id) {
                try await handleWizardComponent(payload, comp: comp)
                return
            }
            return
        }

        // (B) Slash — agent/mode/model/effort/stop/clear/stop-all (TS ACTION_TIER; drive except stop-all).
        guard let cmd = try? payload.data?.requireApplicationCommand() else { return }
        let channelId = payload.channel_id?.rawValue ?? ""
        let guildId = payload.guild_id?.rawValue ?? "dm"
        let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
        let authAction: AuthAction = cmd.name == "stop-all" ? .admin : .drive
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(
                userId: actorId,
                roleIds: payload.member?.roles.map(\.rawValue) ?? [],
                action: authAction,
                guildId: payload.guild_id?.rawValue,
                channelId: channelId,
                isAdministrator: payload.member?.permissions?.contains(.administrator) ?? false
            )
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
            try await respondEphemeral(payload, "권한이 없습니다: \(decision.reason ?? "unauthorized")")
            return
        }
        let tier = decision.tier?.rawValue ?? "execute"
        let stubCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let life = SessionLifecycle.shared

        switch cmd.name {
        case "stop":
            _ = await life.stopChannel(
                channelId: channelId, actorId: actorId, guildId: guildId, roleTier: tier
            )
            try await respondEphemeral(payload, "세션을 종료했습니다.")

        case "stop-all":
            let count = await life.stopAll(actorId: actorId, guildId: guildId, roleTier: tier)
            try await respondEphemeral(payload, "세션 \(count)개를 모두 종료했습니다.")

        case "clear":
            // PLAN §14.6: keep config, wipe backendSessionId + live bridges (not full unbind).
            let ok = await life.clearChannel(
                channelId: channelId, actorId: actorId, guildId: guildId,
                roleTier: tier, defaultCwd: stubCwd
            )
            try await respondEphemeral(
                payload,
                ok ? "대화 컨텍스트를 초기화했습니다. (설정 유지, 다음 메시지부터 새 세션)"
                   : "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요."
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
            try await respondEphemeral(
                payload,
                ok ? "모델을 `\(value)`(으)로 바꿨습니다. (다음 턴/ensure에 적용)"
                   : "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요."
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
                ok ? "추론 강도를 `\(value)`(으)로 바꿨습니다. (다음 턴/ensure에 적용)"
                   : "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요."
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
                let ok = await life.rebindBackend(
                    channelId: channelId, backend: backend,
                    actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
                )
                try await respondEphemeral(
                    payload,
                    ok ? "백엔드를 \(backend.rawValue)(으)로 전환했습니다. (컨텍스트 초기화)"
                       : "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요."
                )
            case "perm":
                guard let value = try? sub.requireOption(named: "value").requireString(), !value.isEmpty else {
                    try await respondEphemeral(payload, "perm 값이 필요합니다.")
                    return
                }
                let ok = await life.updateBinding(
                    channelId: channelId, patch: BindingPatch(permMode: value),
                    actorId: actorId, guildId: guildId, roleTier: tier, defaultCwd: stubCwd
                )
                try await respondEphemeral(
                    payload,
                    ok ? "권한 모드를 `\(value)`(으)로 바꿨습니다."
                       : "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요."
                )
            default:
                try await respondEphemeral(payload, "알 수 없는 서브커맨드: \(sub.name)")
            }

        case "agent":
            guard let sub = cmd.options?.first else { return }
            switch sub.name {
            case "start":
                // W11-b2: folder browser → backend→model→effort→perm.
                // Browser starts at DAB_CWD else home; unbounded (no allowedRoots) like TS default.
                // nativePanel: package is macOS-only → always wire host picker (dir:panel).
                let ownerId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
                let optionSource = await loadWizardOptionSource()
                let browser = DirectoryBrowser(startPath: stubCwd, nativePanel: true)
                let wizard = ChannelWizard(
                    guildId: guildId,
                    channelId: channelId,
                    ownerId: ownerId,
                    browser: browser,
                    options: optionSource
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
                try await respondEphemeral(payload, "이 채널의 세션을 종료하고 바인딩을 해제했습니다.")
            case "resume":
                // W11-d minimal: re-bind registry from non-archived store row (no wizard).
                if let cfg = await life.resumeBinding(channelId: channelId) {
                    try await respondEphemeral(
                        payload,
                        "저장된 \(cfg.backend.rawValue) 세션을 다시 바인딩했습니다."
                    )
                } else {
                    try await respondEphemeral(payload, "이 채널에 재개할 세션이 없습니다.")
                }
            case "stats":
                let lines = formatStatsLines(bindings: await life.listActiveBindings())
                let count = lines.count == 1 && lines[0] == "(none)" ? 0 : lines.count
                let content =
                    "**활성 세션** (\(count))\n" + lines.joined(separator: "\n")
                // W11-g slice2: Claude usage embed when OAuth credentials are available.
                let usage = await ClaudeUsageService.shared.getUsage()
                if let spec = buildUsageEmbed(usage: usage, ctxUsage: nil) {
                    try await respondEphemeral(payload, content, embeds: [discordEmbed(from: spec)])
                } else {
                    try await respondEphemeral(payload, content)
                }
            default:
                try await respondEphemeral(payload, "알 수 없는 서브커맨드: \(sub.name)")
            }
        default:
            return
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

    /// Prefer persisted session ownerId; fall back to the message author (drive path).
    private func resolveOwnerId(channelId: String, messageAuthorId: String) async -> String {
        if let o = await SessionStore.shared.binding(channelId: channelId)?.ownerId, !o.isEmpty {
            return o
        }
        return messageAuthorId
    }

    /// W11-b2: drive the channel's agent-start wizard from a select/button click (dir:* + choice steps).
    /// Owner gate: only the user who opened the wizard may advance it.
    /// dir:create / dir:manual open modals (showModal = ack). dir:panel defers then native pick.
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
            if let p = wizard.startParams {
                await bindFromWizard(p)
                let extra = [
                    p.model.isEmpty ? nil : "model=\(p.model)",
                    p.effort.isEmpty ? nil : "effort=\(p.effort)",
                    p.permMode.isEmpty ? nil : "perm=\(p.permMode)",
                ].compactMap { $0 }.joined(separator: " ")
                let text = "이 채널이 \(p.backend.rawValue) 세션에 바인딩됨"
                    + (extra.isEmpty ? "" : " (\(extra))")
                    + ". cwd=\(p.cwd). 이제 접두사 없이 메시지를 보내면 됩니다."
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .updateMessage(.init(content: text, embeds: [], components: []))
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

    /// Modal submits for dir:create (mkdir+into) and dir:manual (goTo).
    private func handleWizardModal(_ payload: Interaction, modal: Interaction.ModalSubmit) async throws {
        let channelId = payload.channel_id?.rawValue ?? ""
        let clicker = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
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

    /// Registry bind + store upsert (same shape as the pre-wizard `/agent start` path).
    private func bindFromWizard(_ p: WizardStartParams) async {
        let model = p.model.isEmpty ? nil : p.model
        let effort = p.effort.isEmpty ? nil : p.effort
        let perm = p.permMode.isEmpty ? nil : p.permMode
        await SessionRegistry.shared.bind(
            channelId: p.channelId,
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
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try? await SessionStore.shared.upsert(channelId: p.channelId, record)
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        // Ignore bots / webhooks
        if payload.author?.bot == true { return }
        if payload.webhook_id != nil { return }

        let channelId = payload.channel_id.rawValue
        let binding = await SessionRegistry.shared.binding(channelId: channelId)
        switch routeDecision(content: payload.content, binding: binding) {
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
        let decision = await Authorizer(config: .shared).authorize(
            AuthInput(userId: actorId, roleIds: payload.member?.roles?.map(\.rawValue) ?? [], action: .drive, guildId: payload.guild_id?.rawValue, channelId: channelId, isAdministrator: false)
        )
        let tier = decision.tier?.rawValue ?? "none"
        guard decision.allowed else {
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "drive", mode: backend.rawValue, outcome: decision.reason, status: "denied"))
            _ = try? await client.createMessage(channelId: payload.channel_id, payload: .init(content: "권한이 없습니다: \(decision.reason ?? "unauthorized")"))
            return
        }

        print("dab: \(backend.rawValue) channel=\(channelId) prompt=\(text.prefix(80))")
        do {
            let turn: TurnResult
            switch backend {
            case .claude:
                turn = try await DabSessionBridge.shared.runTurn(
                    channelId: channelId,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    ownerId: payload.author?.id.rawValue,
                    text: text,
                    config: binding
                )
            case .codex:
                turn = try await CodexSessionBridge.shared.runTurn(channelId: channelId, ownerId: payload.author?.id.rawValue, guildId: payload.guild_id?.rawValue ?? "dm", text: text, config: binding)
            case .grok:
                turn = try await GrokSessionBridge.shared.runTurn(channelId: channelId, ownerId: payload.author?.id.rawValue, guildId: payload.guild_id?.rawValue ?? "dm", text: text, config: binding)
            }
            // W16-a: multi-message chunking (TS chunkMessage) — never truncate long replies.
            let body = turn.text.isEmpty ? "(no text)" : turn.text
            for chunk in DiscordText.chunkMessage(body) {
                _ = try await client.createMessage(channelId: payload.channel_id, payload: .init(content: chunk))
            }
            // W11-g slice1: optional done-line footer (cost/tokens/duration) after answer chunks.
            if let usage = turn.usage, let line = buildResultLine(usage) {
                _ = try? await client.createMessage(channelId: payload.channel_id, payload: .init(content: line))
            }
            // W11-g slice2: context_usage summary line when the bridge captured one.
            if let ctx = turn.contextUsage {
                _ = try? await client.createMessage(
                    channelId: payload.channel_id,
                    payload: .init(content: formatContextUsageLine(ctx))
                )
            }
            // W11-g slice2: rate_limit notice (event fields; enrich with Claude usage snapshot if any).
            if let rl = turn.rateLimit {
                let usageSnap = backend == .claude ? await ClaudeUsageService.shared.getUsage() : nil
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
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "turn", mode: backend.rawValue, permMode: binding?.permMode, status: "ok"))
        } catch {
            // Same chunking on error path so huge error text is not truncated.
            let msg = "⚠️ \(error.localizedDescription)"
            print("dab: \(backend.rawValue) turn failed: \(error)")
            for chunk in DiscordText.chunkMessage(msg) {
                _ = try? await client.createMessage(channelId: payload.channel_id, payload: .init(content: chunk))
            }
            await AuditLog.shared.record(AuditEntry(actorId: actorId, roleTier: tier, guildId: guildId, channelId: channelId, action: "turn", mode: backend.rawValue, permMode: binding?.permMode, outcome: error.localizedDescription, status: "error"))
        }
    }
}

// MARK: - permission buttons

/// The gate's presenter sink: post Allow / Always-Allow / Deny (TS permissionButtons 3-button row).
/// custom_id carries the reqKey so the click routes back to the same pending ask.
func postPermissionButtons(client: any DiscordClient, prompt: PermissionPrompt) async {
    // TS styles: allow=success, always=primary, deny=danger.
    let allow = Interaction.ActionRow.Button(
        style: .success, label: "Allow", custom_id: buildCustomId(reqKey: prompt.reqKey, action: .allow)
    )
    let always = Interaction.ActionRow.Button(
        style: .primary, label: "Always-Allow", custom_id: buildCustomId(reqKey: prompt.reqKey, action: .always)
    )
    let deny = Interaction.ActionRow.Button(
        style: .danger, label: "Deny", custom_id: buildCustomId(reqKey: prompt.reqKey, action: .deny)
    )
    let row: Interaction.ActionRow = [.button(allow), .button(always), .button(deny)]
    let detail = prompt.detail.map { ": `\($0)`" } ?? ""
    let mention = prompt.approverId.map { " <@\($0)>" } ?? ""
    let content = "🔐 권한 요청\(mention): **\(prompt.toolName)**\(detail)"
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
