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

@Suite("Authorizer user-id tiers")
struct AuthorizerUserIdTests {
    @Test func adminUserIdWithNoRoleGrantsAdminForEveryAction() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, adminUsers: [ADMIN_USER])
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            let r = await authz.authorize(input(userId: ADMIN_USER, action: action))
            #expect(r.allowed == true)
            #expect(r.tier == .admin)
        }
    }

    @Test func executeUserIdWithNoRoleMayDriveAndRunButNotAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, executeUsers: [EXEC_USER])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(userId: EXEC_USER, action: .drive)).allowed == true)
        #expect(await authz.authorize(input(userId: EXEC_USER, action: .runCommand)).allowed == true)
        #expect(await authz.authorize(input(userId: EXEC_USER, action: .read)).allowed == true)
        let denied = await authz.authorize(input(userId: EXEC_USER, action: .admin))
        #expect(denied.allowed == false)
        #expect(denied.tier == .execute)
    }

    @Test func readOnlyUserIdWithNoRoleMayReadButNotDriveRunAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, readOnlyUsers: [READ_USER])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(userId: READ_USER, action: .read)).allowed == true)
        #expect(await authz.authorize(input(userId: READ_USER, action: .drive)).allowed == false)
        #expect(await authz.authorize(input(userId: READ_USER, action: .runCommand)).allowed == false)
        #expect(await authz.authorize(input(userId: READ_USER, action: .admin)).allowed == false)
    }

    @Test func unknownUserIdWithNoRoleDeniedFailSecure() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, executeUsers: [EXEC_USER])
        let r = await authorizer(dir).authorize(input(userId: "stranger", action: .read))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("fail-secure") == true)
    }

    /// Server layer's adminUserIds widens for that guild only, even though global has none.
    @Test func serverAdminUserIdsWidenGlobalForThatGuildOnly() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir) // global grants nobody anything
        try writeServerAuth(dir, guildId: "g1", adminUsers: [ADMIN_USER])
        let authz = authorizer(dir)
        #expect(await authz.authorize(input(userId: ADMIN_USER, action: .admin, guildId: "g1")).allowed == true)
        #expect(await authz.authorize(input(userId: ADMIN_USER, action: .admin, guildId: "g2")).allowed == false)
    }
}
