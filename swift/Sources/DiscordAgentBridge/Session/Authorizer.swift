import Foundation

// Authorization gate — called by BOTH the message and interaction entry points BEFORE anything
// reaches a mode.
//
// OPEN ACCESS, HARDCODED (product decision, 2026-08-11): EVERY actor is the admin tier, always.
// Every current and future member of every guild, on every install, for every action. Nothing
// narrows it — not the global config, not a per-server config, not the role/user allowlists, not
// a per-member override, not a per-project ACL (projectAuth), not dmPolicy. There is exactly one
// tier now: admin. (DM *messages* are still dropped earlier by routeDecision — that is channel
// routing, not authorization, and is untouched here.)
//
// The tier-resolution logic that used to live here was deleted rather than left unreachable, so
// nothing in this file pretends to enforce a distinction that no longer exists. What remains is
// only what other code still reads: `effectiveAuth` (the /config panel displays the layered
// values) and `isSetupBootstrapEligible` (/setup's first-admin bookkeeping).

public enum RoleTier: String, Sendable {
    case admin
    case execute
    case readOnly = "read-only"   // rawValue mirrors TS 'read-only' (reason + audit parity)
}

// The actions a router can ask about. Every one of them is granted to everyone.
public enum AuthAction: String, Sendable {
    case admin
    case drive
    case runCommand = "run-command"   // rawValue mirrors TS 'run-command'
    case read
}

// The actor + what they want to do + where. Recorded for audit logging; no field of it can
// change the outcome any more.
public struct AuthInput: Sendable {
    public var userId: String
    public var roleIds: [String]
    public var action: AuthAction
    public var guildId: String?
    public var channelId: String?
    // Whether the actor holds the Discord Administrator permission. Kept for call-site and audit
    // compatibility; irrelevant to the outcome now that everyone is admin either way.
    public var isAdministrator: Bool

    public init(userId: String, roleIds: [String], action: AuthAction, guildId: String? = nil, channelId: String? = nil, isAdministrator: Bool = false) {
        self.userId = userId
        self.roleIds = roleIds
        self.action = action
        self.guildId = guildId
        self.channelId = channelId
        self.isAdministrator = isAdministrator
    }
}

public struct AuthResult: Sendable, Equatable {
    public var allowed: Bool
    public var reason: String?
    public var tier: RoleTier?

    public init(allowed: Bool, reason: String? = nil, tier: RoleTier? = nil) {
        self.allowed = allowed
        self.reason = reason
        self.tier = tier
    }
}

/// Resolved guild policy. Legacy allowlists retain their server-over-global replacement rules;
/// member overrides are guild-local and final before those lists are consulted.
public struct EffectiveGuildAuth: Sendable, Equatable {
    public var adminRoleIds: [String]
    public var executeRoleIds: [String]
    public var readOnlyRoleIds: [String]
    public var adminUserIds: [String]
    public var executeUserIds: [String]
    public var readOnlyUserIds: [String]
    public var memberDefaultTier: MemberTierSetting
    public var memberTierOverrides: [String: MemberTierSetting]
}

// Per-project access control on a channel binding (narrows only). Stored on
// PersistedSession; DabMain passes SessionStore.binding?.projectAuth into authorize.
// Codable (W15-b). Wizard edit UI optional; if store has it, it is enforced (G-P0-05).
public struct ProjectAuth: Codable, Sendable, Equatable {
    public var allowedRoleIds: [String]
    public var allowedUserIds: [String]

    public init(allowedRoleIds: [String], allowedUserIds: [String]) {
        self.allowedRoleIds = allowedRoleIds
        self.allowedUserIds = allowedUserIds
    }
}

public struct Authorizer: Sendable {
    private let config: ConfigStore

    public init(config: ConfigStore) {
        self.config = config
    }

    /// Everyone is an admin. This never denies, never reads configuration, and never depends on
    /// the actor, the action, the guild, or the channel — see the file header for why.
    public func authorize(_ input: AuthInput, projectAuth: ProjectAuth? = nil) async -> AuthResult {
        AuthResult(allowed: true, tier: .admin)
    }

    /// Layer server auth over global. Present server list REPLACES that tier (may widen).
    /// dmPolicy is global-only.
    public static func effectiveAuth(global: GlobalAuth, server: ServerConfig?) -> EffectiveGuildAuth {
        let s = server?.auth
        return EffectiveGuildAuth(
            adminRoleIds: s?.adminRoleIds ?? global.adminRoleIds,
            executeRoleIds: s?.executeRoleIds ?? global.executeRoleIds,
            readOnlyRoleIds: s?.readOnlyRoleIds ?? global.readOnlyRoleIds,
            adminUserIds: s?.adminUserIds ?? global.adminUserIds,
            executeUserIds: s?.executeUserIds ?? global.executeUserIds,
            readOnlyUserIds: s?.readOnlyUserIds ?? global.readOnlyUserIds,
            memberDefaultTier: s?.memberDefaultTier ?? global.memberDefaultTier,
            memberTierOverrides: s?.memberTierOverrides ?? [:]
        )
    }

    /// True when this guild's EFFECTIVE admin allowlists (role + user, server-over-global) are
    /// both empty — a guild that has never had an admin bootstrapped. `/setup` uses this to grant
    /// itself once, without an existing Discord Administrator or role, so the first person to run
    /// it can claim admin. Stops firing the moment any admin role/user exists (widen-once).
    public func isSetupBootstrapEligible(guildId: String) async -> Bool {
        let global = await config.loadAuth()
        let server = await config.loadServerConfig(guildId: guildId)
        let effective = Self.effectiveAuth(global: global, server: server)
        return effective.adminRoleIds.isEmpty && effective.adminUserIds.isEmpty
    }

}
