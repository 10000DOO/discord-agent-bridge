import { readFile as realReadFile, readdir as realReaddir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import * as path from 'node:path';
import type { Database, SqlJsStatic } from 'sql.js';

// Bundled sql.js (WASM) reader over ~/.codex/state_*.sqlite. Replaces CDC's
// external `sqlite3` CLI subprocess (resolves the C3 external-dependency issue,
// §7.3). Opens the db READ-ONLY (from a byte copy — sql.js never writes back to
// disk) and returns the thread-state rows plus the set of sub-agent child ids
// from thread_spawn_edges. Every external touchpoint — the SQL engine loader,
// fs.readFile, fs.readdir — is injectable so the reader runs under test against a
// fixture db with no real ~/.codex. On ANY open/read/parse failure it throws a
// typed CodexSqliteError; discovery.ts catches that to degrade to the index-only
// fallback (§5b, §7.3).

// ---- Public row shapes ------------------------------------------------------
export interface CodexThreadStateRow {
  id: string;
  cwd?: string;
  title?: string;
  preview?: string;
  updatedAtMs?: number;
  archived: boolean;
  source?: string;
}

export interface CodexThreadStates {
  // thread id → row (from the `threads` table)
  rows: CodexThreadStateRow[];
  // child_thread_id values from thread_spawn_edges: any id here is a sub-agent.
  subAgentChildIds: Set<string>;
}

// Typed failure so discovery can distinguish "reader failed → fall back to index"
// from a programming error. Carries the underlying cause for logging.
export class CodexSqliteError extends Error {
  constructor(
    message: string,
    readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'CodexSqliteError';
  }
}

// ---- Injectable seams -------------------------------------------------------
// The real sql.js loader (initSqlJs) resolves its WASM via locateFile. Tests can
// supply an already-initialized SqlJsStatic to skip WASM loading entirely.
export type SqlLoader = () => Promise<SqlJsStatic>;
export type ReadFileFn = (filePath: string) => Promise<Buffer>;
export type ReaddirFn = (dir: string) => Promise<string[]>;

export interface CodexSqliteReaderOptions {
  loadSql?: SqlLoader;
  readFile?: ReadFileFn;
  readdir?: ReaddirFn;
}

// Lazily initialize sql.js once and reuse the engine across reads. locateFile
// resolves sql-wasm.wasm from the installed sql.js package's dist directory via
// require.resolve so it works regardless of cwd (dev, test, packaged dist).
const require = createRequire(import.meta.url);

function defaultSqlLoader(): SqlLoader {
  let cached: Promise<SqlJsStatic> | undefined;
  return () => {
    if (!cached) {
      cached = (async () => {
        const initSqlJs = (await import('sql.js')).default;
        const wasmPath = require.resolve('sql.js/dist/sql-wasm.wasm');
        return initSqlJs({ locateFile: () => wasmPath });
      })();
    }
    return cached;
  };
}

export class CodexSqliteReader {
  private readonly loadSql: SqlLoader;
  private readonly readFile: ReadFileFn;
  private readonly readdir: ReaddirFn;

  constructor(options: CodexSqliteReaderOptions = {}) {
    this.loadSql = options.loadSql ?? defaultSqlLoader();
    this.readFile = options.readFile ?? ((p) => realReadFile(p));
    this.readdir = options.readdir ?? ((dir) => realReaddir(dir));
  }

  // Read thread states from a specific state_*.sqlite file.
  async readThreadStatesFromFile(dbPath: string): Promise<CodexThreadStates> {
    let bytes: Buffer;
    try {
      bytes = await this.readFile(dbPath);
    } catch (error) {
      throw new CodexSqliteError(`Failed to read Codex state db: ${dbPath}`, error);
    }

    let SQL: SqlJsStatic;
    try {
      SQL = await this.loadSql();
    } catch (error) {
      throw new CodexSqliteError('Failed to initialize sql.js engine', error);
    }

    let db: Database | undefined;
    try {
      db = new SQL.Database(bytes);
      const rows = queryThreadRows(db);
      const subAgentChildIds = querySubAgentChildIds(db);
      return { rows, subAgentChildIds };
    } catch (error) {
      throw new CodexSqliteError(`Failed to query Codex state db: ${dbPath}`, error);
    } finally {
      db?.close();
    }
  }

  // Resolve the highest state_<N>.sqlite in codexHome, then read it. Throws
  // CodexSqliteError when no state db exists so discovery falls back to the index.
  async readThreadStates(codexHome: string): Promise<CodexThreadStates> {
    const dbPath = await this.findStateDatabase(codexHome);
    if (!dbPath) {
      throw new CodexSqliteError(`No state_<N>.sqlite found in ${codexHome}`);
    }
    return this.readThreadStatesFromFile(dbPath);
  }

  // Pick the highest N among state_<N>.sqlite; ignores logs_*/goals_*/memories_*.
  async findStateDatabase(codexHome: string): Promise<string | null> {
    let names: string[];
    try {
      names = await this.readdir(codexHome);
    } catch (error) {
      if (isEnoent(error)) return null;
      throw new CodexSqliteError(`Failed to list ${codexHome}`, error);
    }

    let best: { version: number; name: string } | null = null;
    for (const name of names) {
      const match = /^state_(\d+)\.sqlite$/.exec(name);
      if (!match) continue;
      const version = Number.parseInt(match[1], 10);
      if (!best || version > best.version) best = { version, name };
    }

    return best ? path.join(codexHome, best.name) : null;
  }
}

// ---- SQL helpers ------------------------------------------------------------
// Read the `threads` rows we care about. Selects a superset of columns and reads
// each by name from the result so a schema that lacks an optional column (older
// codex) still yields the columns it does have rather than throwing.
function queryThreadRows(db: Database): CodexThreadStateRow[] {
  const result = db.exec(
    'SELECT id, cwd, title, preview, updated_at_ms, archived, source FROM threads',
  );
  if (result.length === 0) return [];

  const { columns, values } = result[0];
  const idx = (name: string): number => columns.indexOf(name);
  const iId = idx('id');
  const iCwd = idx('cwd');
  const iTitle = idx('title');
  const iPreview = idx('preview');
  const iUpdated = idx('updated_at_ms');
  const iArchived = idx('archived');
  const iSource = idx('source');

  const rows: CodexThreadStateRow[] = [];
  for (const value of values) {
    const id = asString(value[iId]);
    if (!id) continue;
    const row: CodexThreadStateRow = {
      id,
      archived: asNumber(value[iArchived]) === 1,
    };
    const cwd = asString(value[iCwd]);
    if (cwd !== undefined) row.cwd = cwd;
    const title = asString(value[iTitle]);
    if (title !== undefined) row.title = title;
    const preview = asString(value[iPreview]);
    if (preview !== undefined) row.preview = preview;
    const updatedAtMs = asNumber(value[iUpdated]);
    if (updatedAtMs !== undefined) row.updatedAtMs = updatedAtMs;
    const source = asString(value[iSource]);
    if (source !== undefined) row.source = source;
    rows.push(row);
  }
  return rows;
}

function querySubAgentChildIds(db: Database): Set<string> {
  const ids = new Set<string>();
  const result = db.exec('SELECT child_thread_id FROM thread_spawn_edges');
  if (result.length === 0) return ids;
  for (const value of result[0].values) {
    const childId = asString(value[0]);
    if (childId) ids.add(childId);
  }
  return ids;
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined;
}

function isEnoent(error: unknown): error is NodeJS.ErrnoException {
  return (
    typeof error === 'object' &&
    error !== null &&
    'code' in error &&
    (error as { code?: string }).code === 'ENOENT'
  );
}
