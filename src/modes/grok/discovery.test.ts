import { describe, it, expect, beforeAll } from 'vitest';
import initSqlJs from 'sql.js';
import type { SqlJsStatic } from 'sql.js';
import { createRequire } from 'node:module';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import type { Logger } from '../../core/contracts.js';
import { GrokDiscovery } from './discovery.js';

const require = createRequire(import.meta.url);

let SQL: SqlJsStatic;

beforeAll(async () => {
  const wasmPath = require.resolve('sql.js/dist/sql-wasm.wasm');
  SQL = await initSqlJs({ locateFile: () => wasmPath });
});

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

// Build a session_search.sqlite matching the measured schema (updated_at = epoch seconds,
// title may be empty). Three sessions across two cwds.
function buildDbBytes(): Uint8Array {
  const db = new SQL.Database();
  db.run(
    `CREATE TABLE session_docs (
       session_id TEXT PRIMARY KEY,
       cwd TEXT NOT NULL,
       updated_at INTEGER NOT NULL,
       title TEXT NOT NULL,
       content TEXT NOT NULL,
       content_hash TEXT NOT NULL,
       last_indexed_offset INTEGER NOT NULL DEFAULT 0
     );`,
  );
  const insert = (id: string, cwd: string, updatedAt: number, title: string): void => {
    db.run(
      `INSERT INTO session_docs (session_id, cwd, updated_at, title, content, content_hash)
       VALUES ('${id}', '${cwd}', ${updatedAt}, '${title}', '', '');`,
    );
  };
  insert('sess-old', '/work/proj', 1783900000, 'Older session');
  insert('sess-new', '/work/proj', 1783908336, ''); // empty title → no label
  insert('sess-other', '/work/other', 1783908999, 'Other project');
  const bytes = db.export();
  db.close();
  return bytes;
}

// Same schema as buildDbBytes() but with caller-supplied rows, for the cwd-normalization cases
// that need specific stored cwds (trailing slash, symlink target).
function buildDbBytesFrom(rows: Array<{ id: string; cwd: string; updatedAt: number; title: string }>): Uint8Array {
  const db = new SQL.Database();
  db.run(
    `CREATE TABLE session_docs (
       session_id TEXT PRIMARY KEY,
       cwd TEXT NOT NULL,
       updated_at INTEGER NOT NULL,
       title TEXT NOT NULL,
       content TEXT NOT NULL,
       content_hash TEXT NOT NULL,
       last_indexed_offset INTEGER NOT NULL DEFAULT 0
     );`,
  );
  for (const row of rows) {
    db.run(
      `INSERT INTO session_docs (session_id, cwd, updated_at, title, content, content_hash)
       VALUES ('${row.id}', '${row.cwd}', ${row.updatedAt}, '${row.title}', '', '');`,
    );
  }
  const bytes = db.export();
  db.close();
  return bytes;
}

// Lay out a temp ~/.grok with sessions/session_search.sqlite (optionally corrupt / absent /
// caller-supplied bytes).
async function makeGrokHome(dir: string, opts: { writeDb?: boolean; corrupt?: boolean; dbBytes?: Uint8Array } = {}): Promise<void> {
  const sessions = path.join(dir, 'sessions');
  await mkdir(sessions, { recursive: true });
  if (opts.corrupt) {
    await writeFile(path.join(sessions, 'session_search.sqlite'), Buffer.from('not a database', 'utf8'));
  } else if (opts.dbBytes) {
    await writeFile(path.join(sessions, 'session_search.sqlite'), Buffer.from(opts.dbBytes));
  } else if (opts.writeDb) {
    await writeFile(path.join(sessions, 'session_search.sqlite'), Buffer.from(buildDbBytes()));
  }
}

