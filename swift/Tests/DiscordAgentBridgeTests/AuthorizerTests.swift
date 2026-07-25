import Testing
import Foundation
@testable import DiscordAgentBridge

// Mirrors src/core/auth.test.ts (minus the out-of-scope server-layer cases — W13 has no
// server layer, D2/Q1=A) plus AuthConfigStore fail-secure fixtures. Zero-entropy role ids.

private let ADMIN_ROLE = "role-admin"
private let EXEC_ROLE = "role-exec"
private let READ_ROLE = "role-read"

private func tempConfigURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-auth-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("config.json", isDirectory: false)
}

// Write a config.json carrying only the auth block we care about.
private func writeAuthConfig(_ url: URL, admin: [String] = [], execute: [String] = [], readOnly: [String] = [], dmPolicy: String = "deny") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let auth: [String: Any] = [
        "adminRoleIds": admin,
        "executeRoleIds": execute,
        "readOnlyRoleIds": readOnly,
        "dmPolicy": dmPolicy,
    ]
    let obj: [String: Any] = ["version": 2, "auth": auth]
    try JSONSerialization.data(withJSONObject: obj).write(to: url)
}

private func authorizer(_ url: URL) -> Authorizer { Authorizer(config: AuthConfigStore(fileURL: url)) }

private func input(userId: String = "u1", roleIds: [String] = [], action: AuthAction = .read, guildId: String? = "g1", channelId: String? = "c1", isAdministrator: Bool = false) -> AuthInput {
    AuthInput(userId: userId, roleIds: roleIds, action: action, guildId: guildId, channelId: channelId, isAdministrator: isAdministrator)
}

@Suite("Authorizer")
struct AuthorizerTests {
    @Test func failSecureEmptyAllowlistsDenyEveryoneEvenRead() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url) // empty allowlists
        let r = await authorizer(url).authorize(input(roleIds: [ADMIN_ROLE], action: .read))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("fail-secure") == true)
    }

    @Test func adminTierAllowedEveryAction() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, admin: [ADMIN_ROLE])
        let authz = authorizer(url)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            let r = await authz.authorize(input(roleIds: [ADMIN_ROLE], action: action))
            #expect(r.allowed == true)
            #expect(r.tier == .admin)
        }
    }

    @Test func executeTierMayDriveAndRunButNotAdmin() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, execute: [EXEC_ROLE])
        let authz = authorizer(url)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .runCommand)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .read)).allowed == true)
        let denied = await authz.authorize(input(roleIds: [EXEC_ROLE], action: .admin))
        #expect(denied.allowed == false)
        #expect(denied.tier == .execute)
    }

    @Test func readOnlyTierMayReadButNotDriveRunAdmin() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, readOnly: [READ_ROLE])
        let authz = authorizer(url)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .read)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .drive)).allowed == false)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .runCommand)).allowed == false)
        #expect(await authz.authorize(input(roleIds: [READ_ROLE], action: .admin)).allowed == false)
    }

    @Test func unknownOrNoRoleDeniedFailSecure() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, execute: [EXEC_ROLE])
        let authz = authorizer(url)
        #expect(await authz.authorize(input(roleIds: [], action: .read)).allowed == false)
        #expect(await authz.authorize(input(roleIds: ["role-stranger"], action: .read)).allowed == false)
    }

    @Test func perProjectAclNarrowsTierClearedActor() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: [])
        let denied = await authorizer(url).authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: acl)
        #expect(denied.allowed == false)
        #expect(denied.reason?.contains("projectAuth") == true)
        #expect(denied.tier == .execute)
    }

    @Test func perProjectAclAdmitsMatchingRoleOrUser() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, execute: [EXEC_ROLE])
        let authz = authorizer(url)
        let byRole = ProjectAuth(allowedRoleIds: [EXEC_ROLE], allowedUserIds: [])
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive), projectAuth: byRole).allowed == true)
        let byUser = ProjectAuth(allowedRoleIds: ["role-other"], allowedUserIds: ["u1"])
        #expect(await authz.authorize(input(userId: "u1", roleIds: [EXEC_ROLE], action: .drive), projectAuth: byUser).allowed == true)
    }

    @Test func dmDeniedByDefault() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, admin: [ADMIN_ROLE]) // dmPolicy defaults to deny
        let r = await authorizer(url).authorize(input(roleIds: [ADMIN_ROLE], action: .read, guildId: nil, channelId: nil))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("dmPolicy=deny") == true)
    }

    @Test func dmAllowedWhenPolicyAllowAndTierClears() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, admin: [ADMIN_ROLE], dmPolicy: "allow")
        let authz = authorizer(url)
        #expect(await authz.authorize(input(roleIds: [ADMIN_ROLE], action: .admin, guildId: nil, channelId: nil)).allowed == true)
        // Still tier-gated in a DM: a stranger is denied.
        #expect(await authz.authorize(input(roleIds: [], action: .read, guildId: nil, channelId: nil)).allowed == false)
    }

    @Test func administratorWithNoRoleAuthorizedAsAdmin() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url) // empty allowlists
        let authz = authorizer(url)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            let r = await authz.authorize(input(roleIds: [], action: action, isAdministrator: true))
            #expect(r.allowed == true)
            #expect(r.tier == .admin)
        }
    }

    @Test func nonAdminWithNoRoleDenied() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url) // empty allowlists
        let r = await authorizer(url).authorize(input(roleIds: [], action: .read, isAdministrator: false))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("fail-secure") == true)
    }

    @Test func configuredRolesWorkForNonAdministrator() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, execute: [EXEC_ROLE])
        let authz = authorizer(url)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .drive)).allowed == true)
        #expect(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .admin)).allowed == false)
    }

    @Test func administratorBypassesNarrowingProjectAcl() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: [])
        let r = await authorizer(url).authorize(input(roleIds: [], action: .drive, isAdministrator: true), projectAuth: acl)
        #expect(r.allowed == true)
        #expect(r.tier == .admin)
    }

    @Test func deniedDmNotRescuedByAdministratorFlag() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url) // dmPolicy defaults to deny
        let r = await authorizer(url).authorize(input(roleIds: [], action: .read, guildId: nil, channelId: nil, isAdministrator: true))
        #expect(r.allowed == false)
        #expect(r.reason?.contains("dmPolicy=deny") == true)
    }
}

