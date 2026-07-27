import Testing
@testable import DiscordAgentBridge

private func makeConfig(
    dmPolicy: String = "deny",
    permissionMode: String = "default",
    logLevel: String = "info",
    profiles: [String: Profile] = [:]
) -> AppConfig {
    AppConfig(
        discord: DiscordSecrets(token: "bot-token-abc", clientId: "123456789"),
        auth: GlobalAuth(dmPolicy: dmPolicy),
        defaults: DefaultsSection(permissionMode: permissionMode),
        profiles: profiles,
        logLevel: logLevel
    )
}

@Suite("validateAppConfig")
struct ConfigValidationTests {
    @Test func profileWithValidPermissionModePasses() throws {
        let config = makeConfig(profiles: [
            "readonly": Profile(permissionMode: "plan", allowedTools: [], policyTier: "read-only"),
        ])
        try validateAppConfig(config)
    }

    @Test func profileWithInvalidPermissionModeThrows() {
        let config = makeConfig(profiles: [
            "bogus": Profile(permissionMode: "bogus", allowedTools: [], policyTier: "read-only"),
        ])
        do {
            try validateAppConfig(config)
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(String(describing: error).contains("profiles.bogus.permissionMode"))
        }
    }

    @Test func emptyProfilesPasses() throws {
        try validateAppConfig(makeConfig())
    }

    @Test func existingDmPolicyCheckStillThrows() {
        let config = makeConfig(dmPolicy: "bogus")
        do {
            try validateAppConfig(config)
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(String(describing: error).contains("auth.dmPolicy"))
        }
    }

    @Test func existingLogLevelCheckStillThrows() {
        let config = makeConfig(logLevel: "bogus")
        do {
            try validateAppConfig(config)
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(String(describing: error).contains("logLevel"))
        }
    }
}
