import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): per-tool threads — tool_use opens a thread; matching tool_result posts back.
// Cap: toolThreads (§6).
export function renderToolThread(_ev: Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>): void {
  throw new Error('not implemented');
}
