import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-cfg-\(UUID().uuidString)", isDirectory: true)
}

private func makeConfig(mode: String = "claude", locale: String = "ko") -> AppConfig {
    AppConfig(
        discord: DiscordSecrets(token: "bot-token-abc", clientId: "123456789"),
        auth: GlobalAuth(adminRoleIds: ["a1"]),
        defaults: DefaultsSection(mode: mode, permissionMode: "default"),
        limits: LimitsSection(maxSessionsPerUser: 0, permissionTimeoutSec: 60, codexTimeoutMs: 1_800_000),
        locale: locale
    )
}

@Suite("ConfigStore")
struct ConfigStoreTests {
    @Test func roundTripSaveLoad() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        let config = makeConfig(locale: "en")
        try await store.save(config)
        let loaded = try await store.load()
        #expect(loaded.locale == "en")
        #expect(loaded.discord.token == "bot-token-abc")
        #expect(loaded.auth.adminRoleIds == ["a1"])
        #expect(loaded.defaults.mode == "claude")
        #expect(loaded.version == CONFIG_VERSION)
    }

    @Test func appliesDefaultsForMinimalSecretsOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw: [String: Any] = ["discord": ["token": "t", "clientId": "c"]]
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: dir.appendingPathComponent("config.json"))
        let loaded = try await ConfigStore(baseDir: dir).load()
        #expect(loaded.version == CONFIG_VERSION)
        #expect(loaded.defaults.mode == "claude")
        #expect(loaded.defaults.claudeModel == "opus")
        #expect(loaded.limits.permissionTimeoutSec == 0)
        #expect(loaded.policy.unknownCommand == "confirm")
        #expect(loaded.autoAllowClaudeTools == ["Read", "Glob", "Grep"])
        #expect(loaded.auth.dmPolicy == "deny")
        #expect(loaded.logLevel == "info")
        #expect(loaded.autoUpdate.enabled == true)
        #expect(loaded.render?.enabled == true)
        #expect(loaded.chromium?.decision == "undecided")
    }

    @Test func nestedLimitsMergeSiblingsDefault() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw: [String: Any] = [
            "discord": ["token": "t", "clientId": "c"],
            "limits": ["maxSessionsPerUser": 5],
        ]
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: dir.appendingPathComponent("config.json"))
        let loaded = try await ConfigStore(baseDir: dir).load()
        #expect(loaded.limits.maxSessionsPerUser == 5)
        #expect(loaded.limits.codexTimeoutMs == 1_800_000)
    }

    @Test func documentShareLimitsMustBePositive() throws {
        var config = makeConfig()
        config.documentShare = DocumentShareSection(maxBytes: 0)
        #expect(throws: ConfigValidationError.self) {
            try validateAppConfig(config)
        }

        config.documentShare = DocumentShareSection(previewMaxChars: -1)
        #expect(throws: ConfigValidationError.self) {
            try validateAppConfig(config)
        }
    }

    @Test func missingFileThrowsOnLoad() async {
        let store = ConfigStore(baseDir: tempDir())
        #expect(await store.exists() == false)
        do {
            _ = try await store.load()
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(String(describing: error).lowercased().contains("not found"))
        }
    }

    @Test func missingSecretsThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["locale": "ko"] as [String: Any])
            .write(to: dir.appendingPathComponent("config.json"))
        do {
            _ = try await ConfigStore(baseDir: dir).load()
            #expect(Bool(false), "expected throw")
        } catch {
            // validation or decode failure
            #expect(true)
        }
    }

    @Test func malformedNestedAuthArrayThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw: [String: Any] = [
            "discord": ["token": "t", "clientId": "c"],
            "auth": ["x"],
        ]
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: dir.appendingPathComponent("config.json"))
        do {
            _ = try await ConfigStore(baseDir: dir).load()
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(true)
        }
    }

    @Test func malformedDefaultsPrimitiveThrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw: [String: Any] = [
            "discord": ["token": "t", "clientId": "c"],
            "defaults": 5,
        ]
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: dir.appendingPathComponent("config.json"))
        do {
            _ = try await ConfigStore(baseDir: dir).load()
            #expect(Bool(false), "expected throw")
        } catch {
            #expect(true)
        }
    }

    @Test func corruptServerConfigReturnsNull() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        let path = await store.serverConfigPath(guildId: "g1")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: path)
        let s = await store.loadServerConfig(guildId: "g1")
        #expect(s == nil)

        // Schema fail (version wrong type after decode fail)
        try Data(#"{"version":"nope","guildId":"g1"}"#.utf8).write(to: path)
        #expect(await store.loadServerConfig(guildId: "g1") == nil)
    }

    @Test func serverConfigWithDisallowedNullReturnsNull() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        let path = await store.serverConfigPath(guildId: "g1")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        try Data(#"{"version":1,"guildId":"g1","defaults":{"mode":null}}"#.utf8).write(to: path)
        #expect(await store.loadServerConfig(guildId: "g1") == nil)

        try Data(#"{"version":1,"guildId":"g1","defaults":{"permissionProfile":null}}"#.utf8).write(to: path)
        #expect(await store.loadServerConfig(guildId: "g1")?.defaults?.permissionProfileExplicitlyNull == true)
    }

    @Test func serverRoundTrip() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        let server = ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "codex", permissionMode: "plan")
        )
        try await store.saveServerConfig(server)
        let loaded = await store.loadServerConfig(guildId: "g1")
        #expect(loaded?.guildId == "g1")
        #expect(loaded?.defaults?.mode == "codex")
        #expect(loaded?.defaults?.permissionMode == "plan")
        #expect(await store.loadServerConfig(guildId: "missing") == nil)
    }

    @Test func normalizeModeIdOnGlobalDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(mode: "grok"))
        #expect(try await store.load().defaults.mode == "grok-build")
        try await store.save(makeConfig(mode: "grok-agent"))
        #expect(try await store.load().defaults.mode == "grok-build")
    }

    @Test func normalizeModeIdOnServerDefaults() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "grok")
        ))
        #expect(await store.loadServerConfig(guildId: "g1")?.defaults?.mode == "grok-build")
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "grok-agent")
        ))
        #expect(await store.loadServerConfig(guildId: "g1")?.defaults?.mode == "grok-build")
    }

    @Test func futureBackendModeLoadsUnchanged() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(mode: "future-backend"))
        #expect(try await store.load().defaults.mode == "future-backend")
    }

    @Test func permissionsAre0600() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        let path = await store.configPath
        let perms = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        try await store.saveServerConfig(ServerConfig(version: 1, guildId: "g1"))
        let sp = await store.serverConfigPath(guildId: "g1")
        let spPerms = try FileManager.default.attributesOfItem(atPath: sp.path)[.posixPermissions] as? Int
        #expect(spPerms == 0o600)
    }

    @Test func addAutoAllowClaudeToolIdempotent() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        #expect(try await store.addAutoAllowClaudeTool("Bash") == true)
        #expect(try await store.load().autoAllowClaudeTools.contains("Bash"))
        #expect(try await store.addAutoAllowClaudeTool("Bash") == false)
        #expect(await store.autoAllowClaudeTools().contains("Bash"))
    }

    @Test func normalizeModeIdFreeFunction() {
        #expect(normalizeModeId("grok") == "grok-build")
        #expect(normalizeModeId("grok-agent") == "grok-build")
        #expect(normalizeModeId("claude") == "claude")
        #expect(normalizeModeId("grok-build") == "grok-build")
    }

    // MARK: - Server presets (W11-b2)

    @Test func addServerPresetAppendsAndPreservesTopLevelFields() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.saveServerConfig(ServerConfig(
            version: CONFIG_VERSION,
            guildId: "g1",
            auth: ServerAuthPartial(adminRoleIds: ["a1"]),
            defaults: ServerDefaultsPartial(mode: "codex"),
            locale: "en",
            capabilities: CapabilitiesPartial(toolThreads: false, usagePanel: false)
        ))
        try await store.addServerPreset(
            guildId: "g1",
            preset: Preset(name: "p1", backend: "claude", model: "opus")
        )
        let loaded = await store.loadServerConfig(guildId: "g1")
        #expect(loaded?.presets == [Preset(name: "p1", backend: "claude", model: "opus")])
        #expect(loaded?.auth?.adminRoleIds == ["a1"])
        #expect(loaded?.defaults?.mode == "codex")
        #expect(loaded?.locale == "en")
        #expect(loaded?.capabilities == CapabilitiesPartial(toolThreads: false, usagePanel: false))
    }

    @Test func addServerPresetOverwritesSameName() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.addServerPreset(
            guildId: "g1",
            preset: Preset(name: "p1", backend: "claude", model: "opus")
        )
        try await store.addServerPreset(
            guildId: "g1",
            preset: Preset(name: "p1", backend: "codex", model: "gpt-5.5")
        )
        let presets = await store.loadServerConfig(guildId: "g1")?.presets ?? []
        #expect(presets.count == 1)
        #expect(presets[0] == Preset(name: "p1", backend: "codex", model: "gpt-5.5"))
    }

    @Test func addServerPresetCreatesServerConfigWhenMissing() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.addServerPreset(
            guildId: "gNew",
            preset: Preset(name: "p1", backend: "claude")
        )
        #expect(await store.loadServerConfig(guildId: "gNew")?.presets == [
            Preset(name: "p1", backend: "claude"),
        ])
    }

    @Test func removeServerPresetReturnsBool() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.addServerPreset(guildId: "g1", preset: Preset(name: "p1", backend: "claude"))
        try await store.addServerPreset(guildId: "g1", preset: Preset(name: "p2", backend: "codex"))
        #expect(try await store.removeServerPreset(guildId: "g1", name: "p1") == true)
        let names = (await store.loadServerConfig(guildId: "g1")?.presets ?? []).map(\.name)
        #expect(names == ["p2"])
        #expect(try await store.removeServerPreset(guildId: "g1", name: "nope") == false)
        #expect(try await store.removeServerPreset(guildId: "gMissing", name: "p1") == false)
    }

    @Test func presetsSurviveUnrelatedSaveServerConfig() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.addServerPreset(
            guildId: "g1",
            preset: Preset(
                name: "p1",
                backend: "claude",
                model: "opus",
                effort: "high",
                permMode: "plan",
                profile: nil
            )
        )
        guard var existing = await store.loadServerConfig(guildId: "g1") else {
            Issue.record("expected server config"); return
        }
        existing.locale = "en"
        try await store.saveServerConfig(existing)
        #expect(await store.loadServerConfig(guildId: "g1")?.presets == [
            Preset(name: "p1", backend: "claude", model: "opus", effort: "high", permMode: "plan", profile: nil),
        ])
    }
}
