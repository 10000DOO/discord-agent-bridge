import { readFile as realReadFile, readdir as realReaddir } from 'node:fs/promises';
import * as path from 'node:path';
import type { Logger, ResumableSession } from '../../core/contracts.js';
import {
  CodexSqliteReader,
  type CodexThreadStateRow,
  type CodexThreadStates,
} from './sqliteReader.js';

// ~/.codex session discovery for the resume UX. Reads session_index.jsonl (fast
// path for id/name/updatedAt) and each rollout's first-line session_meta (for the
// cwd hint), then enriches/filters against thread state read via the bundled
// sqliteReader. Two safety rules govern the sqlite dependency (§5b, §7.3):
//   • Index-only FALLBACK: if the sqlite read throws (missing binary/file/parse
//     error) the thread-state map is empty → list from the index alone with NO
//     archived/sub-agent filtering, and log a visible warning.
//   • Fail-safe EXCLUDE: when thread state IS available but a session id has no
//     row in `threads`, exclude it (don't show an unknown-state session as
//     resumable).
// The on-disk rollout/index schema here is DIFFERENT from the exec `--json`
// stream — this does NOT reuse eventMapper.ts.

export interface ListResumableOptions {
  includeSubAgents?: boolean;
}

interface SessionIndexEntry {
  id: string;
  threadName: string;
  updatedAt: string;
}

// A narrow fs seam so discovery runs under test against a temp ~/.codex.
export interface DiscoveryFs {
  readFile(filePath: string): Promise<string>;
  readdir(dir: string): Promise<string[]>;
}

const realFs: DiscoveryFs = {
  readFile: (p) => realReadFile(p, 'utf8'),
  readdir: (dir) => realReaddir(dir),
};

export interface CodexDiscoveryOptions {
  reader?: CodexSqliteReader;
  fs?: DiscoveryFs;
  logger?: Logger;
}

// The rollout filename UUID is the last 36 chars before .jsonl.
const ROLLOUT_UUID = /-([0-9a-f-]{36})\.jsonl$/i;

// Any 36-char UUID embedded in an archived filename (its naming may differ from a
// live rollout, so match the UUID anywhere, not just before .jsonl).
const ANY_UUID = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;

export class CodexDiscovery {
  private readonly reader: CodexSqliteReader;
  private readonly fs: DiscoveryFs;
  private readonly logger?: Logger;

  constructor(options: CodexDiscoveryOptions = {}) {
    this.reader = options.reader ?? new CodexSqliteReader();
    this.fs = options.fs ?? realFs;
    if (options.logger) this.logger = options.logger;
  }

  async listResumable(
    codexHome: string,
    opts: ListResumableOptions = {},
  ): Promise<ResumableSession[]> {
    const entries = await this.readSessionIndex(codexHome);
    if (entries.length === 0) return [];

    const cwdById = await this.readRolloutCwds(codexHome);

    // Try to read thread state; a failure (missing/corrupt db) means we degrade
    // to index-only with no filtering (fallback rule).
    let states: CodexThreadStates | null = null;
    try {
      states = await this.reader.readThreadStates(codexHome);
    } catch (error) {
      this.logger?.warn(
        'Codex state db unreadable; falling back to session_index.jsonl (no archived/sub-agent filtering)',
        error,
      );
      states = null;
    }

    const stateAvailable = states !== null && states.rows.length > 0;
    const rowById = new Map<string, CodexThreadStateRow>();
    if (states) {
      for (const row of states.rows) rowById.set(row.id, row);
    }
    const subAgentChildIds = states?.subAgentChildIds ?? new Set<string>();

    // In the index-only fallback (sqlite unavailable → no `archived` column to
    // read), still exclude ids whose UUID appears under ~/.codex/archived_sessions/
    // so archived threads don't reappear when the db can't be read (P2-2 Q3).
    // Best-effort: a missing/unreadable dir yields an empty set (tolerate ENOENT).
    const archivedIds = stateAvailable ? new Set<string>() : await this.readArchivedIds(codexHome);

    const sessions: ResumableSession[] = [];
    for (const entry of entries) {
      const row = rowById.get(entry.id);

      if (stateAvailable) {
        // Fail-safe exclude: state is available but this session has no thread row.
        if (!row) continue;
        if (row.archived) continue;
        if (!opts.includeSubAgents && isSubAgent(entry.id, row, subAgentChildIds)) continue;
        // Non-interactive sources are not resumable user threads.
        if (row.source === 'exec') continue;
      } else if (archivedIds.has(entry.id)) {
        // Fallback path: the db is unreadable but the file layout still tells us
        // this thread was archived — keep it excluded.
        continue;
      }

      const cwd = row?.cwd ?? cwdById.get(entry.id) ?? '';
      const label = row?.title || row?.preview || entry.threadName || entry.id;
      const session: ResumableSession = { sessionId: entry.id, cwd };
      if (label) session.label = label;
      if (entry.updatedAt) session.updatedAt = entry.updatedAt;
      sessions.push(session);
    }

    sessions.sort((a, b) => (b.updatedAt ?? '').localeCompare(a.updatedAt ?? ''));
    return sessions;
  }

