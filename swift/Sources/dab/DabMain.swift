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
        print("dab: !dab <prompt> → Claude sidecar (DAB_CWD / DAB_PERM_MODE)")

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
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        // Ignore bots / webhooks
        if payload.author?.bot == true { return }
        if payload.webhook_id != nil { return }

        let content = payload.content

        // !codex <prompt> → Codex app-server (parallel to !dab; W10-c1). !dab path unchanged.
        if content.hasPrefix("!codex ") {
            await handleCodexMessage(payload, content: content)
            return
        }

        // !grok <prompt> → Grok ACP (parallel to !dab; W10-c3). !dab/!codex paths unchanged.
        if content.hasPrefix("!grok ") {
            await handleGrokMessage(payload, content: content)
            return
        }

        let prefix = "!dab "
        guard content.hasPrefix(prefix) else { return }

        let prompt = String(content.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: "Usage: `!dab <prompt>`")
            )
            return
        }

        let channelId = payload.channel_id.rawValue
        let guildId = payload.guild_id?.rawValue ?? "dm"
        let ownerId = payload.author?.id.rawValue

        print("dab: !dab channel=\(channelId) prompt=\(prompt.prefix(80))")

        do {
            let reply = try await DabSessionBridge.shared.runTurn(
                channelId: channelId,
                guildId: guildId,
                ownerId: ownerId,
                text: prompt
            )
            let body = DiscordText.clip(reply.isEmpty ? "(no text)" : reply)
            _ = try await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: body)
            )
        } catch {
            let msg = DiscordText.clip("⚠️ \(error.localizedDescription)")
            print("dab: turn failed: \(error)")
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: msg)
            )
        }
    }

    /// Parallel to the `!dab` handling above, routed to the Codex bridge (W10-c1).
    func handleCodexMessage(_ payload: Gateway.MessageCreate, content: String) async {
        let prefix = "!codex "
        let prompt = String(content.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: "Usage: `!codex <prompt>`")
            )
            return
        }

        let channelId = payload.channel_id.rawValue
        print("dab: !codex channel=\(channelId) prompt=\(prompt.prefix(80))")

        do {
            let reply = try await CodexSessionBridge.shared.runTurn(channelId: channelId, text: prompt)
            let body = DiscordText.clip(reply.isEmpty ? "(no text)" : reply)
            _ = try await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: body)
            )
        } catch {
            let msg = DiscordText.clip("⚠️ \(error.localizedDescription)")
            print("dab: codex turn failed: \(error)")
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: msg)
            )
        }
    }

    /// Parallel to the `!codex` handling above, routed to the Grok bridge (W10-c3).
    func handleGrokMessage(_ payload: Gateway.MessageCreate, content: String) async {
        let prefix = "!grok "
        let prompt = String(content.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: "Usage: `!grok <prompt>`")
            )
            return
        }

        let channelId = payload.channel_id.rawValue
        print("dab: !grok channel=\(channelId) prompt=\(prompt.prefix(80))")

        do {
            let reply = try await GrokSessionBridge.shared.runTurn(channelId: channelId, text: prompt)
            let body = DiscordText.clip(reply.isEmpty ? "(no text)" : reply)
            _ = try await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: body)
            )
        } catch {
            let msg = DiscordText.clip("⚠️ \(error.localizedDescription)")
            print("dab: grok turn failed: \(error)")
            _ = try? await client.createMessage(
                channelId: payload.channel_id,
                payload: .init(content: msg)
            )
        }
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
