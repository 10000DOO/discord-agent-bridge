import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): translate each stdout JSON line → AgentEvent, validated & non-silent.
// Unrecognized type → progress{label:'working…'} PLUS counted logger.debug — never a silent drop (C2, §5b).
export function mapCodexEvent(_line: unknown): AgentEvent | null {
  throw new Error('not implemented');
}
