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

// Write a minimal config.json (secrets + auth) via JSON so loadAuth partial-tolerates.
private func writeAuthConfig(
    _ dir: URL,
    admin: [String] = [],
    execute: [String] = [],
    readOnly: [String] = [],
    dmPolicy: String = "deny"
) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let auth: [String: Any] = [
        "adminRoleIds": admin,
        "executeRoleIds": execute,
        "readOnlyRoleIds": readOnly,
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

@Suite("Authorizer")
struct AuthorizerTests {
    @Test func failSecureEmptyAllowlistsDenyEveryoneEvenRead() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        let r = await authorizer(dir).authorize(input(roleIds: [ADMIN_ROLE], action: .read))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("fail-secure") == true)
    }

    @Test func adminTierAllowedEveryAction() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE])
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            let r = await authz.authorize(input(roleIds: [ADMIN_ROLE], action: action))
            #expect(r.allowed == true)
            #expect(r.tier == .admin)
        }
    }

    @Test func executeTierMayDriveAndRunButNotAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .runCommand)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .read)).allowed == true)
        let denied = await authz.authorize(input(roleIds: [EXEC_ROLE], action: .admin))
        #expect(denied.allowed == false)
        #expect(denied.tier == .execute)
    }

    @Test func readOnlyTierMayReadButNotDriveRunAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, readOnly: [READ_ROLE])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .read)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .drive)).allowed == false)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .runCommand)).allowed == false)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .admin)).allowed == false)
    }

    @Test func unknownOrNoRoleDeniedFailSecure() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [], action: .read)).allowed == false)
        #expect(await authz.authorize(input(roleIds: ["role-stranger"], action: .read)).allowed == false)
    }

    @Test func perProjectAclNarrowsTierClearedActor() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: [])
        let denied = await authorizer(dir).authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: acl)
        #expect(denied.allowed == false)
        #expect(denied.reason?.contains("projectAuth") == true)
        #expect(denied.tier == .execute)
    }

    @Test func perProjectAclAdmitsMatchingRoleOrUser() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        let byRole = ProjectAuth(allowedRoleIds: [EXEC_ROLE], allowedUserIds: [])
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: byRole).allowed == true)
        let byUser = ProjectAuth(allowedRoleIds: ["role-other"], allowedUserIds: ["u1"])
        #expect(await authz.authorize(input(userId: "u1", roleIds: [EXEC_ROLE], action: .drive), projectAuth: byUser).allowed == true)
    }

    /// G-P0-05: store-shaped ACL → authorize (DabMain loads PersistedSession.projectAuth).
    @Test func projectAuthFromStoreRowNarrowsAndAdmits() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let storeURL = dir.appendingPathComponent("swift-state.json")
        let store = SessionStore(fileURL: storeURL)
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: ["u-owner"])
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .claude,
                cwd: "/ws",
                guildId: "g1",
                projectAuth: acl,
                updatedAt: "t"
            )
        )
        let fromStore = await store.binding(channelId: "c1")?.projectAuth
        #expect(fromStore == acl)
        let authz = authorizer(dir)
        let denied = await authz.authorize(
            input(userId: "stranger", roleIds: [EXEC_ROLE], action: .drive, channelId: "c1"),
            projectAuth: fromStore
        )
        #expect(denied.allowed == false)
        #expect(denied.reason?.contains("projectAuth") == true)
        let admitted = await authz.authorize(
            input(userId: "u-owner", roleIds: [EXEC_ROLE], action: .drive, channelId: "c1"),
            projectAuth: fromStore
        )
        #expect(admitted.allowed == true)
        #expect(admitted.tier == .execute)
    }

    @Test func nilProjectAuthDoesNotNarrow() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let r = await authorizer(dir).authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: nil)
        #expect(r.allowed == true)
    }

    @Test func dmDeniedByDefault() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE])
        let r = await authorizer(dir).authorize(input(roleIds: [ADMIN_ROLE], action: .read, guildId: nil, channelId: nil))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("dmPolicy=deny") == true)
    }

    @Test func dmAllowedWhenPolicyAllowAndTierClears() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE], dmPolicy: "allow")
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [ADMIN_ROLE], action: .admin, guildId: nil, channelId: nil)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [], action: .read, guildId: nil, channelId: nil)).allowed == false)
    }

    @Test func administratorWithNoRoleAuthorizedAsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            let r = await authz.authorize(input(roleIds: [], action: action, isAdministrator: true))
            #expect(r.allowed == true)
            #expect(r.tier == .admin)
        }
    }

    @Test func nonAdminWithNoRoleDenied() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        let r = await authorizer(dir).authorize(input(roleIds: [], action: .read, isAdministrator: false))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("fail-secure") == true)
    }

    @Test func configuredRolesWorkForNonAdministrator() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .admin)).allowed == false)
    }

    @Test func administratorBypassesNarrowingProjectAcl() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: [])
        let r = await authorizer(dir).authorize(input(roleIds: [], action: .drive, isAdministrator: true), projectAuth: acl)
        #expect(r.allowed == true)
        #expect(r.tier == .admin)
    }

    @Test func deniedDmNotRescuedByAdministratorFlag() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        let r = await authorizer(dir).authorize(input(roleIds: [], action: .read, guildId: nil, channelId: nil, isAdministrator: true))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("dmPolicy=deny") == true)
    }

    // W15-a: server auth layer (TS auth.test.ts)

    @Test func serverExecuteRolesWidenGlobalForThatGuildOnly() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir) // global grants nobody execute
        try writeServerAuth(dir, guildId: "g1", execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive, guildId: "g1")).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive, guildId: "g2")).allowed == false)
    }

    @Test func serverAuthOneTierDoesNotClearGlobalOtherTier() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, admin: [ADMIN_ROLE])
        try writeServerAuth(dir, guildId: "g1", execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(roleIds: [ADMIN_ROLE], action: .admin)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)).allowed == true)
    }

    @Test func absentServerFieldFallsThroughToGlobal() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        // Server file with empty auth object — execute falls through.
        let servers = dir.appendingPathComponent("servers", isDirectory: true)
        try FileManager.default.createDirectory(at: servers, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "guildId": "g1"] as [String: Any])
            .write(to: servers.appendingPathComponent("g1.json"))
        #expect(await authorizer(dir).authorize(input(roleIds: [EXEC_ROLE], action: .drive)).allowed == true)
    }

    @Test func corruptGlobalConfigFailSecureDeny() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("}{ not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        let r = await authorizer(dir).authorize(input(roleIds: [ADMIN_ROLE], action: .read))
        #expect(r.allowed == false)
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

    @Test func absentFieldsFallBackToEmptyAndDeny() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Partial auth-only file (no discord) → full load fails → partial path.
        let obj: [String: Any] = ["version": 2, "auth": ["executeRoleIds": [EXEC_ROLE]]]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("config.json"))
        let g = await store(dir).loadAuth()
        #expect(g.executeRoleIds == [EXEC_ROLE])
        #expect(g.adminRoleIds.isEmpty)
        #expect(g.readOnlyRoleIds.isEmpty)
        #expect(g.dmPolicy == "deny")
    }
}
