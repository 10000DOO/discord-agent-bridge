import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-cfgres-\(UUID().uuidString)", isDirectory: true)
}

private func makeConfig(
    claudeModel: String = "opus",
    permissionMode: String = "default",
    claudeEffort: String? = nil
) -> AppConfig {
    var d = DefaultsSection(claudeModel: claudeModel, permissionMode: permissionMode)
    d.claudeEffort = claudeEffort
    return AppConfig(
        discord: DiscordSecrets(token: "bot-token-abc", clientId: "123456789"),
        defaults: d,
        limits: LimitsSection()
    )
}

@Suite("ConfigResolver")
struct ConfigResolverTests {
    @Test func globalOnly() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(claudeModel: "sonnet", permissionMode: "plan"))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        let r = try await resolver.resolve(guildId: "g1", channelId: "c1")
        #expect(r.claudeModel == "sonnet")
        #expect(r.permissionMode == "plan")
        #expect(r.mode == "claude")
        #expect(r.limits.permissionTimeoutSec == 0)
    }

    @Test func serverOverridesGlobalUnsetFallsThrough() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "codex", permissionMode: "acceptEdits")
        ))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        let r = try await resolver.resolve(guildId: "g1", channelId: "c1")
        #expect(r.mode == "codex")
        #expect(r.permissionMode == "acceptEdits")
        #expect(r.claudeModel == "opus")
    }

    @Test func otherGuildUnaffected() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "codex")
        ))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        #expect(try await resolver.resolve(guildId: "g1", channelId: "c1").mode == "codex")
        #expect(try await resolver.resolve(guildId: "g2", channelId: "c1").mode == "claude")
    }

    @Test func bindingOverridesServerAndGlobal() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(
                mode: "codex",
                permissionMode: "acceptEdits",
                permissionProfile: "server-prof"
            )
        ))
        let bindings = MapBindingSource([
            "g1:c1": ConfigBindingLayer(mode: "claude", permissionMode: "plan", permissionProfile: "proj-prof"),
        ])
        let resolver = ConfigResolver(configStore: store, bindingSource: bindings)
        let r = try await resolver.resolve(guildId: "g1", channelId: "c1")
        #expect(r.mode == "claude")
        #expect(r.permissionMode == "plan")
        #expect(r.permissionProfile == "proj-prof")
    }

    @Test func deepMergesNestedLimits() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig())
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            limits: PartialLimits(maxSessionsPerUser: 3)
        ))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        let r = try await resolver.resolve(guildId: "g1", channelId: "c1")
        #expect(r.limits.maxSessionsPerUser == 3)
        #expect(r.limits.permissionTimeoutSec == 0)
        #expect(r.limits.codexTimeoutMs == 1_800_000)
    }

    @Test func missingProjectFallsThroughToServerThenGlobal() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(permissionMode: "default"))
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(permissionMode: "plan")
        ))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        #expect(try await resolver.resolve(guildId: "g1", channelId: "c1").permissionMode == "plan")
        #expect(try await resolver.resolve(guildId: "g3", channelId: "c9").permissionMode == "default")
    }

    @Test func resolveModeConfigNarrows() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(claudeModel: "haiku"))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        let view = try await resolver.resolveModeConfig(guildId: "g1", channelId: "c1")
        #expect(view.model == "haiku")
        #expect(view.codexHome == "~/.codex")
        #expect(view.permissionTimeoutSec == 0)
        #expect(view.codexTimeoutMs == 1_800_000)
    }

    @Test func effortLayersServerOverGlobal() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(baseDir: dir)
        try await store.save(makeConfig(claudeEffort: "high"))
        try await store.saveServerConfig(ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(claudeEffort: "medium", codexEffort: "low")
        ))
        let resolver = ConfigResolver(configStore: store, bindingSource: MapBindingSource())
        let r = try await resolver.resolve(guildId: "g1", channelId: "c1")
        #expect(r.claudeEffort == "medium")
        #expect(r.codexEffort == "low")
        let g2 = try await resolver.resolve(guildId: "g2", channelId: "c1")
        #expect(g2.claudeEffort == "high")
        #expect(g2.codexEffort == nil)
    }

    @Test func pureMergeWithoutDisk() {
        let global = makeConfig(claudeModel: "opus", permissionMode: "default")
        let server = ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(mode: "codex"),
            limits: PartialLimits(maxSessionsPerUser: 2)
        )
        let binding = ConfigBindingLayer(mode: "claude", permissionMode: "plan")
        let r = ConfigResolver.merge(global: global, server: server, binding: binding)
        #expect(r.mode == "claude")
        #expect(r.permissionMode == "plan")
        #expect(r.claudeModel == "opus")
        #expect(r.limits.maxSessionsPerUser == 2)
    }

    @Test func emptyBindingPermModeFallsThrough() {
        let global = makeConfig(permissionMode: "default")
        let server = ServerConfig(
            version: 1,
            guildId: "g1",
            defaults: ServerDefaultsPartial(permissionMode: "plan")
        )
        // nil / empty permissionMode must not override server/global.
        let rNil = ConfigResolver.merge(
            global: global, server: server,
            binding: ConfigBindingLayer(mode: "claude", permissionMode: nil)
        )
        #expect(rNil.permissionMode == "plan")
        let rEmpty = ConfigResolver.merge(
            global: global, server: server,
            binding: ConfigBindingLayer(mode: "claude", permissionMode: "")
        )
        #expect(rEmpty.permissionMode == "plan")
    }

    @Test func sessionStoreBindingSourceNormalizesAndSkipsArchived() async throws {
        let store = freshTempStore()
        try await store.upsert(
            channelId: "c1",
            PersistedSession(
                backend: .grok, cwd: "/x", guildId: "g1",
                permMode: "", permissionProfile: "p1",
                updatedAt: "t"
            )
        )
        try await store.upsert(
            channelId: "c-arch",
            PersistedSession(backend: .claude, cwd: "/y", guildId: "g1", updatedAt: "t", archived: true)
        )
        let src = SessionStoreBindingSource(store: store)
        let layer = await src.configBinding(guildId: "g1", channelId: "c1")
        #expect(layer?.mode == "grok-build")          // normalizeModeId
        #expect(layer?.permissionMode == nil)         // empty → fall through
        #expect(layer?.permissionProfile == "p1")
        #expect(await src.configBinding(guildId: "g1", channelId: "c-arch") == nil)
    }
}
