import Foundation

// Backend (declared in SessionRegistry.swift) is a String raw enum; adopt Codable here (same module)
// via its rawValue so PersistedSession can synthesize encode of the runtime enum. Decode accepts
// retired aliases via normalizeModeId (W15-b).
extension Backend: Codable {}

/// On-disk / in-memory state schema version for `swift-state.json`.
public let STATE_VERSION = 2

/// One channel's session as persisted to disk (for reconnect after a restart).
public struct PersistedSession: Codable, Sendable, Equatable {
    public var backend: Backend
    public var backendSessionId: String?
    public var cwd: String
    public var guildId: String
    public var ownerId: String?
    public var model: String?
    public var effort: String?
    public var permMode: String?
    public var permissionProfile: String?
    public var projectAuth: ProjectAuth?
    public var createdAt: String?
    public var updatedAt: String
    public var archived: Bool

    public init(
        backend: Backend,
        backendSessionId: String? = nil,
        cwd: String,
        guildId: String,
        ownerId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permMode: String? = nil,
        permissionProfile: String? = nil,
        projectAuth: ProjectAuth? = nil,
        createdAt: String? = nil,
        updatedAt: String,
        archived: Bool = false
    ) {
        self.backend = backend
        self.backendSessionId = backendSessionId
        self.cwd = cwd
        self.guildId = guildId
        self.ownerId = ownerId
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.permissionProfile = permissionProfile
        self.projectAuth = projectAuth
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }

    // Custom decode so retired mode strings (`grok`, `grok-agent`, `grok-build`) map to Backend.grok
    // and missing `archived` defaults false (pre-W15-b files).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try c.decode(String.self, forKey: .backend)
        self.backend = Self.backend(fromMode: rawMode)
        self.backendSessionId = try c.decodeIfPresent(String.self, forKey: .backendSessionId)
        self.cwd = try c.decode(String.self, forKey: .cwd)
        self.guildId = try c.decode(String.self, forKey: .guildId)
        self.ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(String.self, forKey: .effort)
        self.permMode = try c.decodeIfPresent(String.self, forKey: .permMode)
        self.permissionProfile = try c.decodeIfPresent(String.self, forKey: .permissionProfile)
        self.projectAuth = try c.decodeIfPresent(ProjectAuth.self, forKey: .projectAuth)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.updatedAt = try c.decode(String.self, forKey: .updatedAt)
        self.archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Runtime enum rawValue stays "grok"; file-facing normalize is on load / ConfigResolver.
        try c.encode(backend.rawValue, forKey: .backend)
        try c.encodeIfPresent(backendSessionId, forKey: .backendSessionId)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(guildId, forKey: .guildId)
        try c.encodeIfPresent(ownerId, forKey: .ownerId)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(permMode, forKey: .permMode)
        try c.encodeIfPresent(permissionProfile, forKey: .permissionProfile)
        try c.encodeIfPresent(projectAuth, forKey: .projectAuth)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(archived, forKey: .archived)
    }

    private enum CodingKeys: String, CodingKey {
        case backend, backendSessionId, cwd, guildId, ownerId, model, effort, permMode
        case permissionProfile, projectAuth, createdAt, updatedAt, archived
    }

    /// Map a stored mode/backend string → `Backend` after `normalizeModeId`.
    public static func backend(fromMode mode: String) -> Backend {
        let n = normalizeModeId(mode)
        if n == "grok-build" { return .grok }
        if let b = Backend(rawValue: n) { return b }
        if let b = Backend(rawValue: mode) { return b }
        // Unknown id: fall back to claude (should not happen for known backends incl. custom).
        return .claude
    }
}

/// On-disk envelope. `version` gates ordered migrations; unknown keys are ignored on decode.
/// `autoUpdate` is optional so pre-W16-h files load without a version bump (default applied).
private struct StoreFile: Codable {
    var version: Int
    var channels: [String: PersistedSession]
    var autoUpdate: AutoUpdateMeta?
}

// MARK: - Ordered migrations (fromVersion → next). Port of state/store.ts migrate().

/// One migration step: upgrades FROM `fromVersion` and MUST set `version` higher.
/// v1→v2: stamp version 2 + default missing `archived` to false (keys stay bare channelId — Q3).
private func migrateStateStep(fromVersion: Int, raw: [String: Any]) throws -> [String: Any] {
    switch fromVersion {
    case 1:
        var next = raw
        next["version"] = 2
        if var channels = next["channels"] as? [String: [String: Any]] {
            for (k, var binding) in channels {
                if binding["archived"] == nil { binding["archived"] = false }
                channels[k] = binding
            }
            next["channels"] = channels
        }
        return next
    default:
        throw SessionStoreError.noMigration(from: fromVersion)
    }
}

private func migrateState(_ raw: [String: Any]) throws -> [String: Any] {
    var current = raw
    var version = (current["version"] as? Int) ?? STATE_VERSION
    while version < STATE_VERSION {
        current = try migrateStateStep(fromVersion: version, raw: current)
        let next = (current["version"] as? Int) ?? (version + 1)
        if next <= version {
            throw SessionStoreError.migrationDidNotAdvance(from: version)
        }
        version = next
    }
    return current
}

