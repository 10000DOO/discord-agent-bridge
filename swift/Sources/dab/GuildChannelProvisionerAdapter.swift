import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "guild-provision")

/// DiscordBM adapter for `GuildChannelProvisioner` (TS `GuildProvisionerAdapter` in client.ts).
/// Best-effort: missing channel / permission errors on rename/delete are swallowed so a single
/// flaky op never aborts the rest of provisioning.
struct DiscordGuildChannelProvisioner: GuildChannelProvisioner, Sendable {
    let client: any DiscordClient
    let guildId: String
    /// When false, `autoProvisionGuild` skips. `/setup` still attempts create and surfaces errors.
    /// Resolved best-effort at construction (member permissions); defaults true if unknown.
    private let manageChannels: Bool

    init(client: any DiscordClient, guildId: String, manageChannels: Bool = true) {
        self.client = client
        self.guildId = guildId
        self.manageChannels = manageChannels
    }

    func canManageChannels() async -> Bool { manageChannels }

    func channelExists(_ id: String) async -> Bool {
        do {
            _ = try await client.getChannel(id: ChannelSnowflake(id)).decode()
            return true
        } catch {
            return false
        }
    }

    func ensureCategory(name: String, existingId: String?) async throws -> ProvisionedChannel {
        if let existingId {
            do {
                let ch = try await client.getChannel(id: ChannelSnowflake(existingId)).decode()
                return ProvisionedChannel(id: ch.id.rawValue, name: ch.name ?? name)
            } catch {
                // Deleted under us — fall through to create.
            }
        }
        let created = try await client.createGuildChannel(
            guildId: GuildSnowflake(guildId),
            payload: .init(name: name, type: .guildCategory)
        ).decode()
        return ProvisionedChannel(id: created.id.rawValue, name: created.name ?? name)
    }

    func ensureTextChannel(name: String, parentId: String, existingId: String?) async throws -> ProvisionedChannel {
        if let existingId {
            do {
                let ch = try await client.getChannel(id: ChannelSnowflake(existingId)).decode()
                return ProvisionedChannel(id: ch.id.rawValue, name: ch.name ?? name)
            } catch {
                // Deleted under us — fall through to create.
            }
        }
        let created = try await client.createGuildChannel(
            guildId: GuildSnowflake(guildId),
            payload: .init(
                name: name,
                type: .guildText,
                parent_id: AnySnowflake(ChannelSnowflake(parentId))
            )
        ).decode()
        return ProvisionedChannel(id: created.id.rawValue, name: created.name ?? name)
    }

    func createTextChannel(name: String, parentId: String?) async throws -> ProvisionedChannel {
        let created = try await client.createGuildChannel(
            guildId: GuildSnowflake(guildId),
            payload: .init(
                name: name,
                type: .guildText,
                parent_id: parentId.map { AnySnowflake(ChannelSnowflake($0)) }
            )
        ).decode()
        return ProvisionedChannel(id: created.id.rawValue, name: created.name ?? name)
    }

    func renameChannel(id: String, name: String) async throws {
        do {
            _ = try await client.updateGuildChannel(
                id: ChannelSnowflake(id),
                payload: .init(name: name)
            ).decode()
        } catch {
            // Best-effort — missing permission / channel must not break provisioning.
        }
    }

    func setParent(id: String, parentId: String) async throws {
        do {
            _ = try await client.updateGuildChannel(
                id: ChannelSnowflake(id),
                payload: .init(parent_id: AnySnowflake(ChannelSnowflake(parentId)))
            ).decode()
        } catch {
            // Best-effort — missing permission / channel must not break provisioning.
        }
    }

    func deleteChannel(id: String) async throws {
        do {
            _ = try await client.deleteChannel(id: ChannelSnowflake(id))
        } catch {
            // Best-effort — missing channel is not an error.
        }
    }

    func childChannelIds(categoryId: String) async throws -> [String] {
        let channels = try await client.listGuildChannels(guildId: GuildSnowflake(guildId)).decode()
        return channels.filter { $0.parent_id?.rawValue == categoryId }.map(\.id.rawValue)
    }
}

/// Build a provisioner for `guildId`. Always returns an adapter; live create will fail if the
/// bot is not in the guild or lacks Manage Channels (caller maps that to the unavailable reply).
func resolveGuildProvisioner(
    client: any DiscordClient,
    guildId: String,
    manageChannels: Bool = true
) -> DiscordGuildChannelProvisioner {
    DiscordGuildChannelProvisioner(client: client, guildId: guildId, manageChannels: manageChannels)
}

// MARK: - G-P1-07 auto-provision wiring (gateway Ready / GuildCreate)

/// Bot user id from READY — used to resolve Manage Channels on GuildCreate.
actor BotGatewayIdentity {
    static let shared = BotGatewayIdentity()
    private var userId: String?

    func setUserId(_ id: String) { userId = id }
    func getUserId() -> String? { userId }
}

/// Resolve Manage Channels for the bot from a full GuildCreate payload.
/// Missing bot member → false (skip auto-provision with warning, matching TS `members.me` absent).
func botCanManageChannels(guild: Gateway.GuildCreate, botUserId: String?) -> Bool {
    let userId: UserSnowflake
    if let botUserId, !botUserId.isEmpty {
        userId = UserSnowflake(botUserId)
    } else if let bot = guild.members.first(where: { $0.user?.bot == true }),
              let id = bot.user?.id {
        userId = id
    } else {
        return false
    }
    return guild.userHasGuildPermission(userId: userId, permission: .manageChannels)
}

/// Best-effort auto-provision one guild (never throws). Reuses pure `autoProvisionGuild`.
func runAutoProvisionGuild(
    client: any DiscordClient,
    guildId: String,
    manageChannels: Bool
) async {
    let provisioner = resolveGuildProvisioner(
        client: client,
        guildId: guildId,
        manageChannels: manageChannels
    )
    _ = await autoProvisionGuild(
        provisioner: provisioner,
        configStore: ConfigStore.shared,
        log: { level, msg in
            switch level {
            case "warn": log.warn(msg)
            case "error": log.error(msg)
            default: log.info(msg)
            }
        }
    )
}
