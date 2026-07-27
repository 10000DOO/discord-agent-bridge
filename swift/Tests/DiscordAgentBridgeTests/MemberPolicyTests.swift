import Testing
import Foundation
@testable import DiscordAgentBridge

private func memberPolicyDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-member-policy-\(UUID().uuidString)", isDirectory: true)
}

private func memberPolicyStore(_ dir: URL) -> ConfigStore { ConfigStore(baseDir: dir) }

private func memberPolicyConfig(defaultTier: MemberTierSetting = .admin) -> AppConfig {
    AppConfig(
        discord: DiscordSecrets(token: "token", clientId: "client"),
        auth: GlobalAuth(memberDefaultTier: defaultTier)
    )
}

private func memberInput(
    _ userId: String,
    roles: [String] = [],
    action: AuthAction,
    guildId: String = "guild",
    isAdministrator: Bool = false
) -> AuthInput {
    AuthInput(
        userId: userId,
        roleIds: roles,
        action: action,
        guildId: guildId,
        channelId: "channel",
        isAdministrator: isAdministrator
    )
}

@Suite("Guild member default and overrides")
struct MemberPolicyTests {
    @Test func oldGlobalConfigWithoutNewFieldDefaultsToAdminImmediately() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldConfig: [String: Any] = [
            "version": 2,
            "discord": ["token": "token", "clientId": "client"],
            "auth": ["dmPolicy": "deny"],
        ]
        try JSONSerialization.data(withJSONObject: oldConfig)
            .write(to: dir.appendingPathComponent("config.json"))

