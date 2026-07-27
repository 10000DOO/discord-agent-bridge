import Foundation

// Append-only who/when/what audit trail (mirror of `src/core/auditLog.ts`). Each
// `record` appends ONE JSON line to `audit/audit.jsonl` under the DAB home dir; the
// file is never rewritten, so history is tamper-evident by append. Secrets are scrubbed
// via `redactSecrets` before the line is written. Best-effort: a transient fs failure
// (mkdir/append) is logged to stderr but NEVER thrown — audit sits on the fire-and-forget
// turn pipeline, so a write failure must not stall the caller's turn. The file URL + clock
// are injectable (like `SessionStore`) so tests never touch the real home and timestamps
// are deterministic.

/// Append-only audit entry (mirror of `AuditEntry`, `src/core/contracts.ts:214-227`). The
/// caller supplies who/what; `AuditLog.record` stamps `when` (`timestamp`) at record time.
public struct AuditEntry: Codable, Sendable, Equatable {
    public var actorId: String
    public var roleTier: String          // "admin" | "execute" | "read-only" (caller-supplied)
    public var guildId: String
    public var channelId: String
    public var action: String            // command | tool | turn | drive | …
    public var command: String?          // raw command line, when action is a command
    public var tool: String?             // tool name, when action is a tool use
    public var mode: String?             // backend that handled it (claude | codex | …)
    public var permMode: String?
    public var cwd: String?
    public var outcome: String?          // free-form result note
    public var status: String?           // allowed | denied | ok | error
    /// Stamped by `AuditLog.record`; callers leave this nil.
    public var timestamp: String? = nil

    public init(
        actorId: String,
        roleTier: String,
        guildId: String,
        channelId: String,
        action: String,
        command: String? = nil,
        tool: String? = nil,
        mode: String? = nil,
        permMode: String? = nil,
        cwd: String? = nil,
        outcome: String? = nil,
        status: String? = nil
    ) {
        self.actorId = actorId
        self.roleTier = roleTier
        self.guildId = guildId
        self.channelId = channelId
        self.action = action
        self.command = command
        self.tool = tool
        self.mode = mode
        self.permMode = permMode
        self.cwd = cwd
        self.outcome = outcome
        self.status = status
    }
}

/// Scrub value-shape secrets (Discord/OAuth/xAI tokens, `Bearer <token>`) out of a plain
/// string. Swift port of `redactString` (`src/core/logger.ts:48`), applied to the serialized
/// audit line (design D5 — string-level scrub, not recursive key redaction). malformed-safe:
/// a bad pattern or any input is skipped/returned rather than throwing.
func redactSecrets(_ input: String) -> String {
    let placeholder = "[REDACTED]"
    // (pattern, options) mirrors logger.ts VALUE_PATTERNS: Discord bot token, sk-/sk-ant-
    // opaque tokens, xAI keys, and "Bearer <token>" (case-insensitive, lookbehind).
    let specs: [(String, NSRegularExpression.Options)] = [
        (#"\b[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6,7}\.[A-Za-z0-9_-]{27,40}\b"#, []),
        (#"\bsk-[A-Za-z0-9-]{16,}\b"#, []),
        (#"\bxai-[A-Za-z0-9_-]{16,}\b"#, []),
        (#"(?<=Bearer\s{1,4})[A-Za-z0-9._-]{8,}"#, [.caseInsensitive]),
    ]
    var out = input
    for (pattern, options) in specs {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }
        let range = NSRange(out.startIndex..., in: out)
        out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: placeholder)
    }
    return out
}

public actor AuditLog {
    public static let shared = AuditLog()

    private let fileURL: URL
    private let now: @Sendable () -> String

    public init(fileURL: URL? = nil, now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.now = now
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
        return dir.appendingPathComponent("audit", isDirectory: true)
            .appendingPathComponent("audit.jsonl", isDirectory: false)
    }

    /// Stamp the timestamp, serialize to one JSON line, scrub secrets, append. The dir is
    /// created if missing. Best-effort: any fs failure is logged to stderr but never thrown —
    /// a write failure must not stall the caller's turn (`auditLog.ts:65-76`).
    public func record(_ entry: AuditEntry) {
        var stamped = entry
        stamped.timestamp = now()
        do {
            let data = try JSONEncoder().encode(stamped)
            guard let line = String(data: data, encoding: .utf8) else { return }
            try append(Data((redactSecrets(line) + "\n").utf8))
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("[audit] failed to write \(fileURL.path): \(error)\n".utf8))
        }
    }

    /// Append one line, creating the `audit/` dir and the 0600 file on first write.
    private func append(_ data: Data) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
