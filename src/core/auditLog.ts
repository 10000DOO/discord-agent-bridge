import type { AuditEntry } from './contracts.js';

// TODO(Phase 1): append-only who/when/what → ~/.discord-agent-bridge/audit/*.jsonl,
// optionally mirrored to a configured Discord channel. See docs/DESIGN.md §7.5.
export class AuditLog {
  append(_entry: AuditEntry): void {
    throw new Error('not implemented');
  }
}
