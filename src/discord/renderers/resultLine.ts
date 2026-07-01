import type { AgentEvent } from '../../core/contracts.js';
import { formatDuration, formatTokens } from '../format.js';
import { t } from '../i18n.js';

// Done-line (§6, §5c): a compact cost/tokens/duration line built from a `result`
// event. Cap-aware by construction — only fields actually present on the event are
// rendered (Codex, e.g., has no cost). Returns the line string (or null when the
// result carries no metric fields at all); 7b posts it to the channel.

export function buildResultLine(ev: Extract<AgentEvent, { kind: 'result' }>): string | null {
  const parts: string[] = [];
  if (ev.costUsd !== undefined) {
    parts.push(`${t('result.cost')} $${ev.costUsd.toFixed(4)}`);
  }
  const hasTokens = ev.tokensIn !== undefined || ev.tokensOut !== undefined;
  if (hasTokens) {
    const inTok = ev.tokensIn !== undefined ? `${formatTokens(ev.tokensIn)}↓` : '';
    const outTok = ev.tokensOut !== undefined ? `${formatTokens(ev.tokensOut)}↑` : '';
    parts.push(`${t('result.tokens')} ${[inTok, outTok].filter(Boolean).join(' ')}`.trim());
  }
  if (ev.durationMs !== undefined) {
    parts.push(`${t('result.duration')} ${formatDuration(ev.durationMs)}`);
  }
  if (parts.length === 0) return null;
  return `${t('result.done')} · ${parts.join(' · ')}`;
}
