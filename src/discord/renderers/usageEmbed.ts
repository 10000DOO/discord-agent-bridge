import type { AgentEvent } from '../../core/contracts.js';
import type { UsageSnapshot } from '../../core/usageService.js';

// TODO(Phase 1): cost/tokens/ctx/5h+weekly panel. Cap: usagePanel (Claude only; Codex skipped) (§6, §7.4).
export function renderUsageEmbed(_ctxUsage: Extract<AgentEvent, { kind: 'context_usage' }> | null, _usage: UsageSnapshot | null): void {
  throw new Error('not implemented');
}
