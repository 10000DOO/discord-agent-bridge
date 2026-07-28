import DiscordAgentBridge
import DiscordBM
import Foundation

// MARK: - `/agent start` wizard open block (WO-6)

/// Extracted verbatim from the `/agent start` slash-command handler's wizard-open block
/// (`DabMain.swift:788-826`, ownerId through `updateOriginalInteractionResponse`), so the redmine
/// "new session" dropdown pick (WO-10) can drive the exact same code path as the slash command
/// instead of a re-implementation (3-3 D1, R2).
///
/// Does not send any interaction ack — the caller must already have sent its own `deferred*`
/// response before calling this (slash command and dropdown select are different interactions, so
/// each call site owns its own ack). The owner-vs-admin re-open check (`DabMain.swift:772-779`) is
/// also left to the caller, not folded in here (2장 Out — wizard steps/UI unchanged; owner check
/// means something different per call site).
func presentAgentStartWizard(
    client: any DiscordClient,
    payload: Interaction,
    guildId: String,
    channelId: String,
    actorId: String,
    stubCwd: String
) async throws {
    // W11-b2: folder → [preset if any] → backend→model→effort→perm.
    // G-P1-06: config.favorites → browseRoots/allowedRoots; empty → unbounded (TS Fix 1).
    // Browser starts at DAB_CWD else home (clamped to first root when bounded).
    // nativePanel: package is macOS-only → always wire host picker (dir:panel).
    let ownerId = actorId
    let optionSource = await loadWizardOptionSource()
    let globalConfig = try? await ConfigStore.shared.load()
    let favorites = globalConfig?.favorites ?? []
    // C3: registered permission profile names for the perm step's quick-select.
    let profileNames = Array((globalConfig?.profiles ?? [:]).keys)
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
        profileNames: profileNames,
        onDeletePreset: { name in
            _ = try? await ConfigStore.shared.removeServerPreset(guildId: guildForPresets, name: name)
            return await ConfigStore.shared.loadServerConfig(guildId: guildForPresets)?.presets ?? []
        },
        backendAvailable: { Backend(rawValue: $0) != nil }
    )
    await WizardRegistry.shared.put(wizard, channelId: channelId)
    let (embeds, components) = discordPayload(from: wizard.render())
    _ = try? await client.updateOriginalInteractionResponse(
        appId: payload.application_id,
        token: payload.token,
        payload: .init(embeds: embeds, components: components)
    )
}
