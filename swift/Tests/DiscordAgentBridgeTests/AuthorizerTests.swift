import Testing
import Foundation
@testable import DiscordAgentBridge

// Mirrors src/core/auth.test.ts (including server-layer cases restored in W15-a).
// Zero-entropy role ids. Fixtures write full-enough config via ConfigStore.

private let ADMIN_ROLE = "role-admin"
private let EXEC_ROLE = "role-exec"
private let READ_ROLE = "role-read"

private func tempBaseDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-auth-\(UUID().uuidString)", isDirectory: true)
}

// Write a minimal valid config.json (secrets + auth) via JSON.
private func writeAuthConfig(
    _ dir: URL,
    admin: [String] = [],
    execute: [String] = [],
    readOnly: [String] = [],
    memberDefaultTier: String = "none",
    dmPolicy: String = "deny"
) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let auth: [String: Any] = [
        "adminRoleIds": admin,
        "executeRoleIds": execute,
        "readOnlyRoleIds": readOnly,
        "memberDefaultTier": memberDefaultTier,
        "dmPolicy": dmPolicy,
    ]
    let obj: [String: Any] = [
        "version": 2,
        "discord": ["token": "t", "clientId": "c"],
        "auth": auth,
    ]
    let url = dir.appendingPathComponent("config.json")
    try JSONSerialization.data(withJSONObject: obj).write(to: url)
}

private func writeServerAuth(_ dir: URL, guildId: String, execute: [String]? = nil, admin: [String]? = nil) throws {
    let servers = dir.appendingPathComponent("servers", isDirectory: true)
    try FileManager.default.createDirectory(at: servers, withIntermediateDirectories: true)
    var auth: [String: Any] = [:]
    if let execute { auth["executeRoleIds"] = execute }
    if let admin { auth["adminRoleIds"] = admin }
    let obj: [String: Any] = [
        "version": 1,
        "guildId": guildId,
        "auth": auth,
    ]
    try JSONSerialization.data(withJSONObject: obj)
        .write(to: servers.appendingPathComponent("\(guildId).json"))
}

private func store(_ dir: URL) -> ConfigStore { ConfigStore(baseDir: dir) }
private func authorizer(_ dir: URL) -> Authorizer { Authorizer(config: store(dir)) }

private func input(
    userId: String = "u1",
    roleIds: [String] = [],
    action: AuthAction = .read,
    guildId: String? = "g1",
    channelId: String? = "c1",
    isAdministrator: Bool = false
) -> AuthInput {
    AuthInput(
        userId: userId,
        roleIds: roleIds,
        action: action,
        guildId: guildId,
        channelId: channelId,
        isAdministrator: isAdministrator
    )
}

// Open access is hardcoded (docs/all-members-admin.md R1): authorize() grants the admin tier to
// every actor for every action, whatever the configuration says.
//
// R7 — every scenario that used to prove access was NARROWED is still here, one-for-one, with its
// expectation flipped. That is deliberate: these are the watchdogs. Restoring any tier decision
// makes this suite fail loudly instead of quietly re-locking the bot. Each test name says what the
// old build did, so the diff against that behaviour stays readable.
@Suite("Authorizer (everyone is admin)")
struct AuthorizerTests {
    private func expectAdmin(_ r: AuthResult) {
        #expect(r.allowed == true)
        #expect(r.tier == .admin)
        #expect(r.reason == nil)
    }

