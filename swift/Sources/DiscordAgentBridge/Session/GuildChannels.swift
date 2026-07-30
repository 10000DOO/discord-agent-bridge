import Foundation

// A4D-style guild channel provisioning — port of src/discord/guildChannels.ts.
// Discord I/O sits behind GuildChannelProvisioner so pure logic (alreadyDone / ensure /
// session name) stays unit-testable without DiscordBM (library has no Discord dep).

// MARK: - Types

/// Narrow view of a created/reused channel.
public struct ProvisionedChannel: Sendable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Channel ops for ONE guild. Adapter (DiscordBM) lives in `dab`; tests use a fake.
public protocol GuildChannelProvisioner: Sendable {
    var guildId: String { get }
    /// True when the bot has Manage Channels. Auto-provision checks this first.
    func canManageChannels() async -> Bool
    /// True when a channel with this id still exists (was not deleted).
    func channelExists(_ id: String) async -> Bool
    /// Reuse `existingId` when present, else create a category named `name`.
    func ensureCategory(name: String, existingId: String?) async throws -> ProvisionedChannel
    /// Reuse `existingId` when present, else create a text channel under `parentId`.
    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel
    /// Always-fresh text channel (per-project session channels).
    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel
    /// Rename by id (control-channel name migration). Best-effort at adapter level.
    func renameChannel(id: String, name: String) async throws
    /// Delete by id (/agent close). Best-effort at adapter level.
    func deleteChannel(id: String) async throws
}

/// Canonical Discord names (not localized — Discord channel/category names).
public enum GuildChannelNames {
    public static let controlCategory = "🤖 Agent"
    public static let controlChannel = "session-generator"
    public static let statusChannel = "agent-status"
    public static let sessionsCategory = "Agent - Sessions"
    public static let redmineReportChannel = "redmine-report"
}

// MARK: - alreadyDone (pure)

/// True when stored structure is complete and every id still exists.
/// Matches TS `runSetup` skip guard (statusChannelId required).
public func isGuildChannelsAlreadyDone(
    existing: ServerChannels?,
    channelExists: (String) -> Bool
) -> Bool {
    guard let existing, let statusId = existing.statusChannelId, !statusId.isEmpty else {
        return false
    }
    return channelExists(existing.categoryId)
        && channelExists(existing.controlChannelId)
        && channelExists(existing.sessionsCategoryId)
        && channelExists(statusId)
}

/// Async variant for live provisioners.
public func isGuildChannelsAlreadyDone(
    existing: ServerChannels?,
    provisioner: any GuildChannelProvisioner
) async -> Bool {
    guard let existing, let statusId = existing.statusChannelId, !statusId.isEmpty else {
        return false
    }
    // Await each check separately — `&&` is an autoclosure (no await on RHS).
    guard await provisioner.channelExists(existing.categoryId) else { return false }
    guard await provisioner.channelExists(existing.controlChannelId) else { return false }
    guard await provisioner.channelExists(existing.sessionsCategoryId) else { return false }
    return await provisioner.channelExists(statusId)
}

// MARK: - ensure / auto-provision

/// Idempotently create (or reuse) the guild channel structure and persist ids into
/// `servers/<guildId>.json`. Re-running with a still-valid structure reuses every channel.
public func ensureGuildChannels(
    provisioner: any GuildChannelProvisioner,
    configStore: ConfigStore
) async throws -> ServerChannels {
    let guildId = provisioner.guildId
    let server = await configStore.loadServerConfig(guildId: guildId)
    let existing = server?.channels

    let controlCategory = try await provisioner.ensureCategory(
        name: GuildChannelNames.controlCategory,
        existingId: await reuseId(existing?.categoryId, provisioner: provisioner)
    )
    let controlChannel = try await provisioner.ensureTextChannel(
        name: GuildChannelNames.controlChannel,
        parentId: controlCategory.id,
        existingId: await reuseId(existing?.controlChannelId, provisioner: provisioner)
    )
    // Migrate old control-channel name (e.g. agent-start → session-generator). Best-effort.
    if controlChannel.name != GuildChannelNames.controlChannel {
        try? await provisioner.renameChannel(id: controlChannel.id, name: GuildChannelNames.controlChannel)
    }
    let statusChannel = try await provisioner.ensureTextChannel(
        name: GuildChannelNames.statusChannel,
        parentId: controlCategory.id,
        existingId: await reuseId(existing?.statusChannelId, provisioner: provisioner)
    )
    let sessionsCategory = try await provisioner.ensureCategory(
        name: GuildChannelNames.sessionsCategory,
        existingId: await reuseId(existing?.sessionsCategoryId, provisioner: provisioner)
    )

    let channels = ServerChannels(
        categoryId: controlCategory.id,
        controlChannelId: controlChannel.id,
        sessionsCategoryId: sessionsCategory.id,
        statusChannelId: statusChannel.id
    )
    try await persistChannels(configStore: configStore, guildId: guildId, existing: server, channels: channels)
    return channels
}

