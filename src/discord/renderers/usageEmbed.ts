import * as path from 'node:path';
import type { AgentEvent, SessionPermMode } from '../../core/contracts.js';
import type { UsageResult, UsageLimit } from '../../core/usageService.js';
import type { EmbedSpec } from '../ports.js';
import { COLORS, formatTokens } from '../format.js';
import { t } from '../i18n.js';

// Usage/limits panel (§6, §7.4 — Claude, cap usagePanel): renders a UsageResult
// (5-hour + weekly + per-model) plus the context % from the latest context_usage
// event. When usage is unavailable (API-key-only user, or the Codex "unsupported"
// result), the panel renders NOTHING — buildUsageEmbed returns null so 7b simply
// posts no panel. Ports A4D buildUsageEmbed layout (progress bars + reset time).
//
// claude-hud-level extras (design_hud_usage_panel.md §5.5), all optional so the
// original panel is the degraded baseline:
//   description  display name · 📁 folder git:(branch) · ⏱️ session elapsed
//   context      … · "/clear saves ~N tokens" hint
//   fields       session composition (CLAUDE.md/MCP counts) · this turn's tools ·
//                subagent runs
//   footer       permission mode · resolved model id (absorbs the old 모델 field)

// Emoji squares read far better than █/░ on mobile; each cell is 10% of the gauge.
const BAR_LEN = 10;
const BAR_EMPTY = '⬜';

// Discord embed hard limit for one field value.
const FIELD_VALUE_MAX = 1024;
// Top-N tool names shown on the tools line (claude-hud toolsMaxVisible analog).
const TOOLS_MAX_VISIBLE = 4;
// Most recent subagent runs shown (claude-hud keeps the last 10; a Discord field
// is narrower, so keep the tail short).
const AGENTS_MAX_VISIBLE = 5;
// Per-run label budget so one long description cannot eat the whole field.
const AGENT_LABEL_MAX = 100;

// Session facts injected by the wiring's getSessionMeta provider (channel binding
// + a best-effort `git rev-parse --abbrev-ref HEAD`). Every member is optional:
// whatever is missing is simply not rendered.
export interface UsageSessionMeta {
  cwd?: string;
  gitBranch?: string;
  permMode?: SessionPermMode;
  createdAt?: string; // ISO — binding creation, shown as session elapsed time
}

// One tool name's turn-local aggregate: ×count with a ❌ marker when any of its
// results failed this turn.
export interface TurnToolStat {
  name: string;
  count: number;
  failed: number;
}

// One completed subagent run (subagent_result paired with its Task tool_use).
export interface SubagentRun {
  status: 'completed' | 'failed' | 'stopped';
  summary: string;
  type?: string; // input.subagent_type from the starting Task/Agent tool_use
  description?: string; // input.description from the starting Task/Agent tool_use
  durationMs?: number;
}

export interface UsageEmbedExtras {
  meta?: UsageSessionMeta | null;
  tools?: TurnToolStat[];
  agents?: SubagentRun[];
  // Explicit panel title from the mode (Claude / Grok / Codex). When set, wins
  // over the weekly-only Grok heuristic below.
  title?: string;
}

// Utilization thresholds → embed color (A4D utilizationColor).
function utilizationColor(maxUtil: number): number {
  if (maxUtil >= 90) return COLORS.stopped;
  if (maxUtil >= 70) return COLORS.streaming;
  return COLORS.idle;
}

// Per-gauge status dot. Thresholds are kept IN LOCKSTEP with utilizationColor
// (≥90 red, ≥70 yellow, else green) so a gauge's dot and the panel's left color
// bar always agree.
function utilizationEmoji(utilization: number): string {
  if (utilization >= 90) return '🔴';
  if (utilization >= 70) return '🟡';
  return '🟢';
}

