import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import type { AuditEntry } from './contracts.js';
import { redact } from './logger.js';

// Append-only who/when/what audit trail (§7.5). Each record() appends ONE JSON
// line to audit/audit.jsonl under the DAB home dir; it never rewrites the file,
// so history is tamper-evident by append. Secrets are scrubbed via the chunk-1
// logger's redact() before the line is written.
//
// The base dir is injectable (same convention as ConfigStore/StateStore): explicit
// ctor arg > env DAB_HOME > ~/.discord-agent-bridge/, so tests never touch the real
// home. The clock is injectable so the `when` timestamp is deterministic in tests.
//
// Optional Discord channel sink: an injectable callback the later Discord chunk
// wires to a channel emitter (§7.5 "optionally mirrored"). discord.js is NOT
// imported here — core stays mode/transport-agnostic.
const DEFAULT_DIR_NAME = '.discord-agent-bridge';
const AUDIT_FILE_NAME = 'audit.jsonl';

function defaultBaseDir(): string {
  const fromEnv = process.env.DAB_HOME;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  return path.join(os.homedir(), DEFAULT_DIR_NAME);
}

// A recorded entry = the caller's AuditEntry plus the stamped ISO timestamp.
export type AuditRecord = AuditEntry & { timestamp: string };

// Sink for mirroring a record elsewhere (e.g. a Discord channel). Wired later.
export type AuditSink = (record: AuditRecord) => void;

export interface AuditLogOptions {
  baseDir?: string;
  now?: () => string;
  sink?: AuditSink;
}

export class AuditLog {
  private readonly baseDir: string;
  private readonly now: () => string;
  private readonly sink?: AuditSink;

  constructor(options: AuditLogOptions = {}) {
    this.baseDir = options.baseDir ?? defaultBaseDir();
    this.now = options.now ?? (() => new Date().toISOString());
    this.sink = options.sink;
  }

  get dir(): string {
    return path.join(this.baseDir, 'audit');
  }

  get filePath(): string {
    return path.join(this.dir, AUDIT_FILE_NAME);
  }

  // Stamp the timestamp, redact secrets, append one JSON line. The dir is created
  // if missing. Best-effort: a transient fs failure (mkdir/append) is logged
  // loudly but NEVER thrown to the caller — audit is on the fire-and-forget turn
  // pipeline (sessionOrchestrator drain), so a write failure must not stall a
  // channel's turn queue. The optional sink still runs and the record is still
  // returned even when the durable append failed.
  record(entry: AuditEntry): AuditRecord {
    const record: AuditRecord = { ...entry, timestamp: this.now() };
    const scrubbed = redact(record) as AuditRecord;
    try {
      this.ensureDir();
      fs.appendFileSync(this.filePath, JSON.stringify(scrubbed) + '\n', { encoding: 'utf-8' });
    } catch (err) {
      console.error(`[audit] failed to write ${this.filePath}: ${String(err)}`);
    }
    this.sink?.(scrubbed);
    return scrubbed;
  }

  private ensureDir(): void {
    if (!fs.existsSync(this.dir)) {
      fs.mkdirSync(this.dir, { recursive: true });
    }
  }
}
