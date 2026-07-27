import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempAuditURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-audit-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("audit", isDirectory: true)
        .appendingPathComponent("audit.jsonl", isDirectory: false)
}

// Grandparent (.../dab-audit-UUID) of the .../audit/audit.jsonl file — remove to clean up.
private func cleanupRoot(_ url: URL) -> URL {
    url.deletingLastPathComponent().deletingLastPathComponent()
}

private func sampleEntry(action: String = "turn", status: String = "ok", outcome: String? = nil) -> AuditEntry {
    AuditEntry(actorId: "u1", roleTier: "execute", guildId: "g1", channelId: "c1",
               action: action, mode: "claude", outcome: outcome, status: status)
}

private func lines(of url: URL) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

@Suite("AuditLog")
struct AuditLogTests {
    @Test func recordAppendsOneJsonLineWithStampedTimestamp() async throws {
        let url = tempAuditURL()
        defer { try? FileManager.default.removeItem(at: cleanupRoot(url)) }

        let log = AuditLog(fileURL: url, now: { "2026-07-25T00:00:00Z" })
        await log.record(sampleEntry())

        let ls = try lines(of: url)
        #expect(ls.count == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(ls[0].utf8)) as! [String: Any]
        #expect(obj["timestamp"] as? String == "2026-07-25T00:00:00Z")
        #expect(obj["actorId"] as? String == "u1")
        #expect(obj["roleTier"] as? String == "execute")
        #expect(obj["action"] as? String == "turn")
        #expect(obj["status"] as? String == "ok")
    }

    // Append, not overwrite: N records → N lines, history preserved in order.
    @Test func consecutiveRecordsAppendPreservingHistory() async throws {
        let url = tempAuditURL()
        defer { try? FileManager.default.removeItem(at: cleanupRoot(url)) }

        let log = AuditLog(fileURL: url, now: { "T" })
        await log.record(sampleEntry(action: "drive", status: "denied"))
        await log.record(sampleEntry(action: "turn", status: "ok"))
        await log.record(sampleEntry(action: "turn", status: "error"))

        let ls = try lines(of: url)
        #expect(ls.count == 3)
        let actions = try ls.map { (try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["action"] as? String }
        #expect(actions == ["drive", "turn", "turn"])
        let statuses = try ls.map { (try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any])["status"] as? String }
        #expect(statuses == ["denied", "ok", "error"])
    }

    @Test func fileIs0600() async throws {
        let url = tempAuditURL()
        defer { try? FileManager.default.removeItem(at: cleanupRoot(url)) }

        let log = AuditLog(fileURL: url, now: { "T" })
        await log.record(sampleEntry())

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    // Nil optionals are omitted (encodeIfPresent) — only set fields land in the line.
    @Test func omitsNilOptionalFields() async throws {
        let url = tempAuditURL()
        defer { try? FileManager.default.removeItem(at: cleanupRoot(url)) }

        let log = AuditLog(fileURL: url, now: { "T" })
        await log.record(sampleEntry())   // command/tool/permMode/cwd/outcome nil

        let obj = try JSONSerialization.jsonObject(with: Data(lines(of: url)[0].utf8)) as! [String: Any]
        #expect(obj["command"] == nil)
        #expect(obj["outcome"] == nil)
        #expect(obj["permMode"] == nil)
    }

    // --- redactSecrets: one assertion per token pattern from logger.ts VALUE_PATTERNS ---

    @Test func redactsDiscordBotToken() {
        let token = "ABCDEFGHIJKLMNOPQRSTUVWX.abcdef.ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
        #expect(redactSecrets(token) == "[REDACTED]")
        #expect(redactSecrets("bot token is \(token) ok").contains("[REDACTED]"))
    }

    @Test func redactsOpaqueSkTokens() {
        #expect(redactSecrets("sk-abcdefghijklmnop1234") == "[REDACTED]")
        #expect(redactSecrets("sk-ant-api03-abcdefghijklmnop") == "[REDACTED]")   // sk-ant- variant
    }

    @Test func redactsXaiKey() {
        #expect(redactSecrets("xai-abcdefghijklmnop1234") == "[REDACTED]")
    }

    @Test func redactsBearerToken() {
        #expect(redactSecrets("Authorization: Bearer abcdefgh12345") == "Authorization: Bearer [REDACTED]")
        #expect(redactSecrets("bearer abcdefgh12345") == "bearer [REDACTED]")     // case-insensitive
    }

    @Test func doesNotRedactBenignDottedString() {
        // File-hash-like strings have segments too short for the Discord pattern → untouched.
        #expect(redactSecrets("deadbeef.sig.0123456789") == "deadbeef.sig.0123456789")
    }

    // A secret that leaks into a free-form field is scrubbed on the serialized line.
    @Test func recordScrubsSecretInSerializedLine() async throws {
        let url = tempAuditURL()
        defer { try? FileManager.default.removeItem(at: cleanupRoot(url)) }

        let log = AuditLog(fileURL: url, now: { "T" })
        await log.record(sampleEntry(outcome: "leaked xai-abcdefghijklmnop1234 here"))

        let line = try lines(of: url)[0]
        #expect(line.contains("[REDACTED]"))
        #expect(!line.contains("xai-abcdefghijklmnop1234"))
        // Still valid JSON after redaction.
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect((obj["outcome"] as? String)?.contains("[REDACTED]") == true)
    }

    // Best-effort: an unwritable path (dir creation blocked by a file) must not throw/crash.
    @Test func recordIsBestEffortOnUnwritablePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blocker = root.appendingPathComponent("blocker", isDirectory: false)
        try Data("x".utf8).write(to: blocker)   // a regular file where a dir would need to be
        let url = blocker.appendingPathComponent("audit", isDirectory: true)
            .appendingPathComponent("audit.jsonl", isDirectory: false)

        let log = AuditLog(fileURL: url, now: { "T" })
        await log.record(sampleEntry())          // must return normally (no throw)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
