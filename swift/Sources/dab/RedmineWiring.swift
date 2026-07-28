import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "redmine")

// MARK: - Build + start (WO-10, mirrors AutoUpdateWiring.swift)

/// Wire RedminePollerDeps over ConfigStore + RedmineClient + the guild's `#redmine-report`
/// channel, for a single guild.
func buildRedminePollerDeps(client: any DiscordClient, guildId: String) -> RedminePollerDeps {
    RedminePollerDeps(
        guildId: guildId,
        loadConfig: {
            await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine
        },
        decryptApiKey: { encrypted in
            try RedmineApiKeyCipher.decrypt(encrypted)
        },
        fetchIssues: { url, apiKey, projectId in
            try await RedmineClient().fetchIssues(baseURL: url, apiKey: apiKey, projectId: projectId)
        },
        fetchStatuses: { url, apiKey in
            try await RedmineClient().fetchStatuses(baseURL: url, apiKey: apiKey)
        },
        saveLastCheckedAt: { timestamp in
            guard var section = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine else { return }
            section.lastCheckedAt = timestamp
            try? await ConfigStore.shared.saveRedmineConfig(guildId: guildId, section: section)
        },
        postIssueCard: { issue in
            await postRedmineIssueCard(client: client, guildId: guildId, issue: issue)
        },
        onLog: { msg in log.info("\(msg)") }
    )
}

/// Posts one issue card to the guild's `#redmine-report` channel. No report channel configured
/// (empty/missing id) is a silent skip — never falls back to a DM or any other channel.
private func postRedmineIssueCard(client: any DiscordClient, guildId: String, issue: RedmineIssueDTO) async {
    guard let channelId = await ConfigStore.shared.loadServerConfig(guildId: guildId)?.redmine?.reportChannelId,
          !channelId.isEmpty
    else {
        log.info("redmine poller (\(guildId)): no report channel configured, skipping issue #\(issue.id)")
        return
    }
    let embed = discordEmbed(from: buildRedmineIssueEmbed(issue))
    let components = discordActionRows(from: [buildRedmineIssueButtons(issueId: issue.id)])
    _ = await createMessageWithRetry(
        client: client,
        channelId: ChannelSnowflake(channelId),
        payload: .init(embeds: [embed], components: components)
    )
}

func startRedminePoller(client: any DiscordClient, guildId: String) async {
    await RedminePollerRegistry.shared.start(guildId: guildId, deps: buildRedminePollerDeps(client: client, guildId: guildId))
}

/// Boot-time restore (WO-10) — starts a poller for every guild that already has a `redmine`
/// section saved, mirroring `AutoUpdateWiring.swift`'s `ConfigStore.shared.listServerGuildIds()`
/// sweep.
func restoreRedminePollers(client: any DiscordClient) async {
    let guildIds = await ConfigStore.shared.listServerGuildIds()
    var restored = 0
    for guildId in guildIds {
        guard let server = await ConfigStore.shared.loadServerConfig(guildId: guildId), server.redmine != nil else { continue }
        await startRedminePoller(client: client, guildId: guildId)
        restored += 1
    }
    log.info("restored \(restored) redmine poller(s) of \(guildIds.count) guild(s)")
}
