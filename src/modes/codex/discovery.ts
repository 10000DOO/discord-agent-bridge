import type { ResumableSession } from '../../core/contracts.js';

// TODO(Phase 1): ~/.codex session discovery — index (session_index.jsonl), meta (sessions/*.jsonl),
// thread state via bundled sqliteReader; index-only fail-safe fallback if the reader fails (C3, §5b, §7.3).
export class CodexDiscovery {
  listResumable(_codexHome: string): Promise<ResumableSession[]> {
    throw new Error('not implemented');
  }
}
