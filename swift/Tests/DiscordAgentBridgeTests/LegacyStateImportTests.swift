import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-legacy-import-swift-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("swift-state.json", isDirectory: false)
}

private func tempLegacyURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-legacy-import-legacy-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("state.json", isDirectory: false)
}

@Suite("LegacyStateImport")
struct LegacyStateImportTests {
    // Case 1 (R1, R4): fresh boot — legacy present, swift-state.json absent → full import,
    // field mapping (mode→backend, sessionId→backendSessionId, guildId fallback from key), and
    // version re-stamped to STATE_VERSION (legacy file's version is 1, deliberately different).
    @Test func importsLegacyChannelsOnFirstBoot() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: swiftURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacy: [String: Any] = [
            "version": 1,
            "channels": [
                "g1:c1": [
                    "mode": "claude", "sessionId": "sess-1", "cwd": "/ws1", "guildId": "g1",
                    "ownerId": "u1", "permissionMode": "default", "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-02T00:00:00Z", "archived": false,
                ] as [String: Any],
                "g1:c2": [
                    "mode": "codex", "sessionId": NSNull(), "cwd": "/ws2", "guildId": "g1",
                    "updatedAt": "2026-01-03T00:00:00Z", "archived": false,
                ] as [String: Any],
                // No "guildId" key in the binding at all → must fall back to the key's guildId part ("g2").
                "g2:c3": [
                    "mode": "grok", "sessionId": "sess-3", "cwd": "/ws3",
                    "updatedAt": "2026-01-04T00:00:00Z", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 3)

        await store.load()
        let active = await store.active()
        #expect(active.count == 3)
        #expect(active["c1"]?.backend == .claude)
        #expect(active["c1"]?.backendSessionId == "sess-1")
        #expect(active["c1"]?.cwd == "/ws1")
        #expect(active["c1"]?.guildId == "g1")
        #expect(active["c2"]?.backend == .codex)
        #expect(active["c2"]?.backendSessionId == nil)
        #expect(active["c3"]?.backend == .grok)
        #expect(active["c3"]?.guildId == "g2")   // fallback from key, not from binding body

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: swiftURL)) as! [String: Any]
        #expect(obj["version"] as? Int == STATE_VERSION)   // legacy had version 1 — must be re-stamped
    }

    // Case 2 (R2): swift-state.json already exists (even with zero channels) → never read/parse it,
    // never import, file left byte-for-byte and mtime untouched.
    @Test func skipsWhenSwiftStateAlreadyExists() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: swiftURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: swiftURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // A valid, importable legacy file — proves it's ignored purely because of the gate, not
        // because it happens to be unreadable.
        let legacy: [String: Any] = [
            "version": 1,
            "channels": [
                "g1:c1": [
                    "mode": "claude", "sessionId": "sess-1", "cwd": "/ws1", "guildId": "g1",
                    "updatedAt": "2026-01-02T00:00:00Z", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        let existing: [String: Any] = ["version": STATE_VERSION, "channels": [:] as [String: Any]]
        try JSONSerialization.data(withJSONObject: existing).write(to: swiftURL)
        let before = try Data(contentsOf: swiftURL)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: swiftURL.path)[.modificationDate] as? Date

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 0)

        let after = try Data(contentsOf: swiftURL)
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: swiftURL.path)[.modificationDate] as? Date
        #expect(after == before)
        #expect(mtimeAfter == mtimeBefore)
    }

    // Case 3a (R3): legacy state.json doesn't exist at all → skip, no crash.
    @Test func skipsWhenLegacyFileMissing() async {
        let legacyURL = tempLegacyURL()   // never written
        let swiftURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent()) }

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 0)
    }

    // Case 3b (R3): legacy state.json exists but isn't valid JSON → skip, no crash.
    @Test func skipsWhenLegacyFileCorrupt() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("}{ not json \u{00}".utf8).write(to: legacyURL)

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 0)
    }

    // Case 4 (R3): one of three channels is missing its required "cwd" field → that channel alone
    // is skipped, the other two still import.
    @Test func skipsOnlyBadChannelKeepsOthers() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: swiftURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacy: [String: Any] = [
            "version": 1,
            "channels": [
                "g1:c1": [
                    "mode": "claude", "cwd": "/ws1", "guildId": "g1", "updatedAt": "2026-01-01T00:00:00Z", "archived": false,
                ] as [String: Any],
                // Missing "cwd" entirely — must be skipped, not crash the whole import.
                "g1:c2": [
                    "mode": "codex", "guildId": "g1", "updatedAt": "2026-01-02T00:00:00Z", "archived": false,
                ] as [String: Any],
                "g1:c3": [
                    "mode": "grok", "cwd": "/ws3", "guildId": "g1", "updatedAt": "2026-01-03T00:00:00Z", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 2)

        await store.load()
        let active = await store.active()
        #expect(active["c1"] != nil)
        #expect(active["c2"] == nil)
        #expect(active["c3"] != nil)
    }

    // Case 7 (H7): one of three channels has an unregistered/unknown `mode` value — that channel
    // alone is skipped (never silently imported as claude), the other two still import.
    @Test func skipsUnknownBackendModeKeepsOthers() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: swiftURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacy: [String: Any] = [
            "version": 1,
            "channels": [
                "g1:c1": [
                    "mode": "claude", "cwd": "/ws1", "guildId": "g1", "updatedAt": "2026-01-01T00:00:00Z", "archived": false,
                ] as [String: Any],
                // Unregistered backend value — must be skipped, not silently imported as claude.
                "g1:c2": [
                    "mode": "future-backend", "cwd": "/ws2", "guildId": "g1", "updatedAt": "2026-01-02T00:00:00Z", "archived": false,
                ] as [String: Any],
                "g1:c3": [
                    "mode": "grok", "cwd": "/ws3", "guildId": "g1", "updatedAt": "2026-01-03T00:00:00Z", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 2)

        await store.load()
        let active = await store.active()
        #expect(active["c1"] != nil)
        #expect(active["c2"] == nil)
        #expect(active["c3"] != nil)
    }

    // Case 5 (R5): the legacy file is opened read-only — its bytes and mtime must be identical
    // before and after a successful import.
    @Test func leavesLegacyFileUntouchedAfterImport() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: swiftURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacy: [String: Any] = [
            "version": 1,
            "channels": [
                "g1:c1": [
                    "mode": "claude", "sessionId": "sess-1", "cwd": "/ws1", "guildId": "g1",
                    "updatedAt": "2026-01-02T00:00:00Z", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)
        let before = try Data(contentsOf: legacyURL)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 1)

        let after = try Data(contentsOf: legacyURL)
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date
        #expect(after == before)
        #expect(mtimeAfter == mtimeBefore)
    }

    // Case 6 (R3): one of three channels' *value* isn't a dictionary at all (String) — that channel
    // alone is skipped, the other two still import. Distinct from skipsOnlyBadChannelKeepsOthers,
    // which covers a dict channel missing a required field.
    @Test func skipsNonDictionaryChannelValueKeepsOthers() async throws {
        let legacyURL = tempLegacyURL()
        let swiftURL = tempStoreURL()
        defer {
            try? FileManager.default.removeItem(at: legacyURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: swiftURL.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacy: [String: Any] = [
            "version": 1,
            "channels": [
                "g1:c1": [
                    "mode": "claude", "cwd": "/ws1", "guildId": "g1", "updatedAt": "2026-01-01T00:00:00Z", "archived": false,
                ] as [String: Any],
                // Value isn't a dictionary at all — must be skipped, not crash/skip the whole file.
                "g1:c2": "not-a-dictionary",
                "g1:c3": [
                    "mode": "grok", "cwd": "/ws3", "guildId": "g1", "updatedAt": "2026-01-03T00:00:00Z", "archived": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: legacyURL)

        let store = SessionStore(fileURL: swiftURL)
        let imported = await LegacyStateImport.runIfNeeded(legacyFileURL: legacyURL, swiftFileURL: swiftURL, store: store)
        #expect(imported == 2)

        await store.load()
        let active = await store.active()
        #expect(active["c1"] != nil)
        #expect(active["c2"] == nil)
        #expect(active["c3"] != nil)
    }
}
