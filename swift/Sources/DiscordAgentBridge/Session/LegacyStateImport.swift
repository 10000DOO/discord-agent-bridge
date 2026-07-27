import Foundation

/// One-time TS→Swift legacy `state.json` importer (docs/legacy-state-migration.md). Runs once at
/// boot, right before `SessionStore.shared.load()`, and only when `swift-state.json` does not
/// exist yet on disk (R2) — never re-syncs, never overwrites an existing store. The legacy file
/// is opened read-only and is never written or deleted (R5) since the TS runtime may still be
/// relying on it. Any parse failure — whole file or a single channel — is swallowed and skipped,
/// never thrown (R3), so a bad/missing legacy file can never brick boot.
public enum LegacyStateImport {
    /// Import legacy channel bindings into `store` if `swiftFileURL` doesn't exist yet.
    /// Returns the number of channels imported (0 if skipped, or if nothing parsed).
    ///
    /// `nil` defaults resolve to the real DAB_HOME-based paths inside the function body — same
    /// nil-then-resolve DI shape as `SessionStore.init(fileURL:)` (SessionStore.swift:178-180),
    /// since a `public` function's parameter defaults can't call an internal static func directly
    /// (cross-module default-argument-value access rule).
    public static func runIfNeeded(
        legacyFileURL: URL? = nil,
        swiftFileURL: URL? = nil,
        store: SessionStore = .shared
    ) async -> Int {
        let legacyFileURL = legacyFileURL ?? defaultLegacyFileURL()
        let swiftFileURL = swiftFileURL ?? SessionStore.defaultFileURL()
        // R2: swift-state.json already present (any content) → never read/parse it, skip outright.
        guard !FileManager.default.fileExists(atPath: swiftFileURL.path) else { return 0 }
        // R5: read-only open of the legacy file; missing/unreadable → skip (no throw).
        guard let data = try? Data(contentsOf: legacyFileURL) else { return 0 }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        guard let channels = raw["channels"] as? [String: Any] else { return 0 }

        var imported = 0
        for (key, rawBinding) in channels {
            // A channel value that isn't a dictionary at all (string/array/null) must only skip
            // that one channel, not the whole file (R3).
            guard let binding = rawBinding as? [String: Any] else { continue }
            // TS composite key "<guildId>:<channelId>" (channelRegistry.ts splitKey). No colon →
            // unrecognized key format, skip just this entry.
            guard let colon = key.firstIndex(of: ":") else { continue }
            let guildIdPart = String(key[key.startIndex..<colon])
            let channelIdPart = String(key[key.index(after: colon)...])
            guard let session = parseSession(binding, guildIdFallback: guildIdPart) else { continue }
            do {
                try await store.upsert(channelId: channelIdPart, session)
                imported += 1
            } catch {
                continue
            }
        }
        return imported
    }

    /// Map one legacy channel binding dict to `PersistedSession`. `cwd`/`updatedAt`/an unmatched
    /// `mode` (H7) are the only fields whose absence/mismatch skips the whole channel (D5/WO-1) —
    /// everything else reads best-effort.
    private static func parseSession(_ binding: [String: Any], guildIdFallback: String) -> PersistedSession? {
        guard let cwd = binding["cwd"] as? String,
              let updatedAt = binding["updatedAt"] as? String
        else { return nil }

        let mode = (binding["mode"] as? String) ?? ""
        // Unknown backend value (H7): skip just this channel rather than silently mapping it to
        // `.claude`, which would run a corrupt/unregistered backend's session under the wrong
        // tools/permissions.
        guard let backend = PersistedSession.backend(fromMode: mode) else { return nil }
        let guildId = (binding["guildId"] as? String) ?? guildIdFallback

        var projectAuth: ProjectAuth?
        if let rawAuth = binding["projectAuth"] as? [String: Any],
           let authData = try? JSONSerialization.data(withJSONObject: rawAuth) {
            projectAuth = try? JSONDecoder().decode(ProjectAuth.self, from: authData)
        }

        return PersistedSession(
            backend: backend,
            backendSessionId: binding["sessionId"] as? String,
            cwd: cwd,
            guildId: guildId,
            ownerId: binding["ownerId"] as? String,
            model: binding["model"] as? String,
            effort: binding["effort"] as? String,
            permMode: binding["permissionMode"] as? String,
            permissionProfile: binding["permissionProfile"] as? String,
            projectAuth: projectAuth,
            createdAt: binding["createdAt"] as? String,
            updatedAt: updatedAt,
            archived: (binding["archived"] as? Bool) ?? false
        )
    }

    /// Same DAB_HOME resolution as `SessionStore.defaultFileURL()` (each store reimplements this
    /// independently — existing convention, see ConfigStore.swift/AuditLog.swift), but pointing at
    /// the TS-owned `state.json` instead of `swift-state.json`.
    static func defaultLegacyFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if let home = env["DAB_HOME"], !home.isEmpty {
            dir = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".discord-agent-bridge", isDirectory: true)
        }
        return dir.appendingPathComponent("state.json", isDirectory: false)
    }
}