// Progress-bar fill color. Thresholds are kept IN LOCKSTEP with utilizationColor
// and utilizationEmoji (≥90 red, ≥70 yellow, else green) so a gauge's bar, its
// status dot, and the panel's left color bar always agree.
function barFilledEmoji(utilization: number): string {
  if (utilization >= 90) return '🟥';
  if (utilization >= 70) return '🟨';
  return '🟩';
}

function progressBar(utilization: number): string {
  const clamped = Math.max(0, Math.min(100, utilization));
  const filled = Math.round((clamped / 100) * BAR_LEN);
  return barFilledEmoji(clamped).repeat(filled) + BAR_EMPTY.repeat(BAR_LEN - filled);
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
    name: `${utilizationEmoji(limit.utilization)} ${label}`,
    value: `${progressBar(limit.utilization)} **${Math.round(limit.utilization)}%**${resetLine(limit)}`,
    ...(inline ? { inline: true } : {}),
  };
}

// "5시간 16분"-style Korean elapsed time; null when the timestamp is absent/invalid.
function formatElapsed(createdAt: string | undefined, now: number): string | null {
  if (!createdAt) return null;
  const started = Date.parse(createdAt);
  if (Number.isNaN(started) || started > now) return null;
  const totalMin = Math.floor((now - started) / 60_000);
  if (totalMin < 60) return t('usage.elapsed.min', { m: totalMin });
  const totalHours = Math.floor(totalMin / 60);
  if (totalHours < 24) return t('usage.elapsed.hourMin', { h: totalHours, m: totalMin % 60 });
  return t('usage.elapsed.dayHour', { d: Math.floor(totalHours / 24), h: totalHours % 24 });
}

// "(12초)" / "(3분 12초)" duration suffix for a subagent run.
function formatRunDuration(ms: number): string {
  const totalSec = Math.max(0, Math.round(ms / 1000));
  if (totalSec < 60) return t('usage.duration.sec', { s: totalSec });
  return t('usage.duration.minSec', { m: Math.floor(totalSec / 60), s: totalSec % 60 });
}

// Header line: display name · 📁 folder git:(branch) · ⏱️ elapsed — only the
// segments that are actually known.
function buildDescription(
  ctxUsage: Extract<AgentEvent, { kind: 'context_usage' }> | null,
  meta: UsageSessionMeta | null,
  now: number,
): string | null {
  const segments: string[] = [];
  if (ctxUsage?.modelDisplayName) segments.push(ctxUsage.modelDisplayName);
  if (meta?.cwd) {
    const branch = meta.gitBranch ? ` git:(${meta.gitBranch})` : '';
    segments.push(`📁 ${path.basename(meta.cwd)}${branch}`);
  }
  const elapsed = formatElapsed(meta?.createdAt, now);
  if (elapsed) segments.push(`⏱️ ${elapsed}`);
  return segments.length > 0 ? segments.join(' · ') : null;
}

// "✅ Bash ×20 · ✅ Read ×3 · ❌ Edit ×1 · +N" — top names by count; ❌ marks a
// name with at least one failed result this turn.
function buildToolsValue(tools: TurnToolStat[]): string | null {
  const sorted = tools.filter((s) => s.count > 0).sort((a, b) => b.count - a.count);
  if (sorted.length === 0) return null;
  const shown = sorted.slice(0, TOOLS_MAX_VISIBLE).map((s) => `${s.failed > 0 ? '❌' : '✅'} ${s.name} ×${s.count}`);
  if (sorted.length > TOOLS_MAX_VISIBLE) shown.push(`+${sorted.length - TOOLS_MAX_VISIBLE}`);
  return shown.join(' · ');
}

