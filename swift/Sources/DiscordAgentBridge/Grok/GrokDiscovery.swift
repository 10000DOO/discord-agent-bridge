import Foundation

// ~/.grok session discovery for the resume UX. 1:1 port of src/modes/grok/discovery.ts.
// Far simpler than Codex/CodexDiscovery.swift: one table (session_docs), no archived/
// sub-agent state, no index-vs-sqlite fallback — any read failure (missing/corrupt db, bad
// schema) means "no resumable sessions", never a degraded partial list.
// NOTE (matches TS grok/agent/index.ts:76): unlike Codex's process-wide discovery, this DOES
// filter by cwd (the resume wizard's browsed folder), same as TS `listResumable(ctx)`.
public enum GrokDiscovery {
    private static let maxResults = 25

    /// List resumable sessions from `<grokHome>/sessions/session_search.sqlite`, newest first,
    /// optionally filtered to `cwd`. Any failure (missing db, corrupt db, bad schema) yields [].
    public static func listResumable(grokHome: String, cwd: String? = nil) -> [ResumableSession] {
        let dbPath = (grokHome as NSString).appendingPathComponent("sessions/session_search.sqlite")
        guard let rows = try? GrokSqliteReader.readSessionDocsFromFile(dbPath) else { return [] }

        // cwd normalization reuses Session/Confinement.swift's realpathOrResolve (already
        // public here). TS's own normalizeCwd (discovery.ts) wanted to reuse
        // sessionOrchestrator.ts's realpathOrResolve but couldn't because it's module-private
        // there — no such restriction in Swift, so no local copy is needed.
        let queryCwd: String? = (cwd?.isEmpty == false) ? cwd : nil
        let targetCwd = queryCwd.map(realpathOrResolve)

        var sessions: [ResumableSession] = []
        for row in rows {
            if let queryCwd, let targetCwd, row.cwd != queryCwd, realpathOrResolve(row.cwd) != targetCwd {
                continue
            }
            var session = ResumableSession(sessionId: row.sessionId, cwd: row.cwd, label: row.title)
            if let updatedAt = row.updatedAt { session.updatedAt = isoString(epochSeconds: updatedAt) }
            sessions.append(session)
            if sessions.count >= maxResults { break }
        }
        return sessions
    }
}

private func isoString(epochSeconds: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epochSeconds)))
}
