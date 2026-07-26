import DiscordAgentBridge
import DiscordBM
import Foundation

/// Process-wide AutoUpdater handle (created after gateway ready so postPrompt can use the client).
actor AutoUpdaterRegistry {
    static let shared = AutoUpdaterRegistry()
    private var updater: AutoUpdater?

    func set(_ u: AutoUpdater) { updater = u }
    func get() -> AutoUpdater? { updater }
}

// MARK: - DiscordBM mapping

func discordEmbed(from spec: UpdateEmbedSpec) -> Embed {
    Embed(
        title: spec.title,
        description: spec.description,
        color: DiscordColor(value: spec.color) ?? DiscordColor(value: DiscordColors.permission)
    )
}

func discordActionRows(from rows: [UpdateComponentRow]) -> [Interaction.ActionRow] {
    rows.map { row in
        let comps: [Interaction.ActionRow.Component] = row.components.map { b in
            let style: Interaction.ActionRow.Button.NonLinkStyle = {
                switch b.style {
                case .success: return .success
                case .secondary: return .secondary
                }
            }()
            return .button(Interaction.ActionRow.Button(
                style: style,
                label: b.label,
                custom_id: b.customId,
                disabled: b.disabled ? true : nil
            ))
        }
        return Interaction.ActionRow(components: comps)
    }
}

// MARK: - Build + start

/// Wire AutoUpdater ports over ConfigStore + SessionStore + Discord control channels, then start.
func startAutoUpdater(client: any DiscordClient) async {
    let version = readAppVersion()
    let dryRun = ProcessInfo.processInfo.environment["DAB_UPDATE_DRY_RUN"] == "1"
    let updater = AutoUpdater(deps: AutoUpdaterDeps(
        currentVersion: version,
        enabled: {
            (try? await ConfigStore.shared.load())?.autoUpdate.enabled ?? true
        },
        fetchLatest: {
            await fetchLatestVersion(opts: FetchLatestOptions(
                userAgent: "discord-agent-bridge-swift/\(readAppVersion())"
            ))
        },
        readMeta: {
            await SessionStore.shared.getUpdateMeta()
        },
        writeMeta: { patch in
            try? await SessionStore.shared.setUpdateMeta(patch)
        },
        postPrompt: { latest in
            await postUpdatePromptToControlChannels(client: client, latest: latest)
        },
        announce: { text in
            await announceToControlChannels(client: client, text: text)
        },
        install: {
            await installLatestSelfUpdate(
                dryRun: dryRun,
                onLog: { msg in
                    print("dab: \(msg)")
                    Task {
                        await AuditLog.shared.record(AuditEntry(
                            actorId: "system",
                            roleTier: "admin",
                            guildId: "-",
                            channelId: "-",
                            action: "auto-update",
                            outcome: msg,
                            status: msg.contains("failed") || msg.contains("empty") ? "error" : "ok"
                        ))
                    }
                }
            )
        },
        restart: {
            if dryRun {
                print("dab: auto-update dry-run — skip restart")
                return
            }
            let strategy = detectRestartStrategy(RestartDetectDeps())
            performRestart(
                RestartPerformDeps(
                    strategy: strategy,
                    runKickstart: { launchctlKickstart() },
                    spawnDetached: { path, args in spawnDetachedDab(path: path, args: args) },
                    exitProcess: { code in Foundation.exit(code) }
                ),
                onLog: { print("dab: \($0)") }
            )
        },
        messages: .korean,
        onLog: { msg in print("dab: \(msg)") }
    ))
    await AutoUpdaterRegistry.shared.set(updater)
    await updater.start()
    print("dab: auto-updater started (version \(version)\(dryRun ? ", DAB_UPDATE_DRY_RUN" : ""))")
}

func postUpdatePromptToControlChannels(client: any DiscordClient, latest: String) async {
    let current = readAppVersion()
    let (embedSpec, rows) = buildUpdatePrompt(version: latest, currentVersion: current)
    let embed = discordEmbed(from: embedSpec)
    let components = discordActionRows(from: rows)
    let guildIds = await ConfigStore.shared.listServerGuildIds()
    for guildId in guildIds {
        guard let server = await ConfigStore.shared.loadServerConfig(guildId: guildId),
              let controlId = server.channels?.controlChannelId,
              !controlId.isEmpty
        else { continue }
        let adminRoles = server.auth?.adminRoleIds ?? []
        let content: String
        if adminRoles.isEmpty {
            content = "@here"
        } else {
            content = adminRoles.map { "<@&\($0)>" }.joined(separator: " ")
        }
        // C14: retry-wrapped. onGone omitted — a control channel has no session binding to
        // clean up (TS never does so either; a stale controlChannelId config entry is a
        // separate, pre-existing concern this WO does not touch).
        _ = await createMessageWithRetry(
            client: client,
            channelId: ChannelSnowflake(controlId),
            payload: .init(content: content, embeds: [embed], components: components)
        )
    }
}

func announceToControlChannels(client: any DiscordClient, text: String) async {
    let guildIds = await ConfigStore.shared.listServerGuildIds()
    for guildId in guildIds {
        guard let server = await ConfigStore.shared.loadServerConfig(guildId: guildId),
              let controlId = server.channels?.controlChannelId,
              !controlId.isEmpty
        else { continue }
        // C14: retry-wrapped (control channel — no session binding to clean up, see above).
        _ = await createMessageWithRetry(
            client: client,
            channelId: ChannelSnowflake(controlId),
            payload: .init(content: text)
        )
    }
}

func formatUpdateCheckReply(_ result: UpdateCheckResult) -> String {
    let cur = result.currentVersion
    switch result.kind {
    case .disabled:
        return UpdateLabels.disabled + " (현재 `\(cur)`)"
    case .fetchFailed:
        return UpdateLabels.checkFailed + " (현재 `\(cur)`)"
    case .upToDate:
        let latest = result.latestVersion.map { " / 레지스트리 `\($0)`" } ?? ""
        return "\(UpdateLabels.upToDate) 현재 `\(cur)`\(latest)"
    case .dismissed:
        let latest = result.latestVersion ?? "?"
        return "새 버전 `\(latest)` 이(가) 있지만 무시됨 (현재 `\(cur)`). 더 새 버전이 나오면 다시 알려드려요."
    case .available:
        let latest = result.latestVersion ?? "?"
        return "새 버전 `\(latest)` 사용 가능 (현재 `\(cur)`)."
    }
}
