import Foundation

// Backend (declared in SessionRegistry.swift) is a String raw enum; adopt Codable here (same module)
// via its rawValue so PersistedSession can synthesize Codable without editing that file.
extension Backend: Codable {}

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
    public var updatedAt: String

    public init(
        backend: Backend,
        backendSessionId: String? = nil,
        cwd: String,
        guildId: String,
        ownerId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permMode: String? = nil,
        updatedAt: String
    ) {
        self.backend = backend
        self.backendSessionId = backendSessionId
        self.cwd = cwd
        self.guildId = guildId
        self.ownerId = ownerId
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.updatedAt = updatedAt
    }
}

/// On-disk envelope. `version` gates future migrations; unknown keys are ignored on decode.
private struct StoreFile: Codable {
    var version: Int
    var channels: [String: PersistedSession]
}

/// Atomic, 0600 JSON persistence of channel → session bindings. Every mutation re-reads the file,
/// merges the single key, and atomically replaces it (tmp+rename) so a concurrent writer's other
/// keys are never clobbered. Loads tolerate a missing/corrupt file (empty state, never throws) so a
/// bad file cannot brick startup.
public actor SessionStore {
    public static let shared = SessionStore()

    private let fileURL: URL
    private var channels: [String: PersistedSession] = [:]

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
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

    /// Read + decode into memory. Missing or corrupt file → empty state (never throws).
    public func load() {
        channels = Self.readFile(fileURL)?.channels ?? [:]
    }

    public func binding(channelId: String) -> PersistedSession? { channels[channelId] }

    public func all() -> [String: PersistedSession] { channels }

    // MARK: - Write (load-merge-save, atomic, 0600)

    public func upsert(channelId: String, _ session: PersistedSession) throws {
        try mutate { $0[channelId] = session }
    }

    public func remove(channelId: String) throws {
        try mutate { $0[channelId] = nil }
    }

    /// Re-read the file (so a concurrent writer's keys survive), apply `change`, write atomically.
    private func mutate(_ change: (inout [String: PersistedSession]) -> Void) throws {
        var merged = Self.readFile(fileURL)?.channels ?? [:]
        change(&merged)
        try Self.writeFile(fileURL, StoreFile(version: 1, channels: merged))
        channels = merged
    }

    // MARK: - Disk

    private static func readFile(_ url: URL) -> StoreFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }        // missing → nil
        return try? JSONDecoder().decode(StoreFile.self, from: data)           // corrupt → nil
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
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
