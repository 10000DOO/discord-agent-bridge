import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): done-line — cost/tokens/duration, cap-aware (render only fields present) (§6, §5c).
export function renderResultLine(_ev: Extract<AgentEvent, { kind: 'result' }>): void {
  throw new Error('not implemented');
}
