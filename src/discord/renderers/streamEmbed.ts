import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): live text/thinking embeds, debounced edit then finalize to chunked text.
// Cap: streaming / thinking (§6). Handles AgentEvent kinds 'text' and 'thinking'.
export function renderStreamEmbed(_ev: Extract<AgentEvent, { kind: 'text' | 'thinking' }>): void {
  throw new Error('not implemented');
}
