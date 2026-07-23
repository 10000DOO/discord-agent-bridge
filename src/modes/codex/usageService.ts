import type { Logger } from '../../core/contracts.js';
import type { UsageProvider, UsageResult, UsageSnapshot, UsageLimit } from '../../core/usageService.js';
import { CodexAppServerClient } from './appServerClient.js';
import { resolveCodexHome } from './resolveHome.js';

// One-shot poller for Codex account rate limits via `codex app-server`
// `account/rateLimits/read` (measured: primary window often 10080 mins = weekly).

export type RateLimitsRequestFn = () => Promise<unknown>;

export interface CodexUsageServiceOptions {
  logger: Logger;
  cacheSec?: number;
  now?: () => number;
  // Injectable so tests avoid spawning a real codex process.
  requestRateLimits?: RateLimitsRequestFn;
  codexCommand?: string;
  codexHome?: string;
}

export class CodexUsageService implements UsageProvider {
  private readonly logger: Logger;
  private readonly cacheMs: number;
  private readonly now: () => number;
  private readonly requestRateLimits: RateLimitsRequestFn;

  private cached: UsageSnapshot | null = null;

  constructor(options: CodexUsageServiceOptions) {
    this.logger = options.logger;
    this.cacheMs = Math.max(0, (options.cacheSec ?? 15)) * 1000;
    this.now = options.now ?? Date.now;
    this.requestRateLimits =
      options.requestRateLimits ??
      (() => defaultRequestRateLimits(this.logger, options.codexCommand, options.codexHome));
  }

  isAvailable(): boolean {
    return true;
  }

  async getUsage(): Promise<UsageResult> {
    const nowMs = this.now();
    if (this.cached && nowMs - this.cached.fetchedAt < this.cacheMs) {
      return this.cached;
    }
    try {
      const raw = await this.requestRateLimits();
      const snap = toSnapshot(raw, this.now());
      if (snap) {
        this.cached = snap;
        return snap;
      }
    } catch (err) {
      this.logger.warn('codex rateLimits fetch failed', { error: String(err) });
    }
    if (this.cached) return this.cached;
    return { available: false, reason: 'no-credentials' };
  }
}

async function defaultRequestRateLimits(
  logger: Logger,
  codexCommand?: string,
  codexHome?: string,
): Promise<unknown> {
  // Expand ~ so CODEX_HOME is a real path (config often stores "~/.codex").
  const home = codexHome !== undefined ? resolveCodexHome(codexHome) : undefined;
  const client = new CodexAppServerClient({
    logger,
    ...(codexCommand !== undefined ? { codexCommand } : {}),
    ...(home !== undefined ? { codexHome: home } : {}),
  });
  try {
    await client.initialize();
    return await client.request('account/rateLimits/read', {});
  } finally {
    await client.close();
  }
}

function toSnapshot(raw: unknown, fetchedAt: number): UsageSnapshot | null {
  if (!raw || typeof raw !== 'object') return null;
  const root = raw as Record<string, unknown>;
  // Response may be { rateLimits: {...} } or the snapshot itself.
  const snap =
    root.rateLimits && typeof root.rateLimits === 'object'
      ? (root.rateLimits as Record<string, unknown>)
      : root;

  const primary = asWindow(snap.primary);
  const secondary = asWindow(snap.secondary);
  if (!primary && !secondary) return null;

  const out: UsageSnapshot = { fetchedAt };
  // Assign by window length: long windows → weekly, short → fiveHour.
  for (const w of [primary, secondary]) {
    if (!w) continue;
    const mins = w.windowDurationMins;
    const limit: UsageLimit = {
      utilization: w.usedPercent,
      ...(w.resetsAt != null ? { resetsAt: new Date(w.resetsAt * 1000).toISOString() } : {}),
    };
    if (mins != null && mins < 24 * 60) {
      if (!out.fiveHour) out.fiveHour = limit;
      else out.sevenDay = out.sevenDay ?? limit;
    } else {
      // Default / weekly (incl. 10080 mins)
      if (!out.sevenDay) out.sevenDay = limit;
      else out.fiveHour = out.fiveHour ?? limit;
    }
  }
  // If only one window and we put it somewhere, OK. If primary had no duration, treat as weekly.
  if (!out.sevenDay && !out.fiveHour && primary) {
    out.sevenDay = {
      utilization: primary.usedPercent,
      ...(primary.resetsAt != null
        ? { resetsAt: new Date(primary.resetsAt * 1000).toISOString() }
        : {}),
    };
  }
  if (!out.sevenDay && !out.fiveHour) return null;
  return out;
}

function asWindow(
  raw: unknown,
): { usedPercent: number; windowDurationMins?: number; resetsAt?: number } | null {
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.usedPercent !== 'number' || !Number.isFinite(o.usedPercent)) return null;
  return {
    usedPercent: o.usedPercent,
    ...(typeof o.windowDurationMins === 'number' ? { windowDurationMins: o.windowDurationMins } : {}),
    ...(typeof o.resetsAt === 'number' ? { resetsAt: o.resetsAt } : {}),
  };
}