async function withGrokHome<T>(
  opts: { writeDb?: boolean; corrupt?: boolean; dbBytes?: Uint8Array },
  fn: (dir: string) => Promise<T>,
): Promise<T> {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'dab-grokhome-'));
  try {
    await makeGrokHome(dir, opts);
    return await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

function makeDiscovery(logger?: Logger): GrokDiscovery {
  return new GrokDiscovery({ loadSql: async () => SQL, ...(logger ? { logger } : {}) });
}

describe('GrokDiscovery.listResumable', () => {
  it('lists all sessions newest-first when no cwd filter is given', async () => {
    await withGrokHome({ writeDb: true }, async (dir) => {
      const sessions = await makeDiscovery().listResumable(dir);
      expect(sessions.map((s) => s.sessionId)).toEqual(['sess-other', 'sess-new', 'sess-old']);
    });
  });

  it('filters to the given cwd and preserves recency order', async () => {
    await withGrokHome({ writeDb: true }, async (dir) => {
      const sessions = await makeDiscovery().listResumable(dir, '/work/proj');
      expect(sessions.map((s) => s.sessionId)).toEqual(['sess-new', 'sess-old']);
      expect(sessions.every((s) => s.cwd === '/work/proj')).toBe(true);
    });
  });

  it('maps title→label (empty title → no label) and updated_at→ISO string', async () => {
    await withGrokHome({ writeDb: true }, async (dir) => {
      const sessions = await makeDiscovery().listResumable(dir, '/work/proj');
      const byId = new Map(sessions.map((s) => [s.sessionId, s]));
      expect(byId.get('sess-old')?.label).toBe('Older session');
      expect(byId.get('sess-new')?.label).toBeUndefined(); // empty title
      // 1783908336s → ISO; relativeTime() downstream does Date.parse on this.
      expect(byId.get('sess-new')?.updatedAt).toBe(new Date(1783908336 * 1000).toISOString());
      expect(Number.isNaN(Date.parse(byId.get('sess-old')?.updatedAt ?? ''))).toBe(false);
    });
  });

  it('matches when the stored cwd has a trailing slash the query cwd lacks (normalization)', async () => {
    const bytes = buildDbBytesFrom([{ id: 'sess-slash', cwd: '/work/proj/', updatedAt: 1783908336, title: 'Slashed' }]);
    await withGrokHome({ dbBytes: bytes }, async (dir) => {
      const sessions = await makeDiscovery().listResumable(dir, '/work/proj');
      expect(sessions.map((s) => s.sessionId)).toEqual(['sess-slash']);
    });
  });

  it('matches when the query cwd has a trailing slash the stored cwd lacks (normalization)', async () => {
    const bytes = buildDbBytesFrom([{ id: 'sess-noslash', cwd: '/work/proj', updatedAt: 1783908336, title: 'NoSlash' }]);
    await withGrokHome({ dbBytes: bytes }, async (dir) => {
      const sessions = await makeDiscovery().listResumable(dir, '/work/proj/');
      expect(sessions.map((s) => s.sessionId)).toEqual(['sess-noslash']);
    });
  });

  // A stored cwd and a query cwd that point at the same directory through a symlink resolve to the
  // same realpath (the /Volumes↔/private case in the wild). Uses real temp dirs so realpathSync
  // exercises actual symlink resolution rather than the path.resolve fallback.
  it('matches across a symlinked cwd difference (realpath resolution)', async () => {
    const base = await mkdtemp(path.join(os.tmpdir(), 'dab-groklink-'));
    try {
      const realDir = path.join(base, 'realproj');
      const linkDir = path.join(base, 'linkproj');
      await mkdir(realDir, { recursive: true });
      await symlink(realDir, linkDir);
      const bytes = buildDbBytesFrom([{ id: 'sess-link', cwd: realDir, updatedAt: 1783908336, title: 'Linked' }]);
      await withGrokHome({ dbBytes: bytes }, async (dir) => {
        const sessions = await makeDiscovery().listResumable(dir, linkDir);
        expect(sessions.map((s) => s.sessionId)).toEqual(['sess-link']);
      });
    } finally {
      await rm(base, { recursive: true, force: true });
    }
  });

  it('still excludes a genuinely different cwd after normalization (regression)', async () => {
    await withGrokHome({ writeDb: true }, async (dir) => {
      expect(await makeDiscovery().listResumable(dir, '/work/nomatch')).toEqual([]);
    });
  });

  it('returns [] when the db file is absent (fail-safe)', async () => {
    await withGrokHome({}, async (dir) => {
      expect(await makeDiscovery().listResumable(dir)).toEqual([]);
    });
  });

  it('returns [] and warns when the db is corrupt (fail-safe, never throws)', async () => {
    await withGrokHome({ corrupt: true }, async (dir) => {
      const { logger, warnCalls } = makeLogger();
      const sessions = await makeDiscovery(logger).listResumable(dir);
      expect(sessions).toEqual([]);
      expect(warnCalls.length).toBeGreaterThan(0);
    });
  });
});
