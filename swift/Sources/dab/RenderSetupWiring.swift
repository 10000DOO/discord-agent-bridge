import DiscordAgentBridge
import DiscordBM
import Foundation

// H6/H7 wiring: the Chromium install prompt posted after /setup, its render-setup:install|
// decline button handling, and the progress-bar-edit loop shared with the /config panel's
// install button (H7). Mirrors AutoUpdateWiring.swift's shape: free functions over `client:
// any DiscordClient`, kept out of DabMain.swift's already-large interaction dispatch.

/// Post the one-time Chromium install prompt to `channelId` (the just-created control
/// channel) when render is enabled, nothing has been decided yet, and nothing is installed.
/// Best-effort: never throws, mirrors TS `maybePromptRenderSetup` (router.ts:266-276).
func maybePromptRenderSetup(client: any DiscordClient, channelId: String) async {
    let cfg = try? await ConfigStore.shared.load()
    let renderEnabled = cfg?.render?.enabled ?? true
    let decision = cfg?.chromium?.decision ?? "undecided"
    let installed = await ImageRenderHost.shared.isInstalled()
    guard shouldPromptRenderSetup(renderEnabled: renderEnabled, chromiumDecision: decision, isInstalled: installed) else {
        return
    }
    let buttons = buildRenderSetupButtons().map { spec in
        Interaction.ActionRow.Button(
            style: spec.style == .primary ? .primary : .secondary,
            label: spec.label,
            custom_id: spec.customId
        )
    }
    let row: Interaction.ActionRow = .init(components: buttons.map { .button($0) })
    // C14: retry-wrapped (control channel — no session binding to clean up; the live
    // channelDelete event / boot resumeAll already cover cleanup independently).
    _ = await createMessageWithRetry(
        client: client,
        channelId: ChannelSnowflake(channelId),
        payload: .init(content: RenderSetupLabels.prompt, components: [row])
    )
}

/// `render-setup:install|decline` button click (drive-tier, host-wide decision — anyone may
/// act on it). Ack via deferUpdate keeps the prompt message in place for the progress edit.
func handleRenderSetupComponent(client: any DiscordClient, payload: Interaction, action: RenderSetupAction) async throws {
    let actorId = payload.member?.user?.id.rawValue ?? payload.user?.id.rawValue ?? ""
    let projectAuth = await SessionStore.shared.binding(channelId: payload.channel_id?.rawValue ?? "")?.projectAuth
    let decision = await Authorizer(config: .shared).authorize(
        AuthInput(
            userId: actorId,
            roleIds: payload.member?.roles.map(\.rawValue) ?? [],
            action: .drive,
            guildId: payload.guild_id?.rawValue,
            channelId: payload.channel_id?.rawValue ?? "",
            isAdministrator: payload.member?.permissions?.contains(.administrator) ?? false
        ),
        projectAuth: projectAuth
    )
    guard decision.allowed else {
        _ = try? await client.createInteractionResponse(
            id: payload.id, token: payload.token,
            payload: .channelMessageWithSource(.init(content: I18n.t("auth.denied.bare"), flags: [.ephemeral]))
        )
        return
    }
    _ = try? await client.createInteractionResponse(
        id: payload.id, token: payload.token,
        payload: .deferredUpdateMessage()
    )
    guard await ImageRenderHost.shared.provisionerInstance() != nil else {
        _ = try? await client.createFollowupMessage(
            appId: payload.application_id, token: payload.token,
            payload: .init(content: RenderSetupLabels.unavailable, flags: [.ephemeral])
        )
        return
    }

    switch action {
    case .decline:
        try? await ConfigStore.shared.setChromiumDecision("declined")
        await editOriginalRenderSetup(client: client, appId: payload.application_id, token: payload.token, content: RenderSetupLabels.declined)
    case .install:
        await performRenderSetupInstall(client: client, appId: payload.application_id, token: payload.token)
    }
}

/// The "install" half of the Chromium setup flow: mark the decision accepted, short-circuit
/// to `render.setup.already` when something's already installed, else drive the download with
/// a live progress-bar edit on the ORIGINAL interaction response, then done/failed (buttons
/// removed). TS `components.ts:78-83` reuses its `handleRenderSetup(..., 'install')` verbatim
/// for BOTH the render-setup:install button and /config's render-install button — this is that
/// same reuse: called by H6's button handler above and directly by H7's `.renderInstall` case
/// in DabMain.swift (both ack via deferredUpdateMessage, so both edit the same way).
func performRenderSetupInstall(client: any DiscordClient, appId: ApplicationSnowflake, token: String) async {
    try? await ConfigStore.shared.setChromiumDecision("accepted")
    if await ImageRenderHost.shared.isInstalled() {
        await editOriginalRenderSetup(client: client, appId: appId, token: token, content: RenderSetupLabels.already)
        return
    }
    await editOriginalRenderSetup(client: client, appId: appId, token: token, content: RenderSetupLabels.progress(pct: 0))
    do {
        _ = try await ImageRenderHost.shared.install { pct in
            Task {
                await editOriginalRenderSetup(client: client, appId: appId, token: token, content: RenderSetupLabels.progress(pct: pct))
            }
        }
        await editOriginalRenderSetup(client: client, appId: appId, token: token, content: RenderSetupLabels.done)
    } catch {
        await editOriginalRenderSetup(client: client, appId: appId, token: token, content: RenderSetupLabels.failed)
    }
}

private func editOriginalRenderSetup(client: any DiscordClient, appId: ApplicationSnowflake, token: String, content: String) async {
    _ = try? await client.updateOriginalInteractionResponse(
        appId: appId, token: token,
        payload: .init(content: content, components: [])
    )
}
