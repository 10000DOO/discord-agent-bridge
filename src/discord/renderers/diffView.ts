import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): file-change diff view — auto diff thread on file edits.
// Cap: fileDiff (Claude only) (§6, §5a).
export function renderDiffView(_ev: Extract<AgentEvent, { kind: 'tool_result' }>): void {
  throw new Error('not implemented');
}