/// Auto-provision on ready / guild-join. GUARDED + NON-THROWING: missing Manage Channels
/// or create failure → nil + no throw. Idempotent via `ensureGuildChannels`.
public func autoProvisionGuild(
    provisioner: any GuildChannelProvisioner,
    configStore: ConfigStore,
    log: (@Sendable (String, String) -> Void)? = nil
) async -> ServerChannels? {
    if await !provisioner.canManageChannels() {
        log?("warn", "auto-provision skipped: missing Manage Channels permission guild=\(provisioner.guildId)")
        return nil
    }
    do {
        let channels = try await ensureGuildChannels(provisioner: provisioner, configStore: configStore)
        log?("info", "auto-provisioned guild channels guild=\(provisioner.guildId) control=\(channels.controlChannelId)")
        return channels
    } catch {
        log?("warn", "auto-provision failed guild=\(provisioner.guildId) err=\(error)")
        return nil
    }
}

// MARK: - Redmine report channel

/// Reuse the stored `#redmine-report` channel when it still exists, else create it under the
/// `🤖 Agent` control category (reusing that category's id if already provisioned, else creating
/// it) so it sits alongside `session-generator`/`agent-status` instead of floating uncategorized.
public func ensureRedmineReportChannel(
    provisioner: any GuildChannelProvisioner,
    configStore: ConfigStore
) async throws -> ProvisionedChannel {
    let server = await configStore.loadServerConfig(guildId: provisioner.guildId)
    if let existingId = server?.redmine?.reportChannelId, await provisioner.channelExists(existingId) {
        return ProvisionedChannel(id: existingId, name: GuildChannelNames.redmineReportChannel)
    }
    let controlCategory = try await provisioner.ensureCategory(
        name: GuildChannelNames.controlCategory,
        existingId: await reuseId(server?.channels?.categoryId, provisioner: provisioner)
    )
    return try await provisioner.createTextChannel(
        name: GuildChannelNames.redmineReportChannel,
        parentId: controlCategory.id
    )
}

// MARK: - Session channel

/// Create a dedicated session channel under the sessions category when available.
public func createSessionChannel(
    provisioner: any GuildChannelProvisioner,
    folderPath: String,
    sessionsCategoryId: String?
) async throws -> ProvisionedChannel {
    let name = sessionChannelName(folderPath)
    return try await provisioner.createTextChannel(name: name, parentId: sessionsCategoryId)
}

/// Resolve the channel id to bind after `/agent start` wizard done (W11-b2 A4D).
///
/// When a provisioner and non-empty `sessionsCategoryId` are available, creates a fresh
/// `proj-<folder>` text channel under that category. On missing setup or create failure,
/// returns `fallbackChannelId` (the wizard's original channel) so start still succeeds.
public func resolveSessionChannelId(
    provisioner: (any GuildChannelProvisioner)?,
    folderPath: String,
    sessionsCategoryId: String?,
    fallbackChannelId: String
) async -> String {
    guard let provisioner else { return fallbackChannelId }
    guard let sessionsCategoryId, !sessionsCategoryId.isEmpty else {
        return fallbackChannelId
    }
    do {
        let created = try await createSessionChannel(
            provisioner: provisioner,
            folderPath: folderPath,
            sessionsCategoryId: sessionsCategoryId
        )
        return created.id
    } catch {
        return fallbackChannelId
    }
}