    /// New case: not even a config file is required to be an admin (R3).
    @Test func everyActionAllowedWithNoConfigAtAll() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            expectAdmin(await authz.authorize(input(roleIds: [], action: action)))
        }
    }

    /// Was: failSecureEmptyAllowlistsDenyEveryoneEvenRead.
    @Test func emptyAllowlistsNoLongerDenyEvenRead() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [ADMIN_ROLE], action: .read)))
    }

    @Test func adminTierAllowedEveryAction() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE])
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            expectAdmin(await authz.authorize(input(roleIds: [ADMIN_ROLE], action: action)))
        }
    }

    /// Was: executeTierMayDriveAndRunButNotAdmin — the execute role now clears `.admin` too.
    @Test func executeTierNowClearsAdminActionAsWell() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        for action in [AuthAction.drive, .runCommand, .read, .admin] {
            expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: action)))
        }
    }

    /// Was: readOnlyTierMayReadButNotDriveRunAdmin.
    @Test func readOnlyTierNowDrivesRunsAndAdministers() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, readOnly: [READ_ROLE])
        let authz = authorizer(dir)
        for action in [AuthAction.read, .drive, .runCommand, .admin] {
            expectAdmin(await authz.authorize(input(roleIds: [READ_ROLE], action: action)))
        }
    }

    /// Was: unknownOrNoRoleDeniedFailSecure.
    @Test func unknownOrNoRoleIsAdminToo() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [], action: .read)))
        expectAdmin(await authz.authorize(input(roleIds: ["role-stranger"], action: .read)))
    }

    /// Was: perProjectAclNarrowsTierClearedActor.
    @Test func perProjectAclNoLongerNarrows() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: [])
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: acl))
    }

    @Test func perProjectAclAdmitsMatchingRoleOrUser() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        let byRole = ProjectAuth(allowedRoleIds: [EXEC_ROLE], allowedUserIds: [])
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: byRole))
        let byUser = ProjectAuth(allowedRoleIds: ["role-other"], allowedUserIds: ["u1"])
        expectAdmin(await authz.authorize(input(userId: "u1", roleIds: [EXEC_ROLE], action: .drive), projectAuth: byUser))
    }

    /// Was: projectAuthFromStoreRowNarrowsAndAdmits. G-P0-05 shape — a stored ACL reaches
    /// authorize() (DabMain loads PersistedSession.projectAuth) and is ignored there.
    @Test func projectAuthFromStoreRowIsIgnored() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let store = SessionStore(fileURL: dir.appendingPathComponent("swift-state.json"))
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: ["u-owner"])
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: "/ws", guildId: "g1", projectAuth: acl, updatedAt: "t")
        )
        let fromStore = await store.binding(channelId: "c1")?.projectAuth
        #expect(fromStore == acl)
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(
            input(userId: "stranger", roleIds: [EXEC_ROLE], action: .drive, channelId: "c1"),
            projectAuth: fromStore
        ))
        expectAdmin(await authz.authorize(
            input(userId: "u-owner", roleIds: [EXEC_ROLE], action: .drive, channelId: "c1"),
            projectAuth: fromStore
        ))
    }

    @Test func nilProjectAuthDoesNotNarrow() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: nil))
    }

    /// Was: dmDeniedByDefault. dmPolicy=deny no longer denies at this gate — DM *messages* are
    /// dropped earlier by routeDecision, which is channel routing, not authorization.
    @Test func dmNoLongerDeniedByDmPolicy() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE])
        expectAdmin(await authorizer(dir).authorize(
            input(roleIds: [ADMIN_ROLE], action: .read, guildId: nil, channelId: nil)
        ))
    }

    /// Was: dmAllowedWhenPolicyAllowAndTierClears — the roleless second half now clears too.
    @Test func dmAllowedWithoutAnyRoleWhenPolicyAllow() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE], dmPolicy: "allow")
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [ADMIN_ROLE], action: .admin, guildId: nil, channelId: nil)))
        expectAdmin(await authz.authorize(input(roleIds: [], action: .read, guildId: nil, channelId: nil)))
    }

    @Test func administratorWithNoRoleAuthorizedAsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            expectAdmin(await authz.authorize(input(roleIds: [], action: action, isAdministrator: true)))
        }
    }

    /// Was: nonAdminWithNoRoleDenied — the whole point of the change.
    @Test func nonAdminWithNoRoleIsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [], action: .read, isAdministrator: false)))
    }

    /// Was: configuredRolesWorkForNonAdministrator (`.admin` half used to be denied).
    @Test func configuredRolesGetAdminForEveryAction() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)))
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .admin)))
    }

    @Test func administratorBypassesNarrowingProjectAcl() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: [])
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [], action: .drive, isAdministrator: true), projectAuth: acl))
    }

    /// Was: deniedDmNotRescuedByAdministratorFlag — nothing needs rescuing now.
    @Test func dmWithAdministratorFlagAlsoAllowed() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        expectAdmin(await authorizer(dir).authorize(
            input(roleIds: [], action: .read, guildId: nil, channelId: nil, isAdministrator: true)
        ))
    }

    /// Was: memberTierOverrideIncludingNoneCannotBlock — `none` used to mean "completely blocked".
    @Test func memberTierOverrideIncludingNoneCannotBlock() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).setServerMemberTierOverride(guildId: "g1", userId: "blocked", tier: .none)
        expectAdmin(await authorizer(dir).authorize(input(userId: "blocked", roleIds: [], action: .admin)))
    }

    // W15-a: server auth layer. The layering still resolves for display; it decides nothing.

    /// Was: serverExecuteRolesWidenGlobalForThatGuildOnly — the other guild is open as well now.
    @Test func serverExecuteRolesNoLongerScopeAccessToOneGuild() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir) // global grants nobody execute
        try writeServerAuth(dir, guildId: "g1", execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive, guildId: "g1")))
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive, guildId: "g2")))
    }

    @Test func serverAuthOneTierDoesNotClearGlobalOtherTier() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE])
        try writeServerAuth(dir, guildId: "g1", execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [ADMIN_ROLE], action: .admin)))
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)))
    }

    @Test func absentServerFieldFallsThroughToGlobal() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let servers = dir.appendingPathComponent("servers", isDirectory: true)
        try FileManager.default.createDirectory(at: servers, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "guildId": "g1"] as [String: Any])
            .write(to: servers.appendingPathComponent("g1.json"))
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [EXEC_ROLE], action: .drive)))
    }

    /// Was: corruptGlobalConfigFailSecureDeny (R3).
    @Test func corruptGlobalConfigStillGrantsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("}{ not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [ADMIN_ROLE], action: .read)))
    }
}

@Suite("ConfigStore.loadAuth")
struct ConfigStoreLoadAuthTests {
    @Test func loadsAuthBlock() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE], execute: [EXEC_ROLE], readOnly: [READ_ROLE], dmPolicy: "allow")
        let g = await store(dir).loadAuth()
        #expect(g.adminRoleIds == [ADMIN_ROLE])
        #expect(g.executeRoleIds == [EXEC_ROLE])
        #expect(g.readOnlyRoleIds == [READ_ROLE])
        #expect(g.dmPolicy == "allow")
    }

    @Test func missingFileFailSecureEmpty() async {
        let g = await ConfigStore(baseDir: tempBaseDir()).loadAuth()
        #expect(g == .empty)
        #expect(g.dmPolicy == "deny")
    }

    @Test func corruptJsonFailSecureEmpty() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("}{ not json \u{00}".utf8).write(to: dir.appendingPathComponent("config.json"))
        let g = await store(dir).loadAuth()
        #expect(g == .empty)
    }

    @Test func invalidGlobalConfigDoesNotPartiallyDecodeAuth() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Missing secrets makes the global config invalid, even though auth itself decodes.
        let obj: [String: Any] = ["version": 2, "auth": ["executeRoleIds": [EXEC_ROLE]]]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("config.json"))
        let g = await store(dir).loadAuth()
        #expect(g == .empty)
    }
}