public enum SessionStoreError: Error, CustomStringConvertible, Sendable {
    case noMigration(from: Int)
    case migrationDidNotAdvance(from: Int)

    public var description: String {
        switch self {
        case .noMigration(let v): return "No migration registered from state version \(v)."
        case .migrationDidNotAdvance(let v): return "Migration from state version \(v) did not advance the version."
        }
    }
}

/// Atomic, 0600 JSON persistence of channel → session bindings. Every mutation re-reads the file,
/// merges the single key, and atomically replaces it (tmp+rename) so a concurrent writer's other
/// keys are never clobbered. Loads tolerate a missing/corrupt file (empty state, never throws) so a
/// bad file cannot brick startup.
public actor SessionStore {
    public static let shared = SessionStore()

    private let fileURL: URL
    private var channels: [String: PersistedSession] = [:]
    private var autoUpdate: AutoUpdateMeta = .empty

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    // internal (not private): LegacyStateImport needs this exact path to gate its one-time import.
    static func defaultFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if let home = env["DAB_HOME"], !home.isEmpty {
            dir = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".discord-agent-bridge", isDirectory: true)
        }
        return dir.appendingPathComponent("swift-state.json", isDirectory: false)
    }

    // MARK: - Read

    /// Read + migrate + decode into memory. Missing or corrupt file → empty state (never throws).
    public func load() {
        let file = Self.readFile(fileURL)
        channels = file?.channels ?? [:]
        autoUpdate = file?.autoUpdate ?? .empty
    }

    public func binding(channelId: String) -> PersistedSession? { channels[channelId] }

    /// All bindings including archived (TS `ChannelRegistry.list` returns everything).
    public func all() -> [String: PersistedSession] { channels }

    /// Non-archived bindings only — resume / stopAll consumers.
    public func active() -> [String: PersistedSession] {
        channels.filter { !$0.value.archived }
    }

    // MARK: - Auto-update meta (TS stateStore.getUpdateMeta / setUpdateMeta)

    public func getUpdateMeta() -> AutoUpdateMeta { autoUpdate }

    /// Merge patch and persist. Channel bindings are re-read so concurrent writers survive.
    public func setUpdateMeta(_ patch: AutoUpdateMetaPatch) throws {
        let disk = Self.readFile(fileURL)
        let mergedChannels = disk?.channels ?? channels
        var meta = disk?.autoUpdate ?? autoUpdate
        if let t = patch.lastCheckAt { meta.lastCheckAt = t }
        if let d = patch.dismissedVersion { meta.dismissedVersion = d }
        try Self.writeFile(
            fileURL,
            StoreFile(version: STATE_VERSION, channels: mergedChannels, autoUpdate: meta)
        )
        channels = mergedChannels
        autoUpdate = meta
    }

    // MARK: - Write (load-merge-save, atomic, 0600)

    public func upsert(channelId: String, _ session: PersistedSession) throws {
        try mutate { map in
            var s = session
            if s.createdAt == nil {
                s.createdAt = map[channelId]?.createdAt ?? s.updatedAt
            }
            map[channelId] = s
        }
    }

    /// Hard-delete (TS `ChannelRegistry.remove` / orchestrator.stop). Explicit purge only.
    public func remove(channelId: String) throws {
        try mutate { $0[channelId] = nil }
    }

    /// Soft-delete: keep the binding but flag archived (resume-on-boot / stopAll skip it).
    /// Returns the updated binding, or nil if the channel is unknown.
    public func markArchived(channelId: String) throws -> PersistedSession? {
        var result: PersistedSession?
        try mutate { map in
            guard var existing = map[channelId] else { return }
            existing.archived = true
            existing.updatedAt = iso8601Now()
            map[channelId] = existing
            result = existing
        }
        return result
    }

    /// Re-read the file (so a concurrent writer's keys survive), apply `change`, write atomically.
    /// Preserves `autoUpdate` from disk (or in-memory default).
    private func mutate(_ change: (inout [String: PersistedSession]) -> Void) throws {
        let disk = Self.readFile(fileURL)
        var merged = disk?.channels ?? [:]
        change(&merged)
        let meta = disk?.autoUpdate ?? autoUpdate
        try Self.writeFile(fileURL, StoreFile(version: STATE_VERSION, channels: merged, autoUpdate: meta))
        channels = merged
        autoUpdate = meta
    }

    // MARK: - Disk

    private static func readFile(_ url: URL) -> StoreFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }  // missing → nil
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil  // corrupt → nil
        }
        do {
            let migrated = try migrateState(json)
            let mdata = try JSONSerialization.data(withJSONObject: migrated)
            return try JSONDecoder().decode(StoreFile.self, from: mdata)
        } catch {
            return nil
        }
    }

    private static func writeFile(_ url: URL, _ file: StoreFile) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        // Atomic replace: write a sibling tmp then rename over the target.
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        // replaceItemAt may not preserve perms on a fresh file — enforce 0600 on the final path.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
