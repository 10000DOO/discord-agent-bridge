import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { z } from 'zod';
import type { Logger } from './contracts.js';

// Claude usage/limits poller (§7.4). Polls the undocumented Anthropic OAuth usage
// endpoint for 5-hour + weekly limits. Grounded in A4D src/sessions/usageTracker.ts
// (endpoint, fields, auth, 429 backoff) and adapted to our injectable style +
// redacting logger. Framework-agnostic (no discord.js). Context usage is emitted
// separately by Claude mode as a `context_usage` AgentEvent — NOT handled here.
//
// Requires OAuth subscription login (~/.claude/.credentials.json), not an API key.
// API-key-only users degrade gracefully: the service reports unavailable and the
// Discord usage embed is simply hidden. This service NEVER throws into callers.
//
// Codex usage is UNSUPPORTED (Codex CLI exposes no limits) — see codexUsageUnavailable().

// ---------------------------------------------------------------------------
// Constants (copied verbatim from A4D usageTracker.ts, plus the UA hardening)
// ---------------------------------------------------------------------------

const OAUTH_TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const USAGE_API_URL = 'https://api.anthropic.com/api/oauth/usage';
const CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const OAUTH_BETA_HEADER = 'oauth-2025-04-20';

// Refresh a token that is expired or expiring within this window (A4D uses 5 min).
const REFRESH_SKEW_MS = 300_000;

// 429 backoff: double the effective cache TTL on each throttle, up to this cap.
const BACKOFF_MULTIPLIER = 2;
const MAX_BACKOFF_MS = 600_000; // 10 min

// ---------------------------------------------------------------------------
// Public snapshot shape (module-local; consumed by discord/renderers/usageEmbed.ts)
// ---------------------------------------------------------------------------

export interface UsageLimit {
  utilization: number; // 0-100
  resetsAt?: string;
}

export interface UsageSnapshot {
  fiveHour?: UsageLimit;
  sevenDay?: UsageLimit;
  sevenDayOpus?: UsageLimit;
  sevenDaySonnet?: UsageLimit;
  fetchedAt: number; // epoch ms when this snapshot was fetched
}

// Returned when subscription credentials are absent/unreadable (API-key-only users)
// or, for the Codex backend, when usage is structurally unsupported.
export interface UsageUnavailable {
  available: false;
  reason: 'no-credentials' | 'codex-unsupported';
}

export type UsageResult = UsageSnapshot | UsageUnavailable;

// ---------------------------------------------------------------------------
// Wire schemas (zod-validate the endpoint response; tolerate missing/null fields)
// ---------------------------------------------------------------------------

const rateLimitSchema = z
  .object({
    utilization: z.number().nullable().optional(),
    resets_at: z.string().nullable().optional(),
  })
  .nullable()
  .optional();

const usageResponseSchema = z.object({
  five_hour: rateLimitSchema,
  seven_day: rateLimitSchema,
  seven_day_opus: rateLimitSchema,
  seven_day_sonnet: rateLimitSchema,
  // extra_usage is tolerated but not surfaced in the snapshot (renderer concern).
  extra_usage: z.unknown().optional(),
});

const credentialsSchema = z.object({
  claudeAiOauth: z
    .object({
      accessToken: z.string().optional(),
      refreshToken: z.string().optional(),
      expiresAt: z.number().optional(),
    })
    .optional(),
});

const tokenResponseSchema = z.object({
  access_token: z.string(),
  refresh_token: z.string().optional(),
  expires_in: z.number().optional(),
});