@Suite("AuthConfigStore")
struct AuthConfigStoreTests {
    @Test func loadsAuthBlock() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeAuthConfig(url, admin: [ADMIN_ROLE], execute: [EXEC_ROLE], readOnly: [READ_ROLE], dmPolicy: "allow")
        let g = await AuthConfigStore(fileURL: url).load()
        #expect(g.adminRoleIds == [ADMIN_ROLE])
        #expect(g.executeRoleIds == [EXEC_ROLE])
        #expect(g.readOnlyRoleIds == [READ_ROLE])
        #expect(g.dmPolicy == "allow")
    }

    @Test func missingFileFailSecureEmpty() async {
        let g = await AuthConfigStore(fileURL: tempConfigURL()).load() // never written
        #expect(g == .empty)
        #expect(g.dmPolicy == "deny")
    }

    @Test func corruptJsonFailSecureEmpty() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("}{ not json \u{00}".utf8).write(to: url)
        let g = await AuthConfigStore(fileURL: url).load() // must not throw
        #expect(g == .empty)
    }

    @Test func absentFieldsFallBackToEmptyAndDeny() async throws {
        let url = tempConfigURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // auth block present but only executeRoleIds set — other fields absent.
        let obj: [String: Any] = ["version": 2, "auth": ["executeRoleIds": [EXEC_ROLE]]]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        let g = await AuthConfigStore(fileURL: url).load()
        #expect(g.executeRoleIds == [EXEC_ROLE])
        #expect(g.adminRoleIds.isEmpty)
        #expect(g.readOnlyRoleIds.isEmpty)
        #expect(g.dmPolicy == "deny")
    }
}
