import { describe, it, expect, beforeAll } from 'vitest';
import initSqlJs from 'sql.js';
import type { SqlJsStatic } from 'sql.js';
import { createRequire } from 'node:module';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import { CodexSqliteReader, CodexSqliteError } from './sqliteReader.js';

const require = createRequire(import.meta.url);

// Shared engine for both building fixtures and (injected) reading them back, so
// the suite never touches the real ~/.codex and never spawns a subprocess.
let SQL: SqlJsStatic;

beforeAll(async () => {
  const wasmPath = require.resolve('sql.js/dist/sql-wasm.wasm');
  SQL = await initSqlJs({ locateFile: () => wasmPath });
});

// Build a state_*.sqlite fixture with the columns discovery keys on, plus a
// spawn edge for the sub-agent thread. Returns the raw db bytes.
function buildFixtureBytes(): Uint8Array {
  const db = new SQL.Database();
  db.run(
    `CREATE TABLE threads (
       id TEXT, cwd TEXT, title TEXT, preview TEXT,
       updated_at_ms INTEGER, updated_at TEXT,
       archived INTEGER, sandbox_policy TEXT, approval_mode TEXT,
       source TEXT, thread_source TEXT
     );
     CREATE TABLE thread_spawn_edges (child_thread_id TEXT);`,
  );
  // A normal, resumable user thread.
  db.run(
    `INSERT INTO threads (id, cwd, title, preview, updated_at_ms, archived, source, thread_source)
     VALUES ('user-1', '/work/user', 'User Title', 'preview text', 2000, 0, 'cli', 'user');`,
  );
  // An archived thread.
  db.run(
    `INSERT INTO threads (id, cwd, title, updated_at_ms, archived, source)
     VALUES ('archived-1', '/work/archived', 'Archived', 1000, 1, 'cli');`,
  );
  // A sub-agent thread (source is a {"subagent":…} blob AND it is a spawn child).
  db.run(
    `INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
     VALUES ('sub-1', '/work/sub', 1500, 0, '{"subagent":{"parent":"user-1"}}');`,
  );
  db.run(`INSERT INTO thread_spawn_edges (child_thread_id) VALUES ('sub-1');`);
  // A non-interactive exec-source thread.
  db.run(
    `INSERT INTO threads (id, cwd, updated_at_ms, archived, source)
     VALUES ('exec-1', '/work/exec', 1800, 0, 'exec');`,
  );
  const bytes = db.export();
  db.close();
  return bytes;
}

async function withTempDir<T>(fn: (dir: string) => Promise<T>): Promise<T> {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'dab-sqlite-'));
  try {
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// A reader wired to the shared, already-initialized engine (no WASM reload).
function makeReader(): CodexSqliteReader {
  return new CodexSqliteReader({ loadSql: async () => SQL });
}

describe('CodexSqliteReader.readThreadStatesFromFile', () => {
  it('returns the thread rows and the sub-agent child id set', async () => {
    await withTempDir(async (dir) => {
      const dbPath = path.join(dir, 'state_1.sqlite');
      await writeFile(dbPath, Buffer.from(buildFixtureBytes()));

      const { rows, subAgentChildIds } = await makeReader().readThreadStatesFromFile(dbPath);

      const byId = new Map(rows.map((r) => [r.id, r]));
      expect([...byId.keys()].sort()).toEqual(['archived-1', 'exec-1', 'sub-1', 'user-1']);

      const user = byId.get('user-1')!;
      expect(user).toMatchObject({
        id: 'user-1',
        cwd: '/work/user',
        title: 'User Title',
        preview: 'preview text',
        updatedAtMs: 2000,
        archived: false,
        source: 'cli',
      });

      expect(byId.get('archived-1')!.archived).toBe(true);
      expect(byId.get('sub-1')!.source).toBe('{"subagent":{"parent":"user-1"}}');
      expect(byId.get('exec-1')!.source).toBe('exec');

      expect([...subAgentChildIds]).toEqual(['sub-1']);
    });
  });

  it('throws CodexSqliteError on a missing file', async () => {
    await withTempDir(async (dir) => {
      const missing = path.join(dir, 'state_9.sqlite');
      await expect(makeReader().readThreadStatesFromFile(missing)).rejects.toBeInstanceOf(
        CodexSqliteError,
      );
    });
  });

  it('throws CodexSqliteError on a corrupt db', async () => {
    await withTempDir(async (dir) => {
      const bad = path.join(dir, 'state_1.sqlite');
      await writeFile(bad, Buffer.from('not a sqlite database at all', 'utf8'));
      await expect(makeReader().readThreadStatesFromFile(bad)).rejects.toBeInstanceOf(
        CodexSqliteError,
      );
    });
  });
});

describe('CodexSqliteReader.findStateDatabase', () => {
  it('picks the highest state_<N>.sqlite and ignores other db families', async () => {
    await withTempDir(async (dir) => {
      const empty = Buffer.from(buildFixtureBytes());
      await Promise.all([
        writeFile(path.join(dir, 'state_1.sqlite'), empty),
        writeFile(path.join(dir, 'state_2.sqlite'), empty),
        writeFile(path.join(dir, 'state_10.sqlite'), empty),
        writeFile(path.join(dir, 'logs_99.sqlite'), empty),
        writeFile(path.join(dir, 'goals_5.sqlite'), empty),
        writeFile(path.join(dir, 'memories_7.sqlite'), empty),
      ]);

      const picked = await makeReader().findStateDatabase(dir);
      expect(picked).toBe(path.join(dir, 'state_10.sqlite'));
    });
  });

  it('returns null when no state db exists', async () => {
    await withTempDir(async (dir) => {
      expect(await makeReader().findStateDatabase(dir)).toBeNull();
    });
  });

  it('returns null when codexHome is absent (ENOENT)', async () => {
    const picked = await makeReader().findStateDatabase(
      path.join(os.tmpdir(), 'dab-does-not-exist-xyz'),
    );
    expect(picked).toBeNull();
  });
});

describe('CodexSqliteReader.readThreadStates', () => {
  it('resolves the highest state db under codexHome and reads it', async () => {
    await withTempDir(async (dir) => {
      const bytes = Buffer.from(buildFixtureBytes());
      await writeFile(path.join(dir, 'state_1.sqlite'), bytes);
      await writeFile(path.join(dir, 'state_3.sqlite'), bytes);

      const { rows } = await makeReader().readThreadStates(dir);
      expect(rows.map((r) => r.id).sort()).toEqual(['archived-1', 'exec-1', 'sub-1', 'user-1']);
    });
  });

  it('throws CodexSqliteError when no state db is present', async () => {
    await withTempDir(async (dir) => {
      await expect(makeReader().readThreadStates(dir)).rejects.toBeInstanceOf(CodexSqliteError);
    });
  });
});