interface OAuthCredentials {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

// ---------------------------------------------------------------------------
// Options (all deps injectable so tests never touch real network or ~/.claude)
// ---------------------------------------------------------------------------

export interface UsageServiceOptions {
  logger: Logger;
  // User-Agent version tag; the header is sent as `claude-code/<version>` to
  // reduce 429s on the undocumented endpoint. Defaults to 'unknown'.
  userAgentVersion?: string;
  // Minimum seconds between refetches (also the base for 429 backoff). Default 180.
  cacheSec?: number;
  // Injected fetch (default: global fetch). typeof globalThis.fetch.
  fetchFn?: typeof fetch;
  // Path to the Claude Code OAuth credentials file. Default ~/.claude/.credentials.json.
  credentialsPath?: string;
  // Injected clock (default: Date.now). Lets tests advance time deterministically.
  now?: () => number;
}

function defaultCredentialsPath(): string {
  return path.join(os.homedir(), '.claude', '.credentials.json');
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

export class UsageService {
  private readonly logger: Logger;
  private readonly userAgent: string;
  private readonly cacheMs: number;
  private readonly fetchFn: typeof fetch;
  private readonly credentialsPath: string;
  private readonly now: () => number;

  private cached: UsageSnapshot | null = null;
  private lastFetchAttemptAt = 0;
  // Effective min interval between fetches; grows on 429 backoff, resets on success.
  private currentIntervalMs: number;

  constructor(options: UsageServiceOptions) {
    this.logger = options.logger;
    this.userAgent = `claude-code/${options.userAgentVersion ?? 'unknown'}`;
    this.cacheMs = Math.max(0, (options.cacheSec ?? 180)) * 1000;
    this.fetchFn = options.fetchFn ?? fetch;
    this.credentialsPath = options.credentialsPath ?? defaultCredentialsPath();
    this.now = options.now ?? Date.now;
    this.currentIntervalMs = this.cacheMs;
  }

  // True when subscription OAuth credentials are present and readable. API-key-only
  // users (no credentials file) report false so the usage embed is hidden.
  isAvailable(): boolean {
    return this.readCredentials() !== null;
  }

  // Serve the cache within TTL; otherwise fetch. NEVER throws — on any failure the
  // last-good snapshot (if any) is returned, else an unavailable result.
  async getUsage(): Promise<UsageResult> {
    const creds = this.readCredentials();
    if (!creds) {
      return { available: false, reason: 'no-credentials' };
    }

    // Serve cache while within the effective interval (base TTL, or a backed-off one).
    const nowMs = this.now();
    if (this.cached && nowMs - this.cached.fetchedAt < this.currentIntervalMs) {
      return this.cached;
    }

    this.lastFetchAttemptAt = nowMs;
    const snapshot = await this.fetchUsage(creds);
    if (snapshot) return snapshot;

    // Fetch failed/backed-off: serve last-good if we have one.
    if (this.cached) return this.cached;
    return { available: false, reason: 'no-credentials' };
  }

  // ---- OAuth credentials -------------------------------------------------

  private readCredentials(): OAuthCredentials | null {
    let raw: string;
    try {
      raw = fs.readFileSync(this.credentialsPath, 'utf-8');
    } catch {
      // Absent/unreadable — API-key-only user. Not an error condition.
      return null;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      this.logger.warn('usage credentials file is not valid JSON; treating as unavailable');
      return null;
    }
    const result = credentialsSchema.safeParse(parsed);
    if (!result.success) {
      this.logger.warn('usage credentials file has an unexpected shape; treating as unavailable');
      return null;
    }
    const oauth = result.data.claudeAiOauth;
    if (!oauth?.accessToken || !oauth.refreshToken) return null;
    return {
      accessToken: oauth.accessToken,
      refreshToken: oauth.refreshToken,
      expiresAt: oauth.expiresAt ?? 0,
    };
  }

  private writeCredentials(creds: OAuthCredentials): void {
    try {
      let data: Record<string, unknown> = {};
      try {
        const existing = JSON.parse(fs.readFileSync(this.credentialsPath, 'utf-8'));
        if (existing && typeof existing === 'object' && !Array.isArray(existing)) {
          data = existing as Record<string, unknown>;
        }
      } catch {
        // Fresh/unreadable file — start from an empty object.
      }
      const prevOauth =
        data.claudeAiOauth && typeof data.claudeAiOauth === 'object'
          ? (data.claudeAiOauth as Record<string, unknown>)
          : {};
      data.claudeAiOauth = {
        ...prevOauth,
        accessToken: creds.accessToken,
        refreshToken: creds.refreshToken,
        expiresAt: creds.expiresAt,
      };
      fs.writeFileSync(this.credentialsPath, JSON.stringify(data), { encoding: 'utf-8', mode: 0o600 });
    } catch (err) {
      // Persisting the refreshed token is best-effort; a failure just means we
      // refresh again next cycle. Do not surface the token in the log.
      this.logger.warn('failed to persist refreshed usage credentials', { error: String(err) });
    }
  }

  private async refreshAccessToken(refreshToken: string): Promise<OAuthCredentials | null> {
    let res: Response;
    try {
      res = await this.fetchFn(OAUTH_TOKEN_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': this.userAgent,
        },
        body: JSON.stringify({
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
          client_id: CLIENT_ID,
        }),
      });
    } catch (err) {
      this.logger.warn('usage token refresh request failed', { error: String(err) });
      return null;
    }
    if (!res.ok) {
      this.logger.warn('usage token refresh returned a non-OK status', { status: res.status });
      return null;
    }
    let body: unknown;
    try {
      body = await res.json();
    } catch (err) {
      this.logger.warn('usage token refresh returned invalid JSON', { error: String(err) });
      return null;
    }
    const result = tokenResponseSchema.safeParse(body);
    if (!result.success) {
      this.logger.warn('usage token refresh response has an unexpected shape');
      return null;
    }
    const creds: OAuthCredentials = {
      accessToken: result.data.access_token,
      refreshToken: result.data.refresh_token ?? refreshToken,
      expiresAt: this.now() + (result.data.expires_in ?? 3600) * 1000,
    };
    this.writeCredentials(creds);
    return creds;
  }