// "✅ developer: Fix model list (12초)" lines for the most recent runs, capped to
// the Discord field-value limit.
function buildAgentsValue(agents: SubagentRun[]): string | null {
  if (agents.length === 0) return null;
  const lines = agents.slice(-AGENTS_MAX_VISIBLE).map((run) => {
    const icon = run.status === 'completed' ? '✅' : run.status === 'failed' ? '❌' : '⏹️';
    const text = run.type || run.description ? [run.type, run.description].filter(Boolean).join(': ') : run.summary;
    const clipped = text.length > AGENT_LABEL_MAX ? `${text.slice(0, AGENT_LABEL_MAX - 1)}…` : text;
    const duration = run.durationMs !== undefined ? ` (${formatRunDuration(run.durationMs)})` : '';
    return `${icon} ${clipped}${duration}`;
  });
  const value = lines.join('\n');
  return value.length > FIELD_VALUE_MAX ? `${value.slice(0, FIELD_VALUE_MAX - 1)}…` : value;
}

// Build the usage embed. Returns null when nothing should be shown (unavailable
// usage AND no context figure). `ctxUsage` is the latest context_usage event or
// null; `extras` carries the optional session meta + turn-local aggregates.
export function buildUsageEmbed(
  usage: UsageResult | null,
  ctxUsage: Extract<AgentEvent, { kind: 'context_usage' }> | null,
  extras?: UsageEmbedExtras,
): EmbedSpec | null {
  const haveUsage = usage !== null && 'fetchedAt' in usage;
  if (!haveUsage && !ctxUsage) return null;

  const meta = extras?.meta ?? null;
  const now = Date.now();
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
    const clearHint =
      ctxUsage.clearableTokens !== undefined && ctxUsage.clearableTokens > 0
        ? ` · ${t('usage.clearHint', { tokens: formatTokens(ctxUsage.clearableTokens) })}`
        : '';
    fields.push({
      name: `${utilizationEmoji(ctxUsage.percentage)} ${t('usage.context')}`,
      value: `${progressBar(ctxUsage.percentage)} **${Math.round(ctxUsage.percentage)}%**${clearHint}`,
    });
    maxUtil = Math.max(maxUtil, ctxUsage.percentage);

    // Session composition: loaded CLAUDE.md files + connected MCP servers. Both
    // ride the context_usage event, so they render inside this block only.
    const composition: string[] = [];
    if (ctxUsage.memoryFileCount !== undefined) composition.push(`CLAUDE.md ${ctxUsage.memoryFileCount}`);
    if (ctxUsage.mcpServerCount !== undefined) composition.push(`MCP ${ctxUsage.mcpServerCount}`);
    if (composition.length > 0) {
      fields.push({ name: `⚙️ ${t('usage.session')}`, value: composition.join(' · '), inline: true });
    }
  }

  const toolsValue = buildToolsValue(extras?.tools ?? []);
  if (toolsValue) fields.push({ name: `🛠️ ${t('usage.tools')}`, value: toolsValue, inline: true });

  const agentsValue = buildAgentsValue(extras?.agents ?? []);
  if (agentsValue) fields.push({ name: `🤖 ${t('usage.agents')}`, value: agentsValue });

  if (fields.length === 0) return null;

  // Footer absorbs the old standalone 모델 field: permission mode + resolved id.
  const footerParts: string[] = [];
  if (meta?.permMode) footerParts.push(t('usage.perm', { perm: t(`perm.${meta.permMode}`) }));
  if (ctxUsage?.model) footerParts.push(ctxUsage.model);

  // Prefer an explicit title from the caller (mode-aware wiring). Fallback: weekly-only
  // snapshot (sevenDay present, no fiveHour/opus/sonnet) → Grok title; else Claude.
  // Claude snapshots always carry fiveHour when available; weekly-only Claude is rare.
  const isGrokWeeklyOnly =
    haveUsage &&
    !!usage.sevenDay &&
    !usage.fiveHour &&
    !usage.sevenDayOpus &&
    !usage.sevenDaySonnet;
  const title =
    extras?.title ?? t(isGrokWeeklyOnly ? 'usage.title.grok' : 'usage.title');

  const description = buildDescription(ctxUsage, meta, now);
  return {
    title,
    color: utilizationColor(maxUtil),
    ...(description ? { description } : {}),
    fields,
    ...(footerParts.length > 0 ? { footer: footerParts.join(' · ') } : {}),
  };
}
