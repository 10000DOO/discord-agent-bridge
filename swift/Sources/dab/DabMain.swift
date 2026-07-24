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

        // Wire the permission-button presenter once: the gate (library) posts Allow/Deny to the
        // prompt's channel via the Discord client. Set before events flow.
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
    private func restoreSessionBindings() async {
        await SessionStore.shared.load()
        let all = await SessionStore.shared.all()
        for (channelId, ps) in all {
            await SessionRegistry.shared.bind(
                channelId: channelId,
                SessionConfig(backend: ps.backend, model: ps.model, effort: ps.effort, permMode: ps.permMode)
            )
        }
        print("dab: restored \(all.count) session binding(s) from store")
    }

    /// Register `/agent`. Dev: instant per-guild via `DAB_DEV_GUILD_ID`; else global (~1h propagation).
    private func registerAgentCommand(appId: ApplicationSnowflake) async {
        let cmd = agentCommandPayload()
        do {
            if let g = ProcessInfo.processInfo.environment["DAB_DEV_GUILD_ID"], !g.isEmpty {
                _ = try await client.bulkSetGuildApplicationCommands(appId: appId, guildId: GuildSnowflake(g), payload: [cmd])
                print("dab: registered /agent to guild \(g)")
            } else {
                _ = try await client.bulkSetApplicationCommands(appId: appId, payload: [cmd])
                print("dab: registered /agent globally (propagation ~1h)")
            }
        } catch {
            print("dab: slash register failed: \(error)")
        }
    }

    func onInteractionCreate(_ payload: Interaction) async throws {
        // (A) Permission button click → resolve the gate. Only the session approver may decide.
        if let comp = try? payload.data?.requireMessageComponent(),
           let (reqKey, action) = parseCustomId(comp.custom_id) {
            let userId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue
            let accepted = await PermissionGate.shared.resolve(reqKey: reqKey, action: action, byUserId: userId)
            if accepted {
                // Replace the buttons with the outcome (idempotent, removes the buttons).
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .updateMessage(.init(content: "🔐 \(action.rawValue.uppercased()) — <@\(userId ?? "")>", components: []))
                )
            } else {
                _ = try? await client.createInteractionResponse(
                    id: payload.id, token: payload.token,
                    payload: .channelMessageWithSource(.init(content: "이 결정은 세션 승인자만 할 수 있어요 (또는 이미 처리됨/만료).", flags: [.ephemeral]))
                )
            }
            return
        }

        // (B) Slash command.
        guard let cmd = try? payload.data?.requireApplicationCommand(), cmd.name == "agent",
              let sub = cmd.options?.first
        else { return }
        let channelId = payload.channel_id?.rawValue ?? ""
        switch sub.name {
        case "start":
            guard let raw = try? sub.requireOption(named: "backend").requireString(),
                  let backend = Backend(rawValue: raw)
            else {
                try await respondEphemeral(payload, "알 수 없는 backend")
                return
            }
            let model = try? sub.requireOption(named: "model").requireString()
            let effort = try? sub.requireOption(named: "effort").requireString()
            let perm = try? sub.requireOption(named: "perm").requireString()
            await SessionRegistry.shared.bind(channelId: channelId, SessionConfig(backend: backend, model: model, effort: effort, permMode: perm))
            // Persist a routing stub (no backend id yet) so a restart restores this binding; the
            // first turn's bridge upsert overwrites it with the real backend session id (F7).
            let stubCwd = ProcessInfo.processInfo.environment["DAB_CWD"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            let ownerId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue
            let record = PersistedSession(backend: backend, backendSessionId: nil, cwd: stubCwd, guildId: payload.guild_id?.rawValue ?? "dm", ownerId: ownerId, model: model, effort: effort, permMode: perm, updatedAt: ISO8601DateFormatter().string(from: Date()))
            try? await SessionStore.shared.upsert(channelId: channelId, record)
            let extra = [model.map { "model=\($0)" }, effort.map { "effort=\($0)" }, perm.map { "perm=\($0)" }].compactMap { $0 }.joined(separator: " ")
            try await respondEphemeral(payload, "이 채널이 \(backend.rawValue) 세션에 바인딩됨\(extra.isEmpty ? "" : " (\(extra))"). 이제 접두사 없이 메시지를 보내면 됩니다.")
        case "close":
            await SessionRegistry.shared.unbind(channelId: channelId)
            try? await SessionStore.shared.remove(channelId: channelId)   // don't re-route after restart
            try await respondEphemeral(payload, "이 채널의 세션 바인딩을 해제했습니다.")
        default:
            try await respondEphemeral(payload, "알 수 없는 서브커맨드: \(sub.name)")
        }
    }

    private func respondEphemeral(_ payload: Interaction, _ text: String) async throws {
        _ = try await client.createInteractionResponse(
            id: payload.id,
            token: payload.token,
            payload: .channelMessageWithSource(.init(content: text, flags: [.ephemeral]))
        )
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
        print("dab: \(backend.rawValue) channel=\(channelId) prompt=\(text.prefix(80))")
        do {
            let reply: String
            switch backend {
            case .claude:
                reply = try await DabSessionBridge.shared.runTurn(
                    channelId: channelId,
                    guildId: payload.guild_id?.rawValue ?? "dm",
                    ownerId: payload.author?.id.rawValue,
                    text: text,
                    config: binding
                )
            case .codex:
                reply = try await CodexSessionBridge.shared.runTurn(channelId: channelId, ownerId: payload.author?.id.rawValue, guildId: payload.guild_id?.rawValue ?? "dm", text: text, config: binding)
            case .grok:
                reply = try await GrokSessionBridge.shared.runTurn(channelId: channelId, ownerId: payload.author?.id.rawValue, guildId: payload.guild_id?.rawValue ?? "dm", text: text, config: binding)
            }
            let body = DiscordText.clip(reply.isEmpty ? "(no text)" : reply)
            _ = try await client.createMessage(channelId: payload.channel_id, payload: .init(content: body))
        } catch {
            let msg = DiscordText.clip("⚠️ \(error.localizedDescription)")
            print("dab: \(backend.rawValue) turn failed: \(error)")
            _ = try? await client.createMessage(channelId: payload.channel_id, payload: .init(content: msg))
        }
    }
}

// MARK: - permission buttons

/// The gate's presenter sink: post Allow/Deny buttons to the prompt's channel. custom_id carries the
/// reqKey so the click routes back to the same pending ask (`parseCustomId` → `gate.resolve`).
func postPermissionButtons(client: any DiscordClient, prompt: PermissionPrompt) async {
    let allow = Interaction.ActionRow.Button(style: .primary, label: "Allow", custom_id: buildCustomId(reqKey: prompt.reqKey, action: .allow))
    let deny = Interaction.ActionRow.Button(style: .danger, label: "Deny", custom_id: buildCustomId(reqKey: prompt.reqKey, action: .deny))
    let row: Interaction.ActionRow = [.button(allow), .button(deny)]
    let detail = prompt.detail.map { ": `\($0)`" } ?? ""
    let mention = prompt.approverId.map { " <@\($0)>" } ?? ""
    let content = "🔐 권한 요청\(mention): **\(prompt.toolName)**\(detail)"
    _ = try? await client.createMessage(
        channelId: ChannelSnowflake(prompt.channelId),
        payload: .init(content: content, components: [row])
    )
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