  private async readSessionIndex(codexHome: string): Promise<SessionIndexEntry[]> {
    const indexPath = path.join(codexHome, 'session_index.jsonl');
    let text: string;
    try {
      text = await this.fs.readFile(indexPath);
    } catch (error) {
      if (isEnoent(error)) return [];
      throw error;
    }

    const entries: SessionIndexEntry[] = [];
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      const entry = parseSessionIndexLine(line);
      if (entry) entries.push(entry);
    }
    return entries;
  }

  // Walk sessions/YYYY/MM/DD/rollout-*.jsonl; map each rollout UUID → its
  // session_meta.payload.cwd (read from the first line only).
  private async readRolloutCwds(codexHome: string): Promise<Map<string, string>> {
    const cwdById = new Map<string, string>();
    const files = await this.listRolloutFiles(path.join(codexHome, 'sessions'));
    await Promise.all(
      files.map(async (file) => {
        const match = ROLLOUT_UUID.exec(path.basename(file));
        if (!match) return;
        const cwd = await this.readSessionMetaCwd(file);
        if (cwd) cwdById.set(match[1], cwd);
      }),
    );
    return cwdById;
  }

  private async listRolloutFiles(root: string): Promise<string[]> {
    let names: string[];
    try {
      names = await this.fs.readdir(root);
    } catch (error) {
      if (isEnoent(error)) return [];
      throw error;
    }

    const nested = await Promise.all(
      names.map(async (name) => {
        const full = path.join(root, name);
        if (name.endsWith('.jsonl')) return [full];
        // Not a jsonl file → treat as a nested directory (YYYY/MM/DD); ENOENT and
        // ENOTDIR (a stray non-jsonl file) both collapse to no results.
        return this.listRolloutFiles(full).catch((error: unknown) =>
          isEnoent(error) || isNotDir(error) ? [] : Promise.reject(error),
        );
      }),
    );
    return nested.flat();
  }

  private async readSessionMetaCwd(file: string): Promise<string | undefined> {
    let text: string;
    try {
      text = await this.fs.readFile(file);
    } catch (error) {
      if (isEnoent(error)) return undefined;
      throw error;
    }
    const firstLine = text.split('\n', 1)[0];
    if (!firstLine) return undefined;
    return parseSessionMetaCwd(firstLine);
  }

  // Best-effort scan of ~/.codex/archived_sessions/ for the UUIDs of archived
  // threads (used only in the index-only fallback). Walks the tree the same way as
  // rollout files and collects every 36-char UUID found in a filename. A missing
  // dir (ENOENT) or any other read error yields an empty set — this must never
  // fail discovery, since it is only a fallback refinement.
  private async readArchivedIds(codexHome: string): Promise<Set<string>> {
    const ids = new Set<string>();
    let files: string[];
    try {
      files = await this.listRolloutFiles(path.join(codexHome, 'archived_sessions'));
    } catch {
      return ids;
    }
    for (const file of files) {
      const match = ANY_UUID.exec(path.basename(file));
      if (match) ids.add(match[1]);
    }
    return ids;
  }
}

// A session id is a sub-agent when its source is a {"subagent":…} blob OR it
// appears as a spawn edge's child_thread_id.
function isSubAgent(
  id: string,
  row: CodexThreadStateRow,
  subAgentChildIds: Set<string>,
): boolean {
  if (subAgentChildIds.has(id)) return true;
  return (row.source ?? '').trimStart().startsWith('{"subagent"');
}

function parseSessionIndexLine(line: string): SessionIndexEntry | null {
  try {
    const parsed = JSON.parse(line) as {
      id?: unknown;
      thread_name?: unknown;
      updated_at?: unknown;
    };
    if (typeof parsed.id !== 'string' || parsed.id.length === 0) return null;
    return {
      id: parsed.id,
      threadName: typeof parsed.thread_name === 'string' ? parsed.thread_name : '',
      updatedAt: typeof parsed.updated_at === 'string' ? parsed.updated_at : '',
    };
  } catch {
    return null;
  }
}

function parseSessionMetaCwd(line: string): string | undefined {
  try {
    const parsed = JSON.parse(line) as {
      type?: unknown;
      payload?: { cwd?: unknown };
    };
    if (parsed.type !== 'session_meta') return undefined;
    const cwd = parsed.payload?.cwd;
    return typeof cwd === 'string' && cwd.length > 0 ? cwd : undefined;
  } catch {
    return undefined;
  }
}

function isEnoent(error: unknown): error is NodeJS.ErrnoException {
  return hasCode(error, 'ENOENT');
}

function isNotDir(error: unknown): error is NodeJS.ErrnoException {
  return hasCode(error, 'ENOTDIR');
}

function hasCode(error: unknown, code: string): boolean {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: string }).code === code
  );
}
