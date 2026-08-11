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

// Open access is hardcoded: authorize() grants the admin tier to every actor for every action,
// in guilds and in DMs, whatever the configuration says. These tests pin that down from the
// directions access used to be narrowed — allowlists, member overrides, project ACLs, dmPolicy —
// and assert none of them bite any more.
@Suite("Authorizer (everyone is admin)")
struct AuthorizerTests {
    private func expectAdmin(_ r: AuthResult) {
        #expect(r.allowed == true)
        #expect(r.tier == .admin)
        #expect(r.reason == nil)
    }

    @Test func everyActionAllowedWithNoConfigAtAll() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            expectAdmin(await authz.authorize(input(roleIds: [], action: action)))
        }
    }

    @Test func emptyAllowlistsNoLongerDenyAnyone() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir) // grants nobody anything, memberDefaultTier "none"
        let authz = authorizer(dir)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            expectAdmin(await authz.authorize(input(roleIds: ["role-stranger"], action: action)))
        }
    }

    @Test func lowerTierRolesStillGetAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE], readOnly: [READ_ROLE])
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [EXEC_ROLE], action: .admin)))
        expectAdmin(await authz.authorize(input(roleIds: [READ_ROLE], action: .admin)))
    }

    @Test func perProjectAclNoLongerNarrows() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, execute: [EXEC_ROLE])
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: ["u-owner"])
        let r = await authorizer(dir).authorize(input(userId: "stranger", roleIds: [], action: .drive), projectAuth: acl)
        expectAdmin(r)
    }

    /// G-P0-05 shape: a stored per-project ACL reaches authorize() and is ignored there.
    @Test func projectAuthFromStoreRowIsIgnored() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(fileURL: dir.appendingPathComponent("swift-state.json"))
        let acl = ProjectAuth(allowedRoleIds: ["role-project"], allowedUserIds: ["u-owner"])
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: "/ws", guildId: "g1", projectAuth: acl, updatedAt: "t")
        )
        let fromStore = await store.binding(channelId: "c1")?.projectAuth
        #expect(fromStore == acl)
        expectAdmin(await authorizer(dir).authorize(
            input(userId: "stranger", roleIds: [], action: .drive, channelId: "c1"),
            projectAuth: fromStore
        ))
    }

    @Test func dmAllowedRegardlessOfDmPolicy() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir, dmPolicy: "deny")
        expectAdmin(await authorizer(dir).authorize(
            input(roleIds: [], action: .admin, guildId: nil, channelId: nil)
        ))
    }

    @Test func nonAdministratorMemberIsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        expectAdmin(await authorizer(dir).authorize(
            input(roleIds: [], action: .admin, isAdministrator: false)
        ))
    }

    @Test func memberTierOverrideIncludingNoneCannotBlock() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cfgStore = store(dir)
        try await cfgStore.setServerMemberTierOverride(guildId: "g1", userId: "blocked", tier: .none)
        expectAdmin(await authorizer(dir).authorize(input(userId: "blocked", roleIds: [], action: .admin)))
    }

    @Test func serverLayerNarrowingHasNoEffectOnAnyGuild() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try writeAuthConfig(dir)
        try writeServerAuth(dir, guildId: "g1", execute: [EXEC_ROLE])
        let authz = authorizer(dir)
        expectAdmin(await authz.authorize(input(roleIds: [], action: .admin, guildId: "g1")))
        expectAdmin(await authz.authorize(input(roleIds: [], action: .admin, guildId: "g2")))
    }

    @Test func corruptGlobalConfigStillGrantsAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("}{ not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        expectAdmin(await authorizer(dir).authorize(input(roleIds: [], action: .admin)))
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
