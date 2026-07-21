import * as fs from 'node:fs';
import { readFile as realReadFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import * as path from 'node:path';
import type { Database, SqlJsStatic } from 'sql.js';
import type { Logger, ResumableSession } from '../../core/contracts.js';

// ~/.grok session discovery for the resume UX (§8.3). Reads the index
// `<grokHome>/sessions/session_search.sqlite`, table `session_docs`, with the bundled sql.js
// (WASM) engine — the same read-only, byte-copy pattern as modes/codex/sqliteReader.ts. Far
// simpler than codex (no rollout files / session_index.jsonl): one table, filter by cwd,
// order by recency. Fail-safe: any missing file / load / query failure yields [] — the resume
// list is best-effort, never load-bearing. Every external touchpoint (sql.js loader,
// fs.readFile) is injectable so the reader runs under test against a fixture db.
//
// Measured schema (grok 0.2.99):
//   session_docs(session_id TEXT PK, cwd TEXT NOT NULL, updated_at INTEGER NOT NULL,
//                title TEXT NOT NULL, content TEXT, content_hash TEXT, last_indexed_offset INTEGER)
// updated_at is epoch SECONDS; title may be an empty string.

const MAX_RESULTS = 25;

// ---- Injectable seams -------------------------------------------------------
export type SqlLoader = () => Promise<SqlJsStatic>;
export type ReadFileFn = (filePath: string) => Promise<Buffer>;

export interface GrokDiscoveryOptions {
  loadSql?: SqlLoader;
  readFile?: ReadFileFn;
  logger?: Logger;
}

// Lazily initialize sql.js once and reuse the engine. locateFile resolves sql-wasm.wasm from
// the installed package via require.resolve so it works regardless of cwd (dev/test/dist).
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

export class GrokDiscovery {
  private readonly loadSql: SqlLoader;
  private readonly readFile: ReadFileFn;
  private readonly logger?: Logger;

  constructor(options: GrokDiscoveryOptions = {}) {
    this.loadSql = options.loadSql ?? defaultSqlLoader();
    this.readFile = options.readFile ?? ((p) => realReadFile(p));
    if (options.logger) this.logger = options.logger;
  }

  // List resumable sessions from session_search.sqlite, newest first, optionally filtered to a
  // cwd. Any failure (missing db, sql.js load, query) yields [].
  async listResumable(grokHome: string, cwd?: string): Promise<ResumableSession[]> {
    const dbPath = path.join(grokHome, 'sessions', 'session_search.sqlite');

    let bytes: Buffer;
    try {
      bytes = await this.readFile(dbPath);
    } catch (error) {
      this.logger?.debug('grok session db not readable; no resumable sessions', {
        dbPath,
        error: error instanceof Error ? error.message : String(error),
      });
      return [];
    }

    let SQL: SqlJsStatic;
    try {
      SQL = await this.loadSql();
    } catch (error) {
      this.logger?.warn('grok discovery: sql.js engine unavailable; no resumable sessions', error);
      return [];
    }

    let db: Database | undefined;
    try {
      db = new SQL.Database(bytes);
      return queryDocs(db, cwd);
    } catch (error) {
      this.logger?.warn('grok discovery: session_docs query failed; no resumable sessions', error);
      return [];
    } finally {
      db?.close();
    }
  }
}

// SELECT the columns we surface, newest first; filter by cwd in JS (a small personal table),
// then cap at MAX_RESULTS. An empty title yields no label (the picker shows the id).
function queryDocs(db: Database, cwd?: string): ResumableSession[] {
  const result = db.exec('SELECT session_id, cwd, updated_at, title FROM session_docs ORDER BY updated_at DESC');
  if (result.length === 0) return [];

  const { columns, values } = result[0];
  const iId = columns.indexOf('session_id');
  const iCwd = columns.indexOf('cwd');
  const iUpdated = columns.indexOf('updated_at');
  const iTitle = columns.indexOf('title');

  const targetCwd = cwd !== undefined && cwd.length > 0 ? normalizeCwd(cwd) : undefined;
  const filterCwd = targetCwd !== undefined;
  const sessions: ResumableSession[] = [];
  for (const value of values) {
    const sessionId = asString(value[iId]);
    if (!sessionId) continue;
    const rowCwd = asString(value[iCwd]) ?? '';
    // raw match is the common case — skip the realpathSync normalization unless needed
    if (filterCwd && rowCwd !== cwd && normalizeCwd(rowCwd) !== targetCwd) continue;

    const session: ResumableSession = { sessionId, cwd: rowCwd };
    const title = asString(value[iTitle]);
    if (title) session.label = title;
    const updatedAt = asNumber(value[iUpdated]);
    if (updatedAt !== undefined) session.updatedAt = new Date(updatedAt * 1000).toISOString();
    sessions.push(session);
    if (sessions.length >= MAX_RESULTS) break;
  }
  return sessions;
}

// Normalize a cwd before equality comparison so a session whose stored cwd differs from the
// bridge's cwd only by a trailing slash or a /Volumes↔/private symlink still matches: strip a
// trailing slash, then realpath to resolve symlinks. Mirrors sessionOrchestrator.ts
// realpathOrResolve (that helper is module-private there, so we keep a local copy rather than
// exporting a new core symbol). FAIL-SAFE — realpath throws for a path that no longer exists, so
// fall back to path.resolve (which still absolutizes and drops the trailing slash). Never throws:
// a normalization failure degrades to comparing the resolved values, never to dropping the list.
function normalizeCwd(cwd: string): string {
  const trimmed = cwd.replace(/(.)\/+$/, '$1');
  try {
    return fs.realpathSync(trimmed);
  } catch {
    return path.resolve(trimmed);
  }
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' ? value : undefined;
}