        let store = memberPolicyStore(dir)
        #expect(try await store.load().auth.memberDefaultTier == .admin)
        let authorizer = Authorizer(config: store)
        for action in [AuthAction.admin, .drive, .runCommand, .read] {
            let result = await authorizer.authorize(memberInput("member", action: action))
            #expect(result.allowed)
            #expect(result.tier == .admin)
        }
    }

    @Test func invalidGlobalConfigFailsSecureWithoutPartialAuthOrAdminMigration() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let invalidConfig: [String: Any] = [
            "version": 2,
            "auth": ["adminUserIds": ["legacy-admin"]],
        ]
        try JSONSerialization.data(withJSONObject: invalidConfig)
            .write(to: dir.appendingPathComponent("config.json"))

        let store = memberPolicyStore(dir)
        #expect(await store.loadAuth() == .empty)
        let authorizer = Authorizer(config: store)
        #expect(!(await authorizer.authorize(memberInput("legacy-admin", action: .admin))).allowed)
        #expect(!(await authorizer.authorize(memberInput("ordinary-member", action: .read))).allowed)
    }

    @Test func defaultAdminOutranksLegacyExecuteAndReadOnlyGrants() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        try await store.save(AppConfig(
            discord: DiscordSecrets(token: "token", clientId: "client"),
            auth: GlobalAuth(
                executeUserIds: ["legacy-execute"],
                readOnlyUserIds: ["legacy-read-only"]
            )
        ))
        let authorizer = Authorizer(config: store)

        for userId in ["legacy-execute", "legacy-read-only"] {
            let result = await authorizer.authorize(memberInput(userId, action: .admin))
            #expect(result.allowed)
            #expect(result.tier == .admin)
        }
    }

    @Test func overrideBeatsLegacyRoleAndUserGrantsAndNoneBlocksCompletely() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        try await store.save(AppConfig(
            discord: DiscordSecrets(token: "token", clientId: "client"),
            auth: GlobalAuth(adminRoleIds: ["legacy-admin"], adminUserIds: ["legacy-user"])
        ))
        try await store.saveServerConfig(ServerConfig(
            guildId: "guild",
            auth: ServerAuthPartial(memberTierOverrides: [
                "legacy-user": .readOnly,
                "execute": .execute,
                "blocked": .none,
            ])
        ))
        let authorizer = Authorizer(config: store)

        let readOnly = await authorizer.authorize(memberInput("legacy-user", roles: ["legacy-admin"], action: .drive))
        #expect(!readOnly.allowed)
        #expect(readOnly.tier == .readOnly)
        let execute = await authorizer.authorize(memberInput("execute", action: .drive))
        #expect(execute.allowed)
        #expect(execute.tier == .execute)
        let blocked = await authorizer.authorize(memberInput("blocked", roles: ["legacy-admin"], action: .read))
        #expect(!blocked.allowed)
        #expect(blocked.reason?.contains("explicitly blocked") == true)
    }

    @Test func serverDefaultOverridesGlobalFallbackWithoutLeakingToOtherGuilds() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        try await store.save(memberPolicyConfig(defaultTier: .none))
        try await store.setServerMemberDefaultTier(guildId: "guild", tier: .execute)
        let authorizer = Authorizer(config: store)

        let inGuild = await authorizer.authorize(memberInput("member", action: .drive))
        #expect(inGuild.allowed)
        #expect(inGuild.tier == .execute)
        let otherGuild = await authorizer.authorize(memberInput("member", action: .read, guildId: "other"))
        #expect(!otherGuild.allowed)
    }

    @Test func actualDiscordAdministratorBypassesNoneOverride() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        try await store.save(memberPolicyConfig())
        try await store.setServerMemberTierOverride(guildId: "guild", userId: "owner", tier: .none)

        let result = await Authorizer(config: store).authorize(memberInput(
            "owner",
            action: .admin,
            isAdministrator: true
        ))
        #expect(result.allowed)
        #expect(result.tier == .admin)
    }

    @Test func serverDefaultAndSingleUserStoreHelpersPreserveExistingFields() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        try await store.saveServerConfig(ServerConfig(
            guildId: "guild",
            auth: ServerAuthPartial(adminRoleIds: ["legacy-admin"]),
            defaults: ServerDefaultsPartial(mode: "codex"),
            presets: [Preset(name: "daily", backend: "claude")]
        ))

        try await store.setServerMemberDefaultTier(guildId: "guild", tier: .execute)
        try await store.setServerMemberTierOverride(guildId: "guild", userId: "member", tier: .readOnly)
        var saved = await store.loadServerConfig(guildId: "guild")
        #expect(saved?.auth?.memberDefaultTier == .execute)
        #expect(saved?.auth?.memberTierOverrides == ["member": .readOnly])
        #expect(saved?.auth?.adminRoleIds == ["legacy-admin"])
        #expect(saved?.defaults?.mode == "codex")
        #expect(saved?.presets == [Preset(name: "daily", backend: "claude")])

        try await store.clearServerMemberTierOverride(guildId: "guild", userId: "member")
        saved = await store.loadServerConfig(guildId: "guild")
        #expect(saved?.auth?.memberTierOverrides == nil)
    }

    @Test func emptyOverrideUserIdAndMalformedServerOverrideAreRejected() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        await #expect(throws: ConfigStoreError.self) {
            try await store.setServerMemberTierOverride(guildId: "guild", userId: "  ", tier: .admin)
        }
        #expect(throws: ConfigValidationError.self) {
            try validateServerConfig(ServerConfig(
                guildId: "guild",
                auth: ServerAuthPartial(memberTierOverrides: ["": .admin])
            ))
        }
    }

    @Test func corruptServerConfigIsNotOverwrittenByMemberPolicyHelpers() async throws {
        let dir = memberPolicyDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = memberPolicyStore(dir)
        let path = await store.serverConfigPath(guildId: "guild")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{ not valid JSON".utf8)
        try corrupt.write(to: path)

        await #expect(throws: ConfigStoreError.self) {
            try await store.setServerMemberTierOverride(guildId: "guild", userId: "member", tier: .execute)
        }
        #expect(try Data(contentsOf: path) == corrupt)

        await #expect(throws: ConfigStoreError.self) {
            try await store.setServerMemberDefaultTier(guildId: "guild", tier: .readOnly)
        }
        #expect(try Data(contentsOf: path) == corrupt)

        await #expect(throws: ConfigStoreError.self) {
            try await store.clearServerMemberTierOverride(guildId: "guild", userId: "member")
        }
        #expect(try Data(contentsOf: path) == corrupt)
    }
}