/// Whether `/agent close` should delete this channel (A4D dedicated session channel).
///
/// Never deletes control / status / category / sessions-category from server config.
/// Deletes only when the channel is under the sessions category **or** its name is `proj-*`.
public func shouldDeleteSessionChannelOnClose(
    channelId: String,
    channelName: String?,
    parentId: String?,
    serverChannels: ServerChannels?
) -> Bool {
    if let sc = serverChannels {
        if channelId == sc.controlChannelId { return false }
        if channelId == sc.categoryId { return false }
        if channelId == sc.sessionsCategoryId { return false }
        if let status = sc.statusChannelId, !status.isEmpty, channelId == status { return false }
    }
    if let parentId,
       let sessionsCat = serverChannels?.sessionsCategoryId,
       !sessionsCat.isEmpty,
       parentId == sessionsCat {
        return true
    }
    if let channelName, channelName.hasPrefix("proj-") {
        return true
    }
    return false
}

/// Best-effort delete of an A4D session channel after `/agent close` (TS `deleteSessionChannel`).
/// Call **after** the interaction reply so the ack lands before the channel vanishes.
public func deleteSessionChannel(
    provisioner: (any GuildChannelProvisioner)?,
    channelId: String,
    channelName: String?,
    parentId: String?,
    serverChannels: ServerChannels?,
    log: (@Sendable (String) -> Void)? = nil
) async {
    guard shouldDeleteSessionChannelOnClose(
        channelId: channelId,
        channelName: channelName,
        parentId: parentId,
        serverChannels: serverChannels
    ) else { return }
    guard let provisioner else { return }
    do {
        try await provisioner.deleteChannel(id: channelId)
    } catch {
        log?("failed to delete session channel: \(error)")
    }
}

/// True for the session-generator / agent-status / redmine-report channels — control-plane
/// channels where a project-scoped command like `/orchestration` must never run (§1.2). Checked
/// independently of session-binding lookups: a small guild's `/agent start` fallback path
/// (`resolveSessionChannelId`, empty `sessionsCategoryId`) can bind a session directly onto
/// `controlChannelId`, so "no binding" alone cannot reliably distinguish these channels.
public func isControlPlaneChannel(
    channelId: String,
    serverChannels: ServerChannels?,
    redmineReportChannelId: String?
) -> Bool {
    if let sc = serverChannels {
        if channelId == sc.controlChannelId { return true }
        if let status = sc.statusChannelId, !status.isEmpty, channelId == status { return true }
    }
    if let redmineReportChannelId, !redmineReportChannelId.isEmpty, channelId == redmineReportChannelId {
        return true
    }
    return false
}

/// `proj-<basename>` slug, lowercased, non-alnum → `-`, capped at 100 chars.
public func sessionChannelName(_ folderPath: String) -> String {
    var path = folderPath
    while path.hasSuffix("/") || path.hasSuffix("\\") {
        path = String(path.dropLast())
    }
    let base = path.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? ""
    let lowered = base.lowercased()
    var slug = ""
    var lastDash = false
    for ch in lowered {
        if ch.isLetter || ch.isNumber {
            slug.append(ch)
            lastDash = false
        } else if !lastDash {
            slug.append("-")
            lastDash = true
        }
    }
    while slug.hasPrefix("-") { slug = String(slug.dropFirst()) }
    while slug.hasSuffix("-") { slug = String(slug.dropLast()) }
    let name = slug.isEmpty ? "proj-session" : "proj-\(slug)"
    if name.count <= 100 { return name }
    return String(name.prefix(100))
}

// MARK: - Persist

/// Merge resolved channel ids into servers/<guildId>.json without clobbering auth/defaults/etc.
private func persistChannels(
    configStore: ConfigStore,
    guildId: String,
    existing: ServerConfig?,
    channels: ServerChannels
) async throws {
    var next = existing ?? ServerConfig(guildId: guildId)
    next.version = existing?.version ?? 1
    next.guildId = guildId
    next.channels = channels
    try await configStore.saveServerConfig(next)
}

/// Reuse stored id only when the channel still exists.
private func reuseId(_ id: String?, provisioner: any GuildChannelProvisioner) async -> String? {
    guard let id, !id.isEmpty else { return nil }
    return await provisioner.channelExists(id) ? id : nil
}
