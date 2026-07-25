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
    let next = ServerConfig(
        version: existing?.version ?? 1,
        guildId: guildId,
        auth: existing?.auth,
        defaults: existing?.defaults,
        limits: existing?.limits,
        locale: existing?.locale,
        auditChannelId: existing?.auditChannelId,
        favorites: existing?.favorites,
        presets: existing?.presets,
        channels: channels,
        notifications: existing?.notifications
    )
    try await configStore.saveServerConfig(next)
}

/// Reuse stored id only when the channel still exists.
private func reuseId(_ id: String?, provisioner: any GuildChannelProvisioner) async -> String? {
    guard let id, !id.isEmpty else { return nil }
    return await provisioner.channelExists(id) ? id : nil
}
