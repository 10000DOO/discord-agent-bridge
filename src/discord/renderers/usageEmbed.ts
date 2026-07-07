import type { AgentEvent } from '../../core/contracts.js';
import type { UsageResult, UsageLimit } from '../../core/usageService.js';
import type { EmbedSpec } from '../ports.js';
import { COLORS } from '../format.js';
import { t } from '../i18n.js';

// Usage/limits panel (§6, §7.4 — Claude, cap usagePanel): renders a UsageResult
// (5-hour + weekly + per-model) plus the context % from the latest context_usage
// event. When usage is unavailable (API-key-only user, or the Codex "unsupported"
// result), the panel renders NOTHING — buildUsageEmbed returns null so 7b simply
// posts no panel. Ports A4D buildUsageEmbed layout (progress bars + reset time).

const BAR_LEN = 20;
const BAR_FILLED = '▓';
const BAR_EMPTY = '░';

// Utilization thresholds → embed color (A4D utilizationColor).
function utilizationColor(maxUtil: number): number {
  if (maxUtil >= 90) return COLORS.stopped;
  if (maxUtil >= 70) return COLORS.streaming;
  return COLORS.idle;
}

function progressBar(utilization: number): string {
  const clamped = Math.max(0, Math.min(100, utilization));
  const filled = Math.round((clamped / 100) * BAR_LEN);
  return BAR_FILLED.repeat(filled) + BAR_EMPTY.repeat(BAR_LEN - filled);
}

// A "resets <t:unix:R>" Discord relative-timestamp line, or '' when no reset is known.
function resetLine(limit: UsageLimit): string {
  if (!limit.resetsAt) return '';
  const ms = Date.parse(limit.resetsAt);
  if (Number.isNaN(ms)) return '';
  return '\n' + t('usage.resets', { reset: `<t:${Math.floor(ms / 1000)}:R>` });
}

function limitField(label: string, limit: UsageLimit, inline?: boolean) {
  return {
    name: label,
    value: `${progressBar(limit.utilization)} **${Math.round(limit.utilization)}%**${resetLine(limit)}`,
    ...(inline ? { inline: true } : {}),
  };
}

// Build the usage embed. Returns null when nothing should be shown (unavailable
// usage AND no context figure). `ctxUsage` is the latest context_usage event or null.
export function buildUsageEmbed(
  usage: UsageResult | null,
  ctxUsage: Extract<AgentEvent, { kind: 'context_usage' }> | null,
): EmbedSpec | null {
  const haveUsage = usage !== null && 'fetchedAt' in usage;
  if (!haveUsage && !ctxUsage) return null;

  const fields: { name: string; value: string; inline?: boolean }[] = [];
  let maxUtil = 0;

  if (haveUsage) {
    const snap = usage;
    if (snap.fiveHour) {
      fields.push(limitField(t('usage.fiveHour'), snap.fiveHour));
      maxUtil = Math.max(maxUtil, snap.fiveHour.utilization);
    }
    if (snap.sevenDay) {
      fields.push(limitField(t('usage.weekly'), snap.sevenDay));
      maxUtil = Math.max(maxUtil, snap.sevenDay.utilization);
    }
    if (snap.sevenDayOpus) fields.push(limitField(t('usage.weeklyOpus'), snap.sevenDayOpus, true));
    if (snap.sevenDaySonnet) fields.push(limitField(t('usage.weeklySonnet'), snap.sevenDaySonnet, true));
  }

  if (ctxUsage) {
    fields.push({
      name: t('usage.context'),
      value: `${progressBar(ctxUsage.percentage)} **${Math.round(ctxUsage.percentage)}%**`,
    });
    maxUtil = Math.max(maxUtil, ctxUsage.percentage);
    // The running model only ever arrives WITH a context_usage event, so it renders
    // inside this block — model presence alone can never produce an embed.
    if (ctxUsage.model) {
      fields.push({ name: t('usage.model'), value: `\`${ctxUsage.model}\`` });
    }
  }

  if (fields.length === 0) return null;

  return {
    title: t('usage.title'),
    color: utilizationColor(maxUtil),
    fields,
  };
}
