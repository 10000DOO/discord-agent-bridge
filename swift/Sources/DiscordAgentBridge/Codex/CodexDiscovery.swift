import Foundation

private let log = Logger(name: "codex-discovery")

// ~/.codex session discovery for the resume UX. 1:1 port of src/modes/codex/discovery.ts.
// Reads session_index.jsonl (fast path for id/name/updatedAt) and each rollout's first-line
// session_meta (for the cwd hint), then enriches/filters against thread state read via
// CodexSqliteReader. Two safety rules govern the sqlite dependency (TS §5b, §7.3):
//   • Index-only FALLBACK: if the sqlite read throws (missing binary/file/parse error) the
//     thread-state map is empty → list from the index alone with NO archived/sub-agent
//     filtering, and log a visible warning.
//   • Fail-safe EXCLUDE: when thread state IS available but a session id has no row in
//     `threads`, exclude it (don't show an unknown-state session as resumable).
// NOTE (matches TS codex/index.ts:67-69): does NOT filter by cwd — Codex's discovery.listResumable
// is called with `{}` opts and no cwd, so the resume list is process-wide across all of
// ~/.codex, not scoped to the folder currently browsed in the wizard.
public enum CodexDiscovery {
    public static func listResumable(codexHome: String, includeSubAgents: Bool = false) -> [ResumableSession] {
        let entries = readSessionIndex(codexHome)
        if entries.isEmpty { return [] }

        let cwdById = readRolloutCwds(codexHome)

        // Try to read thread state; a failure (missing/corrupt db) means we degrade to
        // index-only with no filtering (fallback rule).
        var states: CodexThreadStates?
        do {
            states = try CodexSqliteReader.readThreadStates(codexHome)
        } catch {
            log.warn(
                "Codex state db unreadable; falling back to session_index.jsonl "
                    + "(no archived/sub-agent filtering): \(error)"
            )
            states = nil
        }

        let stateAvailable = states.map { !$0.rows.isEmpty } ?? false
        var rowById: [String: CodexThreadStateRow] = [:]
        if let states {
            for row in states.rows { rowById[row.id] = row }
        }
        let subAgentChildIds = states?.subAgentChildIds ?? []

        // In the index-only fallback (sqlite unavailable → no `archived` column to read), still
        // exclude ids whose UUID appears under ~/.codex/archived_sessions/ so archived threads
        // don't reappear when the db can't be read.
        let archivedIds: Set<String> = stateAvailable ? [] : readArchivedIds(codexHome)

        var sessions: [ResumableSession] = []
        for entry in entries {
            let row = rowById[entry.id]

            if stateAvailable {
                // Fail-safe exclude: state is available but this session has no thread row.
                guard let row else { continue }
                if row.archived { continue }
                if !includeSubAgents, isSubAgent(id: entry.id, row: row, subAgentChildIds: subAgentChildIds) {
                    continue
                }
                // Non-interactive sources are not resumable user threads.
                if row.source == "exec" { continue }
            } else if archivedIds.contains(entry.id) {
                // Fallback path: the db is unreadable but the file layout still tells us this
                // thread was archived — keep it excluded.
                continue
            }

            let cwd = row?.cwd ?? cwdById[entry.id] ?? ""
            let label = nonEmpty(row?.title) ?? nonEmpty(row?.preview) ?? nonEmpty(entry.threadName) ?? entry.id
            var session = ResumableSession(sessionId: entry.id, cwd: cwd, label: label)
            if !entry.updatedAt.isEmpty { session.updatedAt = entry.updatedAt }
            sessions.append(session)
        }

        sessions.sort { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        return sessions
    }
}

// MARK: - session_index.jsonl

private struct SessionIndexEntry {
    let id: String
    let threadName: String
    let updatedAt: String
}

private struct RawIndexLine: Decodable {
    let id: String?
    let thread_name: String?
    let updated_at: String?
}

private func readSessionIndex(_ codexHome: String) -> [SessionIndexEntry] {
    let indexPath = (codexHome as NSString).appendingPathComponent("session_index.jsonl")
    guard let text = try? String(contentsOfFile: indexPath, encoding: .utf8) else { return [] }

    var entries: [SessionIndexEntry] = []
    for line in text.components(separatedBy: "\n") {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawIndexLine.self, from: data),
              let id = raw.id, !id.isEmpty
        else { continue }
        entries.append(SessionIndexEntry(id: id, threadName: raw.thread_name ?? "", updatedAt: raw.updated_at ?? ""))
    }
    return entries
}

// MARK: - Rollout cwd hints (sessions/YYYY/MM/DD/rollout-*.jsonl)

private struct RolloutMetaPayload: Decodable { let cwd: String? }
private struct RolloutMetaLine: Decodable {
    let type: String?
    let payload: RolloutMetaPayload?
}

private func readRolloutCwds(_ codexHome: String) -> [String: String] {
    // The rollout filename UUID is the last 36 chars before .jsonl.
    let rolloutUUID = #/-([0-9a-fA-F-]{36})\.jsonl$/#
    var cwdById: [String: String] = [:]
    let root = (codexHome as NSString).appendingPathComponent("sessions")
    for file in listJsonlFiles(under: root) {
        guard let match = (file as NSString).lastPathComponent.firstMatch(of: rolloutUUID) else { continue }
        guard let cwd = readSessionMetaCwd(file) else { continue }
        cwdById[String(match.1)] = cwd
    }
    return cwdById
}

private func readSessionMetaCwd(_ file: String) -> String? {
    guard let firstLine = firstLine(ofFile: file) else { return nil }
    guard let data = firstLine.data(using: .utf8),
          let raw = try? JSONDecoder().decode(RolloutMetaLine.self, from: data),
          raw.type == "session_meta",
          let cwd = raw.payload?.cwd, !cwd.isEmpty
    else { return nil }
    return cwd
}

// Best-effort scan of ~/.codex/archived_sessions/ for the UUIDs of archived threads (used only
// in the index-only fallback). A missing dir or any other read error yields an empty set — this
// must never fail discovery, since it is only a fallback refinement.
private func readArchivedIds(_ codexHome: String) -> Set<String> {
    // Any 36-char UUID embedded in an archived filename (its naming may differ from a live
    // rollout, so match the UUID anywhere, not just before .jsonl).
    let anyUUID = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#
    var ids: Set<String> = []
    let root = (codexHome as NSString).appendingPathComponent("archived_sessions")
    for file in listJsonlFiles(under: root) {
        let name = (file as NSString).lastPathComponent
        if let match = name.firstMatch(of: anyUUID) { ids.insert(String(match.0)) }
    }
    return ids
}

// Recursively list every .jsonl file under `root`. A missing/non-directory root yields [].
private func listJsonlFiles(under root: String) -> [String] {
    guard FileManager.default.fileExists(atPath: root) else { return [] }
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    var out: [String] = []
    for case let relPath as String in enumerator where relPath.hasSuffix(".jsonl") {
        out.append((root as NSString).appendingPathComponent(relPath))
    }
    return out
}

private func firstLine(ofFile path: String) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
}

// A session id is a sub-agent when its source is a {"subagent":…} blob OR it appears as a
// spawn edge's child_thread_id.
private func isSubAgent(id: String, row: CodexThreadStateRow, subAgentChildIds: Set<String>) -> Bool {
    if subAgentChildIds.contains(id) { return true }
    return (row.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\"subagent\"")
}

private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}
