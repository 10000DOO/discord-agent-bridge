import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { AuditLog, type AuditRecord } from './auditLog.js';
import type { AuditEntry } from './contracts.js';

const FIXED_NOW = '2026-01-01T00:00:00.000Z';

function entry(overrides: Partial<AuditEntry> = {}): AuditEntry {
  return {
    actorId: 'u1',
    roleTier: 'execute',
    guildId: 'g1',
    channelId: 'c1',
    action: 'turn',
    ...overrides,
  };
}

describe('AuditLog', () => {
  let dir: string;

  function build(sink?: (r: AuditRecord) => void): AuditLog {
    return new AuditLog({ baseDir: dir, now: () => FIXED_NOW, sink });
  }

  function readLines(log: AuditLog): string[] {
    return fs
      .readFileSync(log.filePath, 'utf-8')
      .split('\n')
      .filter((l) => l.length > 0);
  }

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-audit-'));
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('creates the audit dir and appends one JSON line', () => {
    const log = build();
    expect(fs.existsSync(log.dir)).toBe(false); // dir not created until first record
    log.record(entry({ action: 'command', command: 'ls -la' }));
    expect(fs.existsSync(log.dir)).toBe(true);
    const lines = readLines(log);
    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]) as AuditRecord;
    expect(parsed.action).toBe('command');
    expect(parsed.command).toBe('ls -la');
  });

  it('stamps the injected clock as the deterministic timestamp', () => {
    const log = build();
    const rec = log.record(entry());
    expect(rec.timestamp).toBe(FIXED_NOW);
    const parsed = JSON.parse(readLines(log)[0]) as AuditRecord;
    expect(parsed.timestamp).toBe(FIXED_NOW);
  });

  it('appends (does not overwrite) across multiple records', () => {
    const log = build();
    log.record(entry({ action: 'turn' }));
    log.record(entry({ action: 'command', command: 'git status' }));
    log.record(entry({ action: 'tool', tool: 'Read' }));
    const lines = readLines(log);
    expect(lines).toHaveLength(3);
    expect((JSON.parse(lines[0]) as AuditRecord).action).toBe('turn');
    expect((JSON.parse(lines[1]) as AuditRecord).command).toBe('git status');
    expect((JSON.parse(lines[2]) as AuditRecord).tool).toBe('Read');
  });

  it('redacts secrets in the written line', () => {
    const log = build();
    // Synthetic Discord-token-SHAPE value (>=17 . >=5 . >=20 chars), assembled at
    // runtime so no realistic token literal lives in source.
    const fakeToken = ['X'.repeat(20), 'Y'.repeat(6), 'Z'.repeat(24)].join('.');
    log.record(entry({ action: 'command', command: `login ${fakeToken}` }));
    const raw = fs.readFileSync(log.filePath, 'utf-8');
    expect(raw).not.toContain(fakeToken);
    expect(raw).toContain('[REDACTED]');
    // Non-secret fields survive redaction.
    expect((JSON.parse(readLines(log)[0]) as AuditRecord).actorId).toBe('u1');
  });

  it('invokes the optional sink with the redacted record', () => {
    const seen: AuditRecord[] = [];
    const log = build((r) => seen.push(r));
    const fakeToken = ['A'.repeat(20), 'B'.repeat(6), 'C'.repeat(24)].join('.');
    log.record(entry({ action: 'command', command: `run ${fakeToken}` }));
    expect(seen).toHaveLength(1);
    expect(seen[0].timestamp).toBe(FIXED_NOW);
    expect(JSON.stringify(seen[0])).not.toContain(fakeToken);
    expect(JSON.stringify(seen[0])).toContain('[REDACTED]');
  });
});
