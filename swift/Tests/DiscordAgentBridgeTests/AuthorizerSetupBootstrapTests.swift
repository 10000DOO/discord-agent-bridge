import Testing
import Foundation
@testable import DiscordAgentBridge

// WO-5 (docs/post-swift-cutover-issues.md §D "최초 관리자 자동 부트스트랩" / §6 WO-5):
// /setup bypasses the normal admin gate exactly once per guild — only while that guild's
// EFFECTIVE admin role+user allowlists are both empty — then commits the actor as the first
// server-scoped admin. Once any admin role/user exists, the bypass never fires again.

private func tempBaseDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-setup-bootstrap-\(UUID().uuidString)", isDirectory: true)
}

private func store(_ dir: URL) -> ConfigStore { ConfigStore(baseDir: dir) }
private func authorizer(_ dir: URL) -> Authorizer { Authorizer(config: store(dir)) }

@Suite("Setup bootstrap (first-admin)")
struct AuthorizerSetupBootstrapTests {
    @Test func eligibleWhenNoConfigExistsAtAll() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await authorizer(dir).isSetupBootstrapEligible(guildId: "g1") == true)
    }

    @Test func eligibleWhenConfigExistsButAdminListsEmpty() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["version": 2, "discord": ["token": "t", "clientId": "c"]]
        try JSONSerialization.data(withJSONObject: obj).write(to: dir.appendingPathComponent("config.json"))
        #expect(await authorizer(dir).isSetupBootstrapEligible(guildId: "g1") == true)
    }

    @Test func notEligibleOnceGlobalAdminRoleExists() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).save(AppConfig(
            discord: DiscordSecrets(token: "t", clientId: "c"),
            auth: GlobalAuth(adminRoleIds: ["role-1"])
        ))
        #expect(await authorizer(dir).isSetupBootstrapEligible(guildId: "g1") == false)
    }

    @Test func notEligibleOnceGlobalAdminUserExists() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).save(AppConfig(
            discord: DiscordSecrets(token: "t", clientId: "c"),
            auth: GlobalAuth(adminUserIds: ["someone-already-admin"])
        ))
        #expect(await authorizer(dir).isSetupBootstrapEligible(guildId: "g1") == false)
    }

    @Test func notEligibleOnceServerLayerHasAdminForThatGuildOnly() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // Global stays empty; only g1's server config already has an admin.
        try await store(dir).saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(adminUserIds: ["already-admin"])
        ))
        #expect(await authorizer(dir).isSetupBootstrapEligible(guildId: "g1") == false)
        // A sibling guild with no server config of its own is unaffected.
        #expect(await authorizer(dir).isSetupBootstrapEligible(guildId: "g2") == true)
    }

    @Test func addServerAdminUserIdCreatesServerConfigWhenMissing() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).addServerAdminUserId(guildId: "gNew", userId: "u1")
        let loaded = await store(dir).loadServerConfig(guildId: "gNew")
        #expect(loaded?.auth?.adminUserIds == ["u1"])
    }

    @Test func addServerAdminUserIdIsIdempotent() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).addServerAdminUserId(guildId: "g1", userId: "u1")
        try await store(dir).addServerAdminUserId(guildId: "g1", userId: "u1")
        #expect(await store(dir).loadServerConfig(guildId: "g1")?.auth?.adminUserIds == ["u1"])
    }

    @Test func addServerAdminUserIdPreservesOtherServerFields() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).saveServerConfig(ServerConfig(
            guildId: "g1",
            auth: ServerAuthPartial(adminRoleIds: ["role-1"]),
            defaults: ServerDefaultsPartial(mode: "codex"),
            locale: "en"
        ))
        try await store(dir).addServerAdminUserId(guildId: "g1", userId: "u1")
        let loaded = await store(dir).loadServerConfig(guildId: "g1")
        #expect(loaded?.auth?.adminUserIds == ["u1"])
        #expect(loaded?.auth?.adminRoleIds == ["role-1"])
        #expect(loaded?.defaults?.mode == "codex")
        #expect(loaded?.locale == "en")
    }

    // WO-8b regression: redmine/capabilities must survive partial-reconstruction saves.
    @Test func addServerAdminUserIdPreservesRedmineAndCapabilities() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let redmine = RedmineSection(url: "https://redmine.example.com", apiKeyEncrypted: Data("cipher".utf8))
        let capabilities = CapabilitiesPartial(fileDiff: false)
        try await store(dir).saveServerConfig(ServerConfig(
            guildId: "g1",
            capabilities: capabilities,
            redmine: redmine
        ))
        try await store(dir).addServerAdminUserId(guildId: "g1", userId: "u1")
        let loaded = await store(dir).loadServerConfig(guildId: "g1")
        #expect(loaded?.auth?.adminUserIds == ["u1"])
        #expect(loaded?.redmine == redmine)
        #expect(loaded?.capabilities == capabilities)
    }

    /// End-to-end: DabMain.swift wires exactly this sequence around /setup (the executable `dab`
    /// target has no test target of its own — WO-1/WO-2 test the library calls it wires up the
    /// same way). An unauthorized actor on a never-bootstrapped guild bypasses the gate, /setup
    /// "succeeds", and the actor is committed as admin — after which they (and only they) hold
    /// admin via the normal role/user allowlist path, with no special-casing left behind.
    @Test func bootstrapAllowsFirstActorThenGrantsAdminGoingForward() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let authz = authorizer(dir)
        let actor = AuthInput(userId: "first-user", roleIds: [], action: .admin, guildId: "g1", channelId: "c1")

        // Pre-check: nobody is admin anywhere, so bootstrap fires for this actor on this guild.
        #expect(await authz.isSetupBootstrapEligible(guildId: "g1") == true)
        #expect(await authz.authorize(actor).allowed == false) // the normal gate alone would deny

        // /setup "succeeds" → DabMain commits the actor as this guild's first admin.
        try await store(dir).addServerAdminUserId(guildId: "g1", userId: "first-user")

        // Now the normal gate grants them admin without any bootstrap special-casing.
        let result = await authz.authorize(actor)
        #expect(result.allowed == true)
        #expect(result.tier == .admin)
    }

    /// Once a guild has ANY admin (role or user), the bootstrap special case must never fire
    /// again for a different actor — otherwise anyone could grab admin at any time.
    @Test func secondActorIsDeniedOnceGuildAlreadyHasAnAdmin() async throws {
        let dir = tempBaseDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try await store(dir).addServerAdminUserId(guildId: "g1", userId: "first-user")
        let authz = authorizer(dir)

        #expect(await authz.isSetupBootstrapEligible(guildId: "g1") == false)
        let other = AuthInput(userId: "second-user", roleIds: [], action: .admin, guildId: "g1", channelId: "c1")
        let result = await authz.authorize(other)
        #expect(result.allowed == false)
        #expect(result.reason?.contains("fail-secure") == true)
    }
}
