import Foundation

private let log = Logger(name: "config")

// Load/save GLOBAL config.json and per-server servers/<guildId>.json (§8).
// baseDir: ctor > DAB_HOME > ~/.discord-agent-bridge/. Atomic write + 0600.
// Mirrors src/core/config.ts. Authorizer uses loadAuth() fail-secure (never throws).

public enum ConfigStoreError: Error, CustomStringConvertible, Sendable {
    case notFound(String)
    case invalidObject(String)
    case validation(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "Config file not found at \(p). Run the setup wizard first."
        case .invalidObject(let p): return "Invalid config file at \(p): expected a JSON object."
        case .validation(let m): return m
        }
    }
}

public actor ConfigStore {
    public static let shared = ConfigStore()

    private let baseDir: URL

    public init(baseDir: URL? = nil) {
        self.baseDir = baseDir ?? Self.defaultBaseDir()
    }

    /// Test helper: directory containing config.json (parent of a file URL).
    public init(configFileURL: URL) {
        self.baseDir = configFileURL.deletingLastPathComponent()
    }

    private static func defaultBaseDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let home = env["DAB_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".discord-agent-bridge", isDirectory: true)
    }

    public var dir: URL { baseDir }

    public var configPath: URL {
        baseDir.appendingPathComponent("config.json", isDirectory: false)
    }

    public func serverConfigPath(guildId: String) -> URL {
        baseDir
            .appendingPathComponent("servers", isDirectory: true)
            .appendingPathComponent("\(guildId).json", isDirectory: false)
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: configPath.path)
    }

    // MARK: - Global

    /// Load config.json with defaults + validate. Missing/invalid → throws (TS strict).
    public func load() throws -> AppConfig {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ConfigStoreError.notFound(path.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw ConfigStoreError.notFound(path.path)
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigStoreError.invalidObject(path.path)
        }
        guard let raw = json as? [String: Any] else {
            throw ConfigStoreError.invalidObject(path.path)
        }
        return try Self.decodeAppConfig(applyDefaults(raw))
    }

    /// Validate then write config.json atomically (tmp + rename); 0600.
    public func save(_ config: AppConfig) throws {
        try validateAppConfig(config)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try Self.writeSecureJSON(to: configPath, value: config)
    }

    /// Fail-secure auth read for Authorizer. Missing/corrupt/invalid → `.empty` (never throws).
    public func loadAuth() -> GlobalAuth {
        do {
            let cfg = try load()
            return cfg.auth
        } catch {
            return .empty
        }
    }

    // MARK: - Server

    /// Fail-safe: missing/corrupt/schema-fail → nil (no throw). normalizeModeId on defaults.mode.
    /// Guild ids that have a `servers/<id>.json` file (for auto-update control-channel fan-out).
    public func listServerGuildIds() -> [String] {
        let dir = baseDir.appendingPathComponent("servers", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    public func loadServerConfig(guildId: String) -> ServerConfig? {
        let path = serverConfigPath(guildId: guildId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        do {
            let data = try Data(contentsOf: path)
            try Self.validateServerJSONNulls(data)
            let cfg = try JSONDecoder().decode(ServerConfig.self, from: data)
            try validateServerConfig(cfg)
            var out = cfg
            if let mode = out.defaults?.mode {
                if out.defaults == nil { out.defaults = ServerDefaultsPartial() }
                out.defaults?.mode = normalizeModeId(mode)
            }
            return out
        } catch {
            log.warn("ignoring corrupt server config \(path.path); falling back to global: \(error)")
            return nil
        }
    }

    public func saveServerConfig(_ config: ServerConfig) throws {
        try validateServerConfig(config)
        let path = serverConfigPath(guildId: config.guildId)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.writeSecureJSON(to: path, value: config)
    }

    // MARK: - Server presets (W11-b2)

    /// Append or overwrite a per-guild session preset (`name` is the unique key). Preserves other
    /// server fields (auth/defaults/locale/…). Write + read-after-write, up to 3 immediate retries.
    public func addServerPreset(guildId: String, preset: Preset) throws {
        let existing = loadServerConfig(guildId: guildId)
        let others = (existing?.presets ?? []).filter { $0.name != preset.name }
        let next = ServerConfig(
            version: existing?.version ?? CONFIG_VERSION,
            guildId: guildId,
            auth: existing?.auth,
            defaults: existing?.defaults,
            limits: existing?.limits,
            locale: existing?.locale,
            auditChannelId: existing?.auditChannelId,
            favorites: existing?.favorites,
            presets: others + [preset],
            channels: existing?.channels,
            notifications: existing?.notifications,
            capabilities: existing?.capabilities
        )
        var lastErr: Error?
        for _ in 0..<3 {
            do {
                try saveServerConfig(next)
                let reloaded = loadServerConfig(guildId: guildId)
                if reloaded?.presets?.contains(where: { $0.name == preset.name }) == true {
                    return
                }
                lastErr = ConfigStoreError.validation(
                    "preset \"\(preset.name)\" not found after save (read-after-write verification failed)"
                )
            } catch {
                lastErr = error
            }
        }
        throw lastErr
            ?? ConfigStoreError.validation("preset save verification failed for guild \(guildId)")
    }

    /// Remove a preset by name. Returns false (no write) when the name or guild config is absent.
    @discardableResult
    public func removeServerPreset(guildId: String, name: String) throws -> Bool {
        let existing = loadServerConfig(guildId: guildId)
        let presets = existing?.presets ?? []
        guard presets.contains(where: { $0.name == name }) else { return false }
        let next = ServerConfig(
            version: existing?.version ?? CONFIG_VERSION,
            guildId: guildId,
            auth: existing?.auth,
            defaults: existing?.defaults,
            limits: existing?.limits,
            locale: existing?.locale,
            auditChannelId: existing?.auditChannelId,
            favorites: existing?.favorites,
            presets: presets.filter { $0.name != name },
            channels: existing?.channels,
            notifications: existing?.notifications,
            capabilities: existing?.capabilities
        )
        try saveServerConfig(next)
        return true
    }

    /// Register `userId` as a server-scoped admin (auth.adminUserIds) for `guildId`. Used by the
    /// first-admin bootstrap: /setup grants itself once when a guild has no admins yet, then
    /// commits the actor as that guild's first admin. Idempotent — already-registered is a no-op.
    /// Preserves all other server fields (mirrors addServerPreset's read-modify-write-and-verify).
    public func addServerAdminUserId(guildId: String, userId: String) throws {
        let existing = loadServerConfig(guildId: guildId)
        var ids = existing?.auth?.adminUserIds ?? []
        guard !ids.contains(userId) else { return }
        ids.append(userId)
        var auth = existing?.auth ?? ServerAuthPartial()
        auth.adminUserIds = ids
        let next = ServerConfig(
            version: existing?.version ?? CONFIG_VERSION,
            guildId: guildId,
            auth: auth,
            defaults: existing?.defaults,
            limits: existing?.limits,
            locale: existing?.locale,
            auditChannelId: existing?.auditChannelId,
            favorites: existing?.favorites,
            presets: existing?.presets,
            channels: existing?.channels,
            notifications: existing?.notifications,
            capabilities: existing?.capabilities
        )
        var lastErr: Error?
        for _ in 0..<3 {
            do {
                try saveServerConfig(next)
                let reloaded = loadServerConfig(guildId: guildId)
                if reloaded?.auth?.adminUserIds?.contains(userId) == true {
                    return
                }
                lastErr = ConfigStoreError.validation(
                    "admin userId \(userId) not found after save (read-after-write verification failed)"
                )
            } catch {
                lastErr = error
            }
        }
        throw lastErr
            ?? ConfigStoreError.validation("admin bootstrap save verification failed for guild \(guildId)")
    }

    /// Set one final, guild-scoped member policy exception. This deliberately does not touch the
    /// legacy user allowlists: those remain readable for compatibility but cannot override this
    /// explicit setting during authorization.
    public func setServerMemberTierOverride(
        guildId: String,
        userId: String,
        tier: MemberTierSetting
    ) throws {
        let trimmedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserId.isEmpty else {
            throw ConfigStoreError.validation("member tier override userId must not be empty")
        }
        let existing = try existingServerConfigForMemberPolicySave(guildId: guildId)
        var auth = existing?.auth ?? ServerAuthPartial()
        var overrides = auth.memberTierOverrides ?? [:]
        overrides[trimmedUserId] = tier
        auth.memberTierOverrides = overrides
        try saveMemberPolicyServerConfig(guildId: guildId, existing: existing, auth: auth)
    }

    /// Remove one member exception so the user returns to the effective guild default.
    public func clearServerMemberTierOverride(guildId: String, userId: String) throws {
        let trimmedUserId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserId.isEmpty else {
            throw ConfigStoreError.validation("member tier override userId must not be empty")
        }
        guard let existing = try existingServerConfigForMemberPolicySave(guildId: guildId) else { return }
        var auth = existing.auth ?? ServerAuthPartial()
        var overrides = auth.memberTierOverrides ?? [:]
        guard overrides.removeValue(forKey: trimmedUserId) != nil else { return }
        auth.memberTierOverrides = overrides.isEmpty ? nil : overrides
        try saveMemberPolicyServerConfig(guildId: guildId, existing: existing, auth: auth)
    }

    /// Persist a guild-local member fallback. It only affects members without an explicit
    /// override or a legacy role/user grant.
    public func setServerMemberDefaultTier(guildId: String, tier: MemberTierSetting) throws {
        let existing = try existingServerConfigForMemberPolicySave(guildId: guildId)
        var auth = existing?.auth ?? ServerAuthPartial()
        auth.memberDefaultTier = tier
        try saveMemberPolicyServerConfig(guildId: guildId, existing: existing, auth: auth)
    }

    /// A missing server file is the only case where member-policy setters may create one. A
    /// present but unreadable/invalid file must remain intact for an operator to repair.
    private func existingServerConfigForMemberPolicySave(guildId: String) throws -> ServerConfig? {
        let path = serverConfigPath(guildId: guildId)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let existing = loadServerConfig(guildId: guildId) else {
            throw ConfigStoreError.validation(
                "existing server config at \(path.path) is unreadable or invalid; refusing to overwrite it"
            )
        }
        return existing
    }

    private func saveMemberPolicyServerConfig(
        guildId: String,
        existing: ServerConfig?,
        auth: ServerAuthPartial
    ) throws {
        var next = existing ?? ServerConfig(guildId: guildId)
        next.version = existing?.version ?? CONFIG_VERSION
        next.guildId = guildId
        next.auth = auth
        var lastErr: Error?
        for _ in 0..<3 {
            do {
                try saveServerConfig(next)
                guard let reloaded = loadServerConfig(guildId: guildId), reloaded.auth == auth else {
                    lastErr = ConfigStoreError.validation(
                        "member policy not preserved after save (read-after-write verification failed)"
                    )
                    continue
                }
                return
            } catch {
                lastErr = error
            }
        }
        throw lastErr
            ?? ConfigStoreError.validation("member policy save verification failed for guild \(guildId)")
    }

    // MARK: - Nice-to-have (cheap)

    /// Append tool to global autoAllowClaudeTools (§7A/§8.1 always-allow). Idempotent: a tool
    /// already present is a no-op. Returns whether the config was changed.
    public func addAutoAllowClaudeTool(_ toolName: String) throws -> Bool {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var config = try load()
        if config.autoAllowClaudeTools.contains(trimmed) { return false }
        config.autoAllowClaudeTools.append(trimmed)
        try save(config)
        return true
    }

    /// Current global auto-allow list, or empty when config is missing/unreadable (fail-closed).
    public func autoAllowClaudeTools() -> [String] {
        (try? load())?.autoAllowClaudeTools ?? []
    }

    public func setRenderEnabled(_ enabled: Bool) throws {
        var config = try load()
        config.render = RenderSection(enabled: enabled)
        try save(config)
    }

    public func setChromiumDecision(_ decision: String) throws {
        var config = try load()
        config.chromium = ChromiumSection(decision: decision)
        try save(config)
    }

    // MARK: - Decode / disk

    private static func decodeAppConfig(_ dict: [String: Any]) throws -> AppConfig {
        // Malformed nested sections (array/primitive) → JSONSerialization keeps them → decode fails.
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: dict)
        } catch {
            throw ConfigStoreError.validation("config is not a JSON object tree")
        }
        let cfg: AppConfig
        do {
            cfg = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw ConfigStoreError.validation(String(describing: error))
        }
        do {
            try validateAppConfig(cfg)
        } catch {
            throw ConfigStoreError.validation(String(describing: error))
        }
        var out = cfg
        out.defaults.mode = normalizeModeId(out.defaults.mode)
        return out
    }

    /// JSONDecoder accepts null for every Optional, while the TS schema only permits it on
    /// nullable leaves. Reject a server file with a null in any other declared field so the
    /// fail-safe load path drops the whole override instead of silently widening it.
    private static func validateServerJSONNulls(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try rejectNulls(
            in: root,
            checking: ["version", "guildId", "auth", "defaults", "limits", "locale", "auditChannelId", "favorites", "presets", "channels", "notifications", "capabilities"],
            allowing: ["auditChannelId"]
        )

        if let auth = root["auth"] as? [String: Any] {
            try rejectNulls(in: auth, checking: ["adminRoleIds", "executeRoleIds", "readOnlyRoleIds", "adminUserIds", "executeUserIds", "readOnlyUserIds", "memberDefaultTier", "memberTierOverrides"], allowing: [])
        }
        if let defaults = root["defaults"] as? [String: Any] {
            try rejectNulls(in: defaults, checking: ["mode", "claudeModel", "codexModel", "permissionMode", "permissionProfile", "codexHome", "claudeEffort", "codexEffort"], allowing: ["permissionProfile"])
        }
        if let limits = root["limits"] as? [String: Any] {
            try rejectNulls(in: limits, checking: ["maxSessionsPerUser", "permissionTimeoutSec", "codexTimeoutMs"], allowing: [])
        }
        if let channels = root["channels"] as? [String: Any] {
            try rejectNulls(in: channels, checking: ["categoryId", "controlChannelId", "sessionsCategoryId", "statusChannelId"], allowing: ["statusChannelId"])
        }
        if let notifications = root["notifications"] as? [String: Any] {
            try rejectNulls(in: notifications, checking: ["enabled", "channelId", "events"], allowing: ["channelId"])
            if let events = notifications["events"] as? [String: Any] {
                try rejectNulls(in: events, checking: ["result", "error", "toolUse"], allowing: [])
            }
        }
        if let capabilities = root["capabilities"] as? [String: Any] {
            try rejectNulls(in: capabilities, checking: ["streaming", "toolThreads", "fileDiff", "usagePanel"], allowing: [])
        }
        if let presets = root["presets"] as? [[String: Any]] {
            for preset in presets {
                try rejectNulls(in: preset, checking: ["name", "backend", "model", "effort", "permMode", "profile"], allowing: ["profile"])
            }
        }
    }

    private static func rejectNulls(
        in object: [String: Any],
        checking fields: Set<String>,
        allowing allowed: Set<String>
    ) throws {
        for (key, value) in object where fields.contains(key) && value is NSNull && !allowed.contains(key) {
            throw ConfigStoreError.validation("server config field \(key) must not be null")
        }
    }

    /// Atomic write (tmp + rename), 0600. Matches SessionStore.writeFile + TS writeSecure.
    static func writeSecureJSON<T: Encodable>(to url: URL, value: T) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(value)
        // Trailing newline (TS always `\n`).
        if data.last != UInt8(ascii: "\n") {
            data.append(UInt8(ascii: "\n"))
        }
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        // Final path must be 0600 (secrets live here). Hard-fail if chmod fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
