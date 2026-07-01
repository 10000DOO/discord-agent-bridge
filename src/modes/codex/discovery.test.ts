import { describe, it, expect, beforeAll } from 'vitest';
import initSqlJs from 'sql.js';
import type { SqlJsStatic } from 'sql.js';
import { createRequire } from 'node:module';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import type { Logger } from '../../core/contracts.js';
import { CodexSqliteReader } from './sqliteReader.js';
import { CodexDiscovery } from './discovery.js';

const require = createRequire(import.meta.url);

let SQL: SqlJsStatic;

beforeAll(async () => {
  const wasmPath = require.resolve('sql.js/dist/sql-wasm.wasm');
  SQL = await initSqlJs({ locateFile: () => wasmPath });
});

// A recording logger so the fallback test can assert a visible warning.
function makeLogger(): { logger: Logger; warnCalls: unknown[][] } {
  const warnCalls: unknown[][] = [];
  const logger: Logger = {
    debug: () => {},
    info: () => {},
    warn: (...meta: unknown[]) => warnCalls.push(meta),
    error: () => {},
  };
  return { logger, warnCalls };
}

// Session ids are real 36-char hex UUIDs so they match both the rollout
// filename regex and the on-disk session id (as codex actually stores them).
const ID = {
  user1: '11111111-1111-1111-1111-111111111111',
  user2: '22222222-2222-2222-2222-222222222222',
  archived: '33333333-3333-3333-3333-333333333333',
  sub: '44444444-4444-4444-4444-444444444444',
  exec: '55555555-5555-5555-5555-555555555555',
} as const;

function buildStateBytes(): Uint8Array {
  const db = new SQL.Database();
  db.run(
    `CREATE TABLE threads (
       id TEXT, cwd TEXT, title TEXT, preview TEXT,
       updated_at_ms INTEGER, archived INTEGER, source TEXT
     );
     CREATE TABLE thread_spawn_edges (child_thread_id TEXT);`,
  );
  db.run(
    `INSERT INTO threads (id, cwd, title, preview, updated_at_ms, archived, source)
     VALUES ('${ID.user1}', '/work/user-1', 'From SQLite', 'preview', 3000, 0, 'cli');`,
  );
  // A user thread with no title → label falls back to preview.
  db.run(
    `INSERT INTO threads (id, cwd, preview, updated_at_ms, archived, source)
     VALUES ('${ID.user2}', '/work/user-2', 'Preview label', 2500, 0, 'vscode');`,
  );
  db.run(
    `INSERT INTO threads (id, cwd, title, updated_at_ms, archived, source)
     VALUES ('${ID.archived}', '/work/arch', 'Archived', 2000, 1, 'cli');`,
  );
  db.run(
    `INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
     VALUES ('${ID.sub}', '/work/sub', 1900, 0, '{"subagent":{}}');`,
  );
  db.run(`INSERT INTO thread_spawn_edges (child_thread_id) VALUES ('${ID.sub}');`);
  db.run(
    `INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
     VALUES ('${ID.exec}', '/work/exec', 1800, 0, 'exec');`,
  );
  const bytes = db.export();
  db.close();
  return bytes;
}

function indexLine(id: string, threadName: string, updatedAt: string): string {
  return JSON.stringify({ id, thread_name: threadName, updated_at: updatedAt });
}

function rolloutMeta(id: string, cwd: string): string {
  return JSON.stringify({ type: 'session_meta', payload: { id, cwd, cli_version: '0.142.4' } });
}

interface FixtureOptions {
  writeState?: boolean;
  corruptState?: boolean;
}

// Lay out a temp ~/.codex: session_index.jsonl, a few rollout files under
// sessions/2026/07/01, and (optionally) a state_2.sqlite fixture.
async function makeCodexHome(dir: string, opts: FixtureOptions = {}): Promise<void> {
  const lines = [
    indexLine(ID.user1, 'user-1 name', '2026-07-01T10:00:00Z'),
    indexLine(ID.user2, 'user-2 name', '2026-07-01T09:00:00Z'),
    indexLine(ID.archived, 'archived name', '2026-07-01T08:00:00Z'),
    indexLine(ID.sub, 'sub name', '2026-07-01T07:00:00Z'),
    indexLine(ID.exec, 'exec name', '2026-07-01T06:00:00Z'),
  ];
  await writeFile(path.join(dir, 'session_index.jsonl'), lines.join('\n') + '\n');

  const day = path.join(dir, 'sessions', '2026', '07', '01');
  await mkdir(day, { recursive: true });
  const rollout = (uuid: string, cwd: string): Promise<void> =>
    writeFile(
      path.join(day, `rollout-2026-07-01T10-00-00-${uuid}.jsonl`),
      rolloutMeta(uuid, cwd) + '\n' + JSON.stringify({ type: 'response_item' }) + '\n',
    );
  // Rollout files for the two user threads (cwd hint source in the fallback path).
  await rollout(ID.user1, '/rollout/user-1');
  await rollout(ID.user2, '/rollout/user-2');

  if (opts.corruptState) {
    await writeFile(path.join(dir, 'state_2.sqlite'), Buffer.from('corrupt', 'utf8'));
  } else if (opts.writeState) {
    await writeFile(path.join(dir, 'state_2.sqlite'), Buffer.from(buildStateBytes()));
  }
}

