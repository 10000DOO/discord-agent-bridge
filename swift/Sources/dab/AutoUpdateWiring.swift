import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "auto-update")

/// Process-wide AutoUpdater handle (created after gateway ready so postPrompt can use the client).
extension AutoUpdaterRegistry {
    static let shared = AutoUpdaterRegistry()
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
                    log.info(msg)
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
        restart: { request in
            if dryRun {
                log.info("auto-update dry-run — skip restart")
                return .manualRestartRequired
            }
            let strategy = detectRestartStrategy(RestartDetectDeps())
            // Source/install.sh path only. Homebrew installs never reach here: approve blocks
            // dual path when DAB_INSTALL_METHOD=homebrew (self-update.sh owns install+restart).
            return await performRestart(
                RestartPerformDeps(
                    strategy: strategy,
                    runKickstart: {
                        relaunchSupervisedService(
                            applicationId: request.applicationId,
                            interactionToken: request.interactionToken
                        )
                    },
                    spawnDetached: { path, args, environment in
                        spawnDetachedDab(path: path, args: args, environment: environment)
                    },
                    exitProcess: { code in Foundation.exit(code) }
                ),
                onLog: { log.info($0) },
                onConfirmed: {
                    if let updater = await AutoUpdaterRegistry.shared.get() {
                        await updater.clearPendingRestart()
                    }
                    await request.notify(UpdateLabels.restartConfirmed)
                }
            )
        },
        homebrewTrigger: { applicationId, interactionToken in
            // Exclusive Homebrew path: install+restart owned by tap script (avoids double restart).
            triggerHomebrewSelfUpdateIfConfigured(applicationId: applicationId, interactionToken: interactionToken)
        },
        messages: .korean,
        onLog: { msg in log.info(msg) }
    ))
    await AutoUpdaterRegistry.shared.startReplacing(with: updater)
    log.info("auto-updater started (version \(version)\(dryRun ? ", DAB_UPDATE_DRY_RUN" : ""))")
}

func postUpdatePromptToControlChannels(client: any DiscordClient, latest: String) async -> Bool {
    let current = readAppVersion()
    let (embedSpec, rows) = buildUpdatePrompt(version: latest, currentVersion: current)
    let embed = discordEmbed(from: embedSpec)
    let components = discordActionRows(from: rows)
    let guildIds = await ConfigStore.shared.listServerGuildIds()
    var delivered = false
    for guildId in guildIds {
        guard let server = await ConfigStore.shared.loadServerConfig(guildId: guildId),
              let controlId = server.channels?.controlChannelId,
              !controlId.isEmpty
        else { continue }
        // Update approval is deliberately the one broadcast exception: operators chose to
        // notify everyone currently present in the control channel, not just admin roles.
        let content = "@here"
        // C14: retry-wrapped. onGone omitted — a control channel has no session binding to
        // clean up (TS never does so either; a stale controlChannelId config entry is a
        // separate, pre-existing concern this WO does not touch).
        if await createMessageWithRetry(
            client: client,
            channelId: ChannelSnowflake(controlId),
            payload: .init(
                content: content,
                embeds: [embed],
                allowed_mentions: .init(parse: [.everyone]),
                components: components
            )
        ) != nil {
            delivered = true
        }
    }
    return delivered
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
        return UpdateLabels.disabled + I18n.t("update.check.current", ["version": cur])
    case .fetchFailed:
        return UpdateLabels.checkFailed + I18n.t("update.check.current", ["version": cur])
    case .upToDate:
        let latest = result.latestVersion.map { I18n.t("update.check.registrySuffix", ["version": $0]) } ?? ""
        return "\(UpdateLabels.upToDate)\(I18n.t("update.check.upToDateCurrent", ["version": cur]))\(latest)"
    case .dismissed:
        let latest = result.latestVersion ?? "?"
        return I18n.t("update.check.dismissed", ["latest": latest, "current": cur])
    case .available:
        let latest = result.latestVersion ?? "?"
        return I18n.t("update.check.available", ["latest": latest, "current": cur])
    }
}
