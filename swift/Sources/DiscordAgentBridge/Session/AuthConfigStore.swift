import Foundation

// Thin, auth-block-only reader of the global config.json (Q1=A / D2 — W13-a stopgap).
// W15-a folds this into a full ConfigStore WITHOUT changing Authorizer's signature.
// Fail-secure: a missing/corrupt file or absent fields → empty allowlists + dmPolicy=deny
// (never throws), mirroring src/core/config.ts fail-safe + configSchema.ts CONFIG_DEFAULTS.auth.
// DAB_HOME resolution reuses the SessionStore.defaultFileURL rule (file name → config.json).
//
// ponytail: reads the file on every load() (no mtime cache), matching TS configStore.load().
// Add a cache only if auth/audit call volume makes the re-read measurable.

/// The effective auth allowlists after reading the global config.json `auth` block.
public struct GlobalAuth: Sendable, Equatable {
    public var adminRoleIds: [String]
    public var executeRoleIds: [String]
    public var readOnlyRoleIds: [String]
    public var dmPolicy: String

    public init(adminRoleIds: [String] = [], executeRoleIds: [String] = [], readOnlyRoleIds: [String] = [], dmPolicy: String = "deny") {
        self.adminRoleIds = adminRoleIds
        self.executeRoleIds = executeRoleIds
        self.readOnlyRoleIds = readOnlyRoleIds
        self.dmPolicy = dmPolicy
    }

    /// Fail-secure default: empty allowlists (nobody authorized) + dmPolicy=deny.
    public static let empty = GlobalAuth()
}

/// Reads only the `auth` block of `<DAB_HOME>/config.json`. Serialized behind an actor so
/// a concurrent reader always sees a consistent file read.
public actor AuthConfigStore {
    public static let shared = AuthConfigStore()

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    // Mirrors SessionStore.defaultFileURL (SessionStore.swift) — same DAB_HOME rule,
    // file name config.json instead of swift-state.json.
    private static func defaultFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if let home = env["DAB_HOME"], !home.isEmpty {
            dir = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".discord-agent-bridge", isDirectory: true)
        }
        return dir.appendingPathComponent("config.json", isDirectory: false)
    }

    /// Read the `auth` block only. Missing file / corrupt JSON / absent fields → fail-secure
    /// empty (never throws). Every field is optional so a partial block still decodes.
    public func load() -> GlobalAuth {
        guard let data = try? Data(contentsOf: fileURL),                       // missing → empty
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data), // corrupt → empty
              let auth = file.auth else {                                        // no auth block → empty
            return .empty
        }
        return GlobalAuth(
            adminRoleIds: auth.adminRoleIds ?? [],
            executeRoleIds: auth.executeRoleIds ?? [],
            readOnlyRoleIds: auth.readOnlyRoleIds ?? [],
            dmPolicy: auth.dmPolicy ?? "deny"
        )
    }

    // Minimal decodable: only the auth block; unknown top-level keys are ignored on decode.
    private struct ConfigFile: Decodable {
        var auth: AuthBlock?
    }

    // All fields optional → a partial/absent field falls back to fail-secure empty.
    private struct AuthBlock: Decodable {
        var adminRoleIds: [String]?
        var executeRoleIds: [String]?
        var readOnlyRoleIds: [String]?
        var dmPolicy: String?
    }
}