async function withCodexHome<T>(
  opts: FixtureOptions,
  fn: (dir: string) => Promise<T>,
): Promise<T> {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'dab-codexhome-'));
  try {
    await makeCodexHome(dir, opts);
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

function makeReader(): CodexSqliteReader {
  return new CodexSqliteReader({ loadSql: async () => SQL });
}

describe('CodexDiscovery.listResumable (state db present)', () => {
  it('lists only resumable user threads, sorted by recency', async () => {
    await withCodexHome({ writeState: true }, async (dir) => {
      const discovery = new CodexDiscovery({ reader: makeReader() });
      const sessions = await discovery.listResumable(dir);

      // archived (archived), sub (sub-agent), exec (exec source) excluded.
      expect(sessions.map((s) => s.sessionId)).toEqual([ID.user1, ID.user2]);
    });
  });

  it('labels from sqlite title, then preview; cwd comes from sqlite', async () => {
    await withCodexHome({ writeState: true }, async (dir) => {
      const discovery = new CodexDiscovery({ reader: makeReader() });
      const sessions = await discovery.listResumable(dir);
      const byId = new Map(sessions.map((s) => [s.sessionId, s]));

      expect(byId.get(ID.user1)).toMatchObject({
        label: 'From SQLite',
        cwd: '/work/user-1',
        updatedAt: '2026-07-01T10:00:00Z',
      });
      expect(byId.get(ID.user2)?.label).toBe('Preview label');
    });
  });

  it('includes sub-agents when includeSubAgents is set', async () => {
    await withCodexHome({ writeState: true }, async (dir) => {
      const discovery = new CodexDiscovery({ reader: makeReader() });
      const sessions = await discovery.listResumable(dir, { includeSubAgents: true });
      expect(sessions.map((s) => s.sessionId)).toContain(ID.sub);
      // archived + exec still excluded even with sub-agents included.
      expect(sessions.map((s) => s.sessionId)).not.toContain(ID.archived);
      expect(sessions.map((s) => s.sessionId)).not.toContain(ID.exec);
    });
  });
});

describe('CodexDiscovery.listResumable (fallback)', () => {
  it('falls back to the index (no filtering) and warns when the db is unreadable', async () => {
    await withCodexHome({ corruptState: true }, async (dir) => {
      const { logger, warnCalls } = makeLogger();
      const discovery = new CodexDiscovery({ reader: makeReader(), logger });
      const sessions = await discovery.listResumable(dir);

      // No thread state → everything from the index is listed, unfiltered.
      expect(sessions.map((s) => s.sessionId).sort()).toEqual(
        [ID.user1, ID.user2, ID.archived, ID.sub, ID.exec].sort(),
      );
      // cwd for rollout-backed sessions still populated from session_meta.
      const byId = new Map(sessions.map((s) => [s.sessionId, s]));
      expect(byId.get(ID.user1)?.cwd).toBe('/rollout/user-1');
      // Label falls back to the index thread_name (no sqlite title/preview).
      expect(byId.get(ID.user1)?.label).toBe('user-1 name');
      expect(warnCalls.length).toBeGreaterThan(0);
    });
  });

  it('falls back when no state db exists at all', async () => {
    await withCodexHome({}, async (dir) => {
      const { logger, warnCalls } = makeLogger();
      const discovery = new CodexDiscovery({ reader: makeReader(), logger });
      const sessions = await discovery.listResumable(dir);
      expect(sessions.length).toBe(5);
      expect(warnCalls.length).toBeGreaterThan(0);
    });
  });
});

describe('CodexDiscovery.listResumable (fail-safe exclude)', () => {
  it('excludes an index session that has no row in threads', async () => {
    await withCodexHome({ writeState: true }, async (dir) => {
      const ghost = '99999999-9999-9999-9999-999999999999';
      // Append an index entry with no corresponding threads row.
      await writeFile(
        path.join(dir, 'session_index.jsonl'),
        indexLine(ghost, 'ghost name', '2026-07-01T11:00:00Z') + '\n',
        { flag: 'a' },
      );
      const discovery = new CodexDiscovery({ reader: makeReader() });
      const sessions = await discovery.listResumable(dir);
      expect(sessions.map((s) => s.sessionId)).not.toContain(ghost);
      expect(sessions.map((s) => s.sessionId)).toEqual([ID.user1, ID.user2]);
    });
  });
});

describe('CodexDiscovery.listResumable (edges)', () => {
  it('returns an empty list when there is no session_index.jsonl', async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), 'dab-empty-'));
    try {
      const discovery = new CodexDiscovery({ reader: makeReader() });
      expect(await discovery.listResumable(dir)).toEqual([]);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
