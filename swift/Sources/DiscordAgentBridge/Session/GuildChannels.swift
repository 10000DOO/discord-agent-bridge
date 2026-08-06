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
    /// Move a channel under a new parent category (`/orchestration` category migration).
    /// Best-effort at adapter level — mirrors `renameChannel`.
    func setParent(id: String, parentId: String) async throws
    /// Delete by id (/agent close). Best-effort at adapter level.
    func deleteChannel(id: String) async throws
    /// Ids of channels still parented under `categoryId` (WO-7 category-empty check before delete).
    /// Throws on a failed query — callers must NOT treat a failure as "empty" (RV: that would let a
    /// transient API error delete a non-empty category).
    func childChannelIds(categoryId: String) async throws -> [String]
}

/// Canonical Discord names (not localized — Discord channel/category names).
public enum GuildChannelNames {
    public static let controlCategory = "🤖 Agent"
    public static let controlChannel = "session-generator"
    public static let statusChannel = "agent-status"
    public static let sessionsCategory = "Agent - Sessions"
    public static let redmineReportChannel = "redmine-report"
    /// + `<folder-slug>` — one category per orchestration set (design_orchestration_module_agents.md R1).
    public static let orchestrationCategoryPrefix = "Agent - Orch - "
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

// MARK: - Orchestration set category (design_orchestration_module_agents.md WO-1)

/// Idempotently create (or reuse) the orchestration set's category and persist its id into
/// `ServerConfig.orchestration[orchestratorChannelId]`. Mirrors `ensureGuildChannels`'s
/// `reuseId` + `ensureCategory` combo. On reuse, never touches `moduleModel`/`moduleEffort` —
/// those fields belong to the WO-10 start card.
public func ensureOrchestrationCategory(
    provisioner: any GuildChannelProvisioner,
    configStore: ConfigStore,
    orchestratorChannelId: String,
    folderPath: String
) async throws -> ProvisionedChannel {
    let guildId = provisioner.guildId
    let server = await configStore.loadServerConfig(guildId: guildId)
    let existingSet = server?.orchestration?[orchestratorChannelId]

    let slug = slugifyPathComponent(folderPath)
    let base = GuildChannelNames.orchestrationCategoryPrefix + (slug.isEmpty ? "session" : slug)
    // Discriminator applies to NEW categories only — `ensureCategory` ignores `name` when
    // `existingId` is non-nil (reuse path below), so this never renames an already-provisioned
    // set. Same folder can back multiple concurrent orchestrator sets (distinct
    // orchestratorChannelId) — D1 allowed identical names since Discord permits duplicates, but
    // users found identical category names confusing across sets. Mirrors `TurnThread.swift:173`'s
    // `key.suffix(6)` collision-discriminator convention.
    let discriminator = " · \(orchestratorChannelId.suffix(6))"
    let categoryName = base.count + discriminator.count <= 100
        ? base + discriminator
        : String(base.prefix(100 - discriminator.count)) + discriminator

    let category = try await provisioner.ensureCategory(
        name: categoryName,
        existingId: await reuseId(existingSet?.categoryId, provisioner: provisioner)
    )

    var nextSet = existingSet ?? OrchestrationSet(categoryId: category.id)
    nextSet.categoryId = category.id
    var nextServer = server ?? ServerConfig(guildId: guildId)
    var sets = nextServer.orchestration ?? [:]
    sets[orchestratorChannelId] = nextSet
    nextServer.orchestration = sets
    try await configStore.saveServerConfig(nextServer)

    return category
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

/// Create a module agent channel under the orchestration set's category (WO-2, R3). Always a
/// fresh channel (like `createSessionChannel`) — the caller (WO-4's order handler) decides
/// reuse-vs-create by checking existing store bindings first; `categoryId` is non-optional here
/// because this is only called after `ensureOrchestrationCategory` has already produced one.
public func createModuleAgentChannel(
    provisioner: any GuildChannelProvisioner,
    moduleName: String,
    categoryId: String
) async throws -> ProvisionedChannel {
    try await provisioner.createTextChannel(name: moduleAgentChannelName(moduleName), parentId: categoryId)
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
/// Deletes when the channel is under the sessions category, under an orchestration set's
/// category (`orchestrationCategoryIds` — design_orchestration_module_agents.md WO-7/R8), or its
/// name is `*-proj` / `*-orc` / `*-agent`.
public func shouldDeleteSessionChannelOnClose(
    channelId: String,
    channelName: String?,
    parentId: String?,
    serverChannels: ServerChannels?,
    orchestrationCategoryIds: Set<String> = []
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
    if let parentId, orchestrationCategoryIds.contains(parentId) {
        return true
    }
    if let channelName,
       channelName.hasPrefix("proj-")
        || channelName.hasSuffix("-proj") || channelName.hasSuffix("-orc") || channelName.hasSuffix("-agent") {
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
    orchestrationCategoryIds: Set<String> = [],
    log: (@Sendable (String) -> Void)? = nil
) async {
    guard shouldDeleteSessionChannelOnClose(
        channelId: channelId,
        channelName: channelName,
        parentId: parentId,
        serverChannels: serverChannels,
        orchestrationCategoryIds: orchestrationCategoryIds
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

/// Shared slug rule for channel/category names derived from a folder path or module name:
/// last path component, lowercased, non-alnum runs collapsed to a single `-`, leading/trailing
/// `-` trimmed. Used by `sessionChannelName` / `orchestratorChannelName` / `moduleAgentChannelName`
/// / the orchestration category name (3-5 규약 — one slug rule, several prefixes).
private func slugifyPathComponent(_ input: String) -> String {
    var path = input
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
    return slug
}

/// `<uniq6>-<basename>-proj`, lowercased, non-alnum → `-`, capped at 100 chars. The random
/// `<uniq6>` prefix (not the slug) tells apart multiple sessions created from the same folder;
/// the `-proj` suffix is the fixed marker `shouldDeleteSessionChannelOnClose` matches on.
public func sessionChannelName(_ folderPath: String) -> String {
    markedChannelName(folderPath, fallback: "session", marker: "proj")
}

/// `<uniq6>-<folder-slug>-orc` — the orchestration lead channel name
/// (design_orchestration_module_agents.md R2). Only ever used to rename an already-existing
/// channel (DabMain.swift), so a fresh `<uniq6>` per call is fine — it need not be stable.
public func orchestratorChannelName(_ folderPath: String) -> String {
    markedChannelName(folderPath, fallback: "session", marker: "orc")
}

/// `<uniq6>-<module-slug>-agent` — a module agent channel name (WO-2 uses this to create the channel).
public func moduleAgentChannelName(_ moduleName: String) -> String {
    markedChannelName(moduleName, fallback: "module", marker: "agent")
}

/// Shared `<uniq6>-<slug>-<marker>` builder for `sessionChannelName` / `orchestratorChannelName` /
/// `moduleAgentChannelName`. `marker` is the fixed suffix `shouldDeleteSessionChannelOnClose`
/// checks for, so the 100-char cap trims the slug only — prefix/marker are never truncated.
private func markedChannelName(_ input: String, fallback: String, marker: String) -> String {
    let slug = slugifyPathComponent(input)
    let base = slug.isEmpty ? fallback : slug
    let prefix = "\(UUID().uuidString.prefix(6).lowercased())-"
    let suffix = "-\(marker)"
    let name = prefix + base + suffix
    if name.count <= 100 { return name }
    let maxBaseLen = max(0, 100 - prefix.count - suffix.count)
    return prefix + String(base.prefix(maxBaseLen)) + suffix
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
