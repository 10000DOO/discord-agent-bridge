import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): Codex progress/result feed — progress events become a compact live status line;
// final result.text posts as normal message(s). Cap: transcript / progress (§6, Codex UX).
export function renderTranscriptFeed(_ev: Extract<AgentEvent, { kind: 'progress' | 'result' }>): void {
  throw new Error('not implemented');
}
