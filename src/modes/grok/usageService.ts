import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { z } from 'zod';
import type { Logger } from '../../core/contracts.js';
import type { UsageResult, UsageSnapshot } from '../../core/usageService.js';

// Grok Build weekly-limit poller. Mirrors Claude UsageService's public contract
// (isAvailable / getUsage → UsageResult) and never-throw cache style, but talks to
// the Grok CLI billing endpoint and only fills sevenDay (no 5-hour / per-model windows).
//
// Auth: ~/.grok/auth.json is an object map of accounts; each value may carry a
// `key` (access token). We take the first entry with a non-empty key string.
// Tokens are NEVER logged. Full OIDC refresh is intentionally out of scope —
// expired keys are still attempted; 401 soft-fails to last cache / unavailable.

const BILLING_URL = 'https://cli-chat-proxy.grok.com/v1/billing?format=credits';

// ---------------------------------------------------------------------------
// Wire schemas (loose — tolerate missing/null product rows)
// ---------------------------------------------------------------------------

const productUsageSchema = z
  .object({
    product: z.string().optional(),
    usagePercent: z.number().nullable().optional(),
  })
  .passthrough();

const billingConfigSchema = z
  .object({
    creditUsagePercent: z.number().nullable().optional(),
    productUsage: z.array(productUsageSchema).nullable().optional(),
    currentPeriod: z
      .object({
        type: z.string().optional(),
        start: z.string().nullable().optional(),
        end: z.string().nullable().optional(),
      })
      .nullable()
      .optional(),
    billingPeriodEnd: z.string().nullable().optional(),
  })
  .passthrough();

const billingResponseSchema = z
  .object({
    config: billingConfigSchema.optional(),
  })
  .passthrough();

// auth.json is a map of account id → { key?, expires_at?, refresh_token?, ... }
const authAccountSchema = z
  .object({
    key: z.string().optional(),
    expires_at: z.union([z.string(), z.number()]).optional(),
  })
  .passthrough();

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

export interface GrokUsageServiceOptions {
  logger: Logger;
  // Minimum seconds between refetches. Default 15 (matches Claude UsageService).
  cacheSec?: number;
  fetchFn?: typeof fetch;
  // Path to Grok CLI auth file. Default ~/.grok/auth.json.
  authPath?: string;
  now?: () => number;
}

function defaultAuthPath(): string {
  return path.join(os.homedir(), '.grok', 'auth.json');
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

export class GrokUsageService {
  private readonly logger: Logger;
  private readonly cacheMs: number;
  private readonly fetchFn: typeof fetch;
  private readonly authPath: string;
  private readonly now: () => number;

  private cached: UsageSnapshot | null = null;

  constructor(options: GrokUsageServiceOptions) {
    this.logger = options.logger;
    this.cacheMs = Math.max(0, (options.cacheSec ?? 15)) * 1000;
    this.fetchFn = options.fetchFn ?? fetch;
    this.authPath = options.authPath ?? defaultAuthPath();
    this.now = options.now ?? Date.now;
  }

  // True when at least one account entry has a non-empty key string.
  isAvailable(): boolean {
    return this.readAccessToken() !== null;
  }

  // Serve the cache within TTL; otherwise fetch. NEVER throws — on any failure the
  // last-good snapshot (if any) is returned, else an unavailable result.
  async getUsage(): Promise<UsageResult> {
    const token = this.readAccessToken();
    if (!token) {
      return { available: false, reason: 'no-credentials' };
    }

    const nowMs = this.now();
    if (this.cached && nowMs - this.cached.fetchedAt < this.cacheMs) {
      return this.cached;
    }

    const snapshot = await this.fetchUsage(token);
    if (snapshot) return snapshot;

    if (this.cached) return this.cached;
    return { available: false, reason: 'no-credentials' };
  }

  // ---- Auth ---------------------------------------------------------------

  // First account entry with a non-empty `key`. Never logs the token. Missing /
  // unreadable / malformed file → null (not an error for API-key-less installs).
  private readAccessToken(): string | null {
    let raw: string;
    try {
      raw = fs.readFileSync(this.authPath, 'utf-8');
    } catch {
      return null;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      this.logger.warn('grok auth is not valid JSON; treating as unavailable');
      return null;
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      this.logger.warn('grok auth has an unexpected shape; treating as unavailable');
      return null;
    }
    for (const value of Object.values(parsed as Record<string, unknown>)) {
      const result = authAccountSchema.safeParse(value);
      if (!result.success) continue;
      const key = result.data.key;
      if (typeof key === 'string' && key.length > 0) return key;
    }
    return null;
  }

  // ---- Billing endpoint ---------------------------------------------------

  private async fetchUsage(token: string): Promise<UsageSnapshot | null> {
    let res: Response;
    try {
      res = await this.fetchFn(BILLING_URL, {
        headers: {
          Authorization: `Bearer ${token}`,
          Accept: 'application/json',
          'x-grok-client-mode': 'cli',
        },
      });
    } catch (err) {
      this.logger.warn('grok usage fetch request failed', { error: String(err) });
      return null;
    }

    if (res.status === 401) {
      this.logger.warn('grok usage endpoint returned 401 (token expired or revoked)');
      return null;
    }

    if (!res.ok) {
      this.logger.warn('grok usage endpoint returned a non-OK status', { status: res.status });
      return null;
    }

    let body: unknown;
    try {
      body = await res.json();
    } catch (err) {
      this.logger.warn('grok usage endpoint returned invalid JSON', { error: String(err) });
      return null;
    }

    const parsed = billingResponseSchema.safeParse(body);
    if (!parsed.success) {
      this.logger.warn('grok usage endpoint response has an unexpected shape');
      return null;
    }

    const snapshot = this.toSnapshot(parsed.data.config);
    if (!snapshot) {
      this.logger.warn('grok usage response missing a usable utilization percent');
      return null;
    }
    this.cached = snapshot;
    return snapshot;
  }

  // Prefer account-total creditUsagePercent (matches Grok UI weekly meter). Fall back to
  // GrokBuild productUsage% when the total is absent. Only sevenDay is set (no 5-hour window).
  private toSnapshot(config: z.infer<typeof billingConfigSchema> | undefined): UsageSnapshot | null {
    if (!config) return null;

    let utilization: number | undefined;
    if (config.creditUsagePercent != null && Number.isFinite(config.creditUsagePercent)) {
      utilization = config.creditUsagePercent;
    } else {
      const products = config.productUsage ?? [];
      const grokBuild = products.find((p) => p.product === 'GrokBuild');
      if (grokBuild?.usagePercent != null && Number.isFinite(grokBuild.usagePercent)) {
        utilization = grokBuild.usagePercent;
      }
    }
    if (utilization == null) return null;

    const resetsAt =
      (config.currentPeriod?.end && config.currentPeriod.end.length > 0
        ? config.currentPeriod.end
        : undefined) ??
      (config.billingPeriodEnd && config.billingPeriodEnd.length > 0
        ? config.billingPeriodEnd
        : undefined);

    const snapshot: UsageSnapshot = {
      fetchedAt: this.now(),
      sevenDay: {
        utilization,
        ...(resetsAt ? { resetsAt } : {}),
      },
    };
    return snapshot;
  }
}
