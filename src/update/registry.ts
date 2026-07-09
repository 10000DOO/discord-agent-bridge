import type { Logger } from '../core/contracts.js';

// npm registry probe for the latest published version (§7). Reads the package's
// `latest` dist-tag document. Mirrors usageService's HTTP-over-injected-fetch style
// (fetchFn injected, timeout via AbortController, NEVER throws): any failure — offline,
// timeout, non-OK status, malformed JSON — resolves to null so the caller silently skips.

const REGISTRY_URL = 'https://registry.npmjs.org/discord-agent-bridge/latest';
const DEFAULT_TIMEOUT_MS = 5000;

export interface FetchLatestOptions {
  timeoutMs?: number;
  userAgent?: string;
  logger?: Logger;
}

// Resolve the latest published version string, or null on ANY failure. fetchFn is
// injected so tests never touch the network; the real caller passes global fetch.
export async function fetchLatestVersion(
  fetchFn: typeof fetch,
  opts: FetchLatestOptions = {},
): Promise<string | null> {
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchFn(REGISTRY_URL, {
      signal: controller.signal,
      headers: {
        Accept: 'application/json',
        ...(opts.userAgent ? { 'User-Agent': opts.userAgent } : {}),
      },
    });
    if (!res.ok) {
      opts.logger?.warn('update check: registry returned a non-OK status', { status: res.status });
      return null;
    }
    let body: unknown;
    try {
      body = await res.json();
    } catch (err) {
      opts.logger?.warn('update check: registry returned invalid JSON', { error: String(err) });
      return null;
    }
    const version = (body as { version?: unknown } | null)?.version;
    if (typeof version !== 'string' || version.length === 0) {
      opts.logger?.warn('update check: registry response has no version field');
      return null;
    }
    return version;
  } catch (err) {
    // Offline, DNS failure, or the timeout abort — all silent skips (never-throws).
    opts.logger?.warn('update check: registry request failed', { error: String(err) });
    return null;
  } finally {
    clearTimeout(timer);
  }
}
