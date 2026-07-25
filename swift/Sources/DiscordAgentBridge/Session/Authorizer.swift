import Foundation

// Role-tier authorization gate — 1:1 port of src/core/auth.ts (§7.1). Called by BOTH the
// message and interaction entry points BEFORE anything reaches a mode. Deny-by-default
// (fail-secure): an empty allowlist grants nothing.
//
// Tier capability nests: admin ⊇ execute ⊇ read-only. A per-project ACL (projectAuth)
// NARROWS access (intersect). DM traffic (no guild) honors dmPolicy.
//
// W13 divergences from TS (decided 2026-07-25):
//  - No server layer (global config only — D2/Q1=A). W15-a folds AuthConfigStore into
//    the full ConfigStore without changing this signature.
//  - projectAuth arrives as a CALL ARGUMENT (Q3=B hook — DabMain always passes nil),
//    not via a ChannelRegistry lookup. Real ACL storage/edit is W16.

public enum RoleTier: String, Sendable {
    case admin
    case execute
    case readOnly = "read-only"   // rawValue mirrors TS 'read-only' (reason + audit parity)
}

// Tier ranking for the ⊇ relation (higher grants everything a lower one does).
private let TIER_RANK: [RoleTier: Int] = [.readOnly: 1, .execute: 2, .admin: 3]

// The actions a router can ask about. Each maps to a MINIMUM required tier.
public enum AuthAction: String, Sendable {
    case admin
    case drive
    case runCommand = "run-command"   // rawValue mirrors TS 'run-command'
    case read
}

// Minimum tier each action requires. 'drive' (start session / run turn) and 'run-command'
// (!cmd) are the execute-tier driver actions; 'read' needs read-only; 'admin' needs admin.
private let ACTION_MIN_TIER: [AuthAction: RoleTier] = [
    .admin: .admin,
    .drive: .execute,
    .runCommand: .execute,
    .read: .readOnly,
]

// The actor + what they want to do + where. roleIds are the actor's Discord role ids as
// seen at the call site. guildId absent → DM context (dmPolicy applies).
public struct AuthInput: Sendable {
    public var userId: String
    public var roleIds: [String]
    public var action: AuthAction
    public var guildId: String?
    public var channelId: String?
    // True when the actor holds the Discord Administrator permission on this guild. A Discord
    // admin is granted the admin tier UNCONDITIONALLY — regardless of the role allowlists — so
    // whoever set the bot up can never lock themselves out. Only ever WIDENS access. In W13 this
    // is filled only on the interaction path (message path fixed false — Q2, fail-secure).
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

// Per-project access control carried on a binding (narrows only). R4 hook — DabMain passes
// nil; real ACL storage/edit lands in W16. Mirrors channelRegistry.ts ProjectAuth.
public struct ProjectAuth: Sendable, Equatable {
    public var allowedRoleIds: [String]
    public var allowedUserIds: [String]

    public init(allowedRoleIds: [String], allowedUserIds: [String]) {
        self.allowedRoleIds = allowedRoleIds
        self.allowedUserIds = allowedUserIds
    }
}

public struct Authorizer: Sendable {
    private let config: AuthConfigStore

    public init(config: AuthConfigStore) {
        self.config = config
    }

    public func authorize(_ input: AuthInput, projectAuth: ProjectAuth? = nil) async -> AuthResult {
        let global = await config.load()

        // No guild → DM. Deny unless dmPolicy explicitly allows (deny-by-default, §7.1). The
        // Administrator flag does NOT rescue a denied DM — dmPolicy stays authoritative.
        if input.guildId == nil {
            if global.dmPolicy != "allow" {
                return AuthResult(allowed: false, reason: "DMs are not permitted (dmPolicy=deny).")
            }
            // DM allowed: global-only allowlists, no per-project ACL.
            return decide(global, input, nil)
        }

        // Guild context. No server layer in W13 (D2); projectAuth is the caller's hook.
        return decide(global, input, projectAuth)
    }

    // Resolve the actor's highest tier, then check it clears the action's minimum tier and
    // (if present) the per-project ACL.
    private func decide(_ auth: GlobalAuth, _ input: AuthInput, _ projectAuth: ProjectAuth?) -> AuthResult {
        // A Discord Administrator is ALWAYS the admin tier and bypasses both the role allowlists
        // and the per-project ACL — the operator who set the bot up can never lock themselves out.
        if input.isAdministrator {
            return AuthResult(allowed: true, tier: .admin)
        }

        guard let tier = resolveTier(auth, input.roleIds) else {
            return AuthResult(allowed: false, reason: "No authorized role for this actor (fail-secure).")
        }

        // TIER_RANK / ACTION_MIN_TIER are total over their enums (every case is a key).
        let required = ACTION_MIN_TIER[input.action]!
        if TIER_RANK[tier]! < TIER_RANK[required]! {
            return AuthResult(allowed: false, reason: "Action '\(input.action.rawValue)' requires '\(required.rawValue)'; actor tier is '\(tier.rawValue)'.", tier: tier)
        }

        // Per-project ACL narrows access: when a binding lists allowed roles/users, the actor
        // must match one of them IN ADDITION to clearing the tier check.
        if let projectAuth {
            let allowedByUser = projectAuth.allowedUserIds.contains(input.userId)
            let allowedByRole = input.roleIds.contains { projectAuth.allowedRoleIds.contains($0) }
            if !allowedByUser && !allowedByRole {
                return AuthResult(allowed: false, reason: "Actor is not in this project\u{2019}s access list (projectAuth).", tier: tier)
            }
        }

        return AuthResult(allowed: true, tier: tier)
    }

    // Highest tier the actor's roles grant, or nil if none match (deny-by-default).
    private func resolveTier(_ auth: GlobalAuth, _ roleIds: [String]) -> RoleTier? {
        let roles = Set(roleIds)
        func has(_ allow: [String]) -> Bool { allow.contains { roles.contains($0) } }
        if has(auth.adminRoleIds) { return .admin }
        if has(auth.executeRoleIds) { return .execute }
        if has(auth.readOnlyRoleIds) { return .readOnly }
        return nil
    }
}