  private async getValidToken(creds: OAuthCredentials): Promise<string | null> {
    if (creds.expiresAt < this.now() + REFRESH_SKEW_MS) {
      const refreshed = await this.refreshAccessToken(creds.refreshToken);
      if (!refreshed) return null;
      return refreshed.accessToken;
    }
    return creds.accessToken;
  }

  // ---- Usage endpoint ----------------------------------------------------

  private async fetchUsage(creds: OAuthCredentials): Promise<UsageSnapshot | null> {
    const token = await this.getValidToken(creds);
    if (!token) return null;

    let res: Response;
    try {
      res = await this.fetchFn(USAGE_API_URL, {
        headers: {
          Authorization: `Bearer ${token}`,
          'anthropic-beta': OAUTH_BETA_HEADER,
          'Content-Type': 'application/json',
          'User-Agent': this.userAgent,
        },
      });
    } catch (err) {
      this.logger.warn('usage fetch request failed', { error: String(err) });
      return null;
    }

    if (res.status === 429) {
      this.currentIntervalMs = Math.min(this.currentIntervalMs * BACKOFF_MULTIPLIER, MAX_BACKOFF_MS);
      this.logger.warn('usage endpoint rate-limited; backing off', {
        nextIntervalSec: Math.round(this.currentIntervalMs / 1000),
      });
      return null;
    }

    if (!res.ok) {
      this.logger.warn('usage endpoint returned a non-OK status', { status: res.status });
      return null;
    }

    let body: unknown;
    try {
      body = await res.json();
    } catch (err) {
      this.logger.warn('usage endpoint returned invalid JSON', { error: String(err) });
      return null;
    }
    const parsed = usageResponseSchema.safeParse(body);
    if (!parsed.success) {
      this.logger.warn('usage endpoint response has an unexpected shape');
      return null;
    }

    // Success — reset backoff.
    this.currentIntervalMs = this.cacheMs;
    const snapshot = this.toSnapshot(parsed.data);
    this.cached = snapshot;
    return snapshot;
  }

  private toSnapshot(data: z.infer<typeof usageResponseSchema>): UsageSnapshot {
    const snapshot: UsageSnapshot = { fetchedAt: this.now() };
    const fiveHour = toLimit(data.five_hour);
    if (fiveHour) snapshot.fiveHour = fiveHour;
    const sevenDay = toLimit(data.seven_day);
    if (sevenDay) snapshot.sevenDay = sevenDay;
    const opus = toLimit(data.seven_day_opus);
    if (opus) snapshot.sevenDayOpus = opus;
    const sonnet = toLimit(data.seven_day_sonnet);
    if (sonnet) snapshot.sevenDaySonnet = sonnet;
    return snapshot;
  }
}

// A rate-limit block maps to a UsageLimit only when utilization is present; a null
// utilization means "no data for this window" and is omitted from the snapshot.
function toLimit(
  raw: { utilization?: number | null; resets_at?: string | null } | null | undefined,
): UsageLimit | undefined {
  if (!raw || raw.utilization == null) return undefined;
  const limit: UsageLimit = { utilization: raw.utilization };
  if (raw.resets_at != null) limit.resetsAt = raw.resets_at;
  return limit;
}

// Codex usage is structurally unsupported (Codex CLI exposes no limits and no
// context maximum — §7.4). The Discord layer shows the "usage/limits unavailable
// (Codex CLI limitation)" status line instead of the usage embed.
export function codexUsageUnavailable(): UsageUnavailable {
  return { available: false, reason: 'codex-unsupported' };
}
