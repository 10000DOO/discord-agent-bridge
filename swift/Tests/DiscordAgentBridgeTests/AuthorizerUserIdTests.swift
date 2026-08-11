import Testing
import Foundation
@testable import DiscordAgentBridge

// WO-3 (docs/post-swift-cutover-issues.md §D/§6): user-id-based tier grants, OR'd alongside
// the existing role-id allowlists. Mirrors AuthorizerTests.swift fixture conventions.

private let ADMIN_USER = "user-admin"
private let EXEC_USER = "user-exec"
private let READ_USER = "user-read"

private func tempBaseDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-auth-userid-\(UUID().uuidString)", isDirectory: true)
}

private func writeAuthConfig(
    _ dir: URL,
    adminUsers: [String] = [],
    executeUsers: [String] = [],
    readOnlyUsers: [String] = [],
    memberDefaultTier: String = "none"
) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let auth: [String: Any] = [
        "adminUserIds": adminUsers,
        "executeUserIds": executeUsers,
        "readOnlyUserIds": readOnlyUsers,
        "memberDefaultTier": memberDefaultTier,
    ]
    let obj: [String: Any] = [
        "version": 2,
        "discord": ["token": "t", "clientId": "c"],
        "auth": auth,
    ]
    try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("config.json"))
}

private func writeServerAuth(_ dir: URL, guildId: String, adminUsers: [String]? = nil) throws {
    let servers = dir.appendingPathComponent("servers", isDirectory: true)
    try FileManager.default.createDirectory(at: servers, withIntermediateDirectories: true)
    var auth: [String: Any] = [:]
    if let adminUsers { auth["adminUserIds"] = adminUsers }
    let obj: [String: Any] = ["version": 1, "guildId": guildId, "auth": auth]
    try JSONSerialization.data(withJSONObject: obj)
        .write(to: servers.appendingPathComponent("\(guildId).json"))
}

private func store(_ dir: URL) -> ConfigStore { ConfigStore(baseDir: dir) }
private func authorizer(_ dir: URL) -> Authorizer { Authorizer(config: store(dir)) }

private func input(
    userId: String,
    action: AuthAction = .read,
    guildId: String? = "g1"
) -> AuthInput {
    AuthInput(userId: userId, roleIds: [], action: action, guildId: guildId, channelId: "c1")
}

// The user-id allowlists still load and persist, but they no longer decide anything (R1): every
// user id gets the admin tier whether it is listed, listed at a lower tier, or absent entirely.
// Same scenarios as before the change, expectations flipped (R7).
@Suite("Authorizer user-id tiers (all admin)")
struct AuthorizerUserIdTests {
    private func expectAdmin(_ r: AuthResult) {
        #expect(r.allowed == true)
        #expect(r.tier == .admin)
    }

    @Test func adminUserIdWithNoRoleGrantsAdminForEveryAction() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, adminUsers: [ADMIN_USER])
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            expectAdmin(await authz.authorize(input(userId: ADMIN_USER, action: action)))
        }
    }

    /// Was: executeUserIdWithNoRoleMayDriveAndRunButNotAdmin.
    @Test func executeUserIdNowClearsAdminActionAsWell() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, executeUsers: [EXEC_USER])
        let authz = authorizer(dir)
        for action in [AuthAction.drive, .runCommand, .read, .admin] {
            expectAdmin(await authz.authorize(input(userId: EXEC_USER, action: action)))
        }
    }

    /// Was: readOnlyUserIdWithNoRoleMayReadButNotDriveRunAdmin.
    @Test func readOnlyUserIdNowDrivesRunsAndAdministers() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, readOnlyUsers: [READ_USER])
        let authz = authorizer(dir)
        for action in [AuthAction.read, .drive, .runCommand, .admin] {
            expectAdmin(await authz.authorize(input(userId: READ_USER, action: action)))
        }
    }

    /// Was: unknownUserIdWithNoRoleDeniedFailSecure.
    @Test func unknownUserIdWithNoRoleIsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, executeUsers: [EXEC_USER])
        expectAdmin(await authorizer(dir).authorize(input(userId: "stranger", action: .read)))
    }

    /// Was: serverAdminUserIdsWidenGlobalForThatGuildOnly — the sibling guild is open too now.
    @Test func serverAdminUserIdsNoLongerScopeAccessToOneGuild() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir) // global grants nobody anything
        try writeServerAuth(dir, guildId: "g1", adminUsers: [ADMIN_USER])
        let authz = authorizer(dir)
        for guildId in ["g1", "g2"] {
            expectAdmin(await authz.authorize(input(userId: ADMIN_USER, action: .admin, guildId: guildId)))
            expectAdmin(await authz.authorize(input(userId: "stranger", action: .admin, guildId: guildId)))
        }
    }
}
