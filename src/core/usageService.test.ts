import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { UsageService, codexUsageUnavailable, type UsageSnapshot } from './usageService.js';
import { createLogger, type LogSink, type LogLevel } from './logger.js';

// ---------------------------------------------------------------------------
// Test helpers — all HTTP and FS are mocked; nothing touches real ~/.claude or
// the network. Secret-shaped fixtures are zero-entropy sentinels assembled here.
// ---------------------------------------------------------------------------

// Zero-entropy sentinel tokens (no realistic secret literals in source).
const ACCESS_TOKEN = 'A'.repeat(24);
const REFRESH_TOKEN = 'R'.repeat(24);
const NEW_ACCESS_TOKEN = 'B'.repeat(24);

function captureSink(): { lines: string[]; sink: LogSink } {
  const lines: string[] = [];
  return {
    lines,
    sink: {
      write(_level: LogLevel, line: string) {
        lines.push(line);
      },
    },
  };
}

// A fetch double that dispatches by URL and returns queued Response-likes.
function jsonResponse(status: number, body: unknown): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as unknown as Response;
}

const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';

// The mocks are typed via `typeof fetch` at the injection site, so their inferred
// call tuples vary; read them positionally through this untyped view.
function calls(fetchFn: { mock: { calls: unknown[] } }): unknown[][] {
  return fetchFn.mock.calls as unknown[][];
}

function usageBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    five_hour: { utilization: 42, resets_at: '2026-07-01T12:00:00Z' },
    seven_day: { utilization: 10, resets_at: '2026-07-07T00:00:00Z' },
    seven_day_opus: { utilization: 55, resets_at: null },
    seven_day_sonnet: { utilization: null, resets_at: null },
    ...overrides,
  };
}

describe('UsageService', () => {
  let dir: string;
  let credsPath: string;
  let clock: number;

  const now = () => clock;

  function writeCreds(expiresAt: number): void {
    fs.writeFileSync(
      credsPath,
      JSON.stringify({ claudeAiOauth: { accessToken: ACCESS_TOKEN, refreshToken: REFRESH_TOKEN, expiresAt } }),
      'utf-8',
    );
  }

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-usage-'));
    credsPath = path.join(dir, '.credentials.json');
    clock = 1_000_000; // fixed base epoch (ms)
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('parses a mocked usage response into a snapshot (5h / weekly / per-model)', async () => {
    writeCreds(clock + 3_600_000); // token valid for an hour
    const fetchFn = vi.fn(async () => jsonResponse(200, usageBody()));
    const svc = new UsageService({
      logger: createLogger('usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      now,
    });

    const result = await svc.getUsage();
    expect('available' in result).toBe(false);
    const snap = result as UsageSnapshot;

    expect(snap.fiveHour).toEqual({ utilization: 42, resetsAt: '2026-07-01T12:00:00Z' });
    expect(snap.sevenDay).toEqual({ utilization: 10, resetsAt: '2026-07-07T00:00:00Z' });
    // resets_at:null → resetsAt omitted, utilization still present.
    expect(snap.sevenDayOpus).toEqual({ utilization: 55 });
    // utilization:null → window omitted entirely.
    expect(snap.sevenDaySonnet).toBeUndefined();
    expect(snap.fetchedAt).toBe(clock);

    // Only the usage endpoint was hit (token still valid — no refresh).
    expect(fetchFn).toHaveBeenCalledTimes(1);
    expect(calls(fetchFn)[0][0]).toBe(USAGE_URL);
  });

  it('sends the User-Agent, Authorization and anthropic-beta headers on the usage call', async () => {
    writeCreds(clock + 3_600_000);
    const fetchFn = vi.fn(async () => jsonResponse(200, usageBody()));
    const svc = new UsageService({
      logger: createLogger('usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      userAgentVersion: '1.2.3',
      now,
    });

    await svc.getUsage();
    const init = calls(fetchFn)[0][1] as RequestInit;
    const headers = init.headers as Record<string, string>;
    expect(headers['User-Agent']).toBe('claude-code/1.2.3');
    expect(headers['anthropic-beta']).toBe('oauth-2025-04-20');
    expect(headers.Authorization).toBe(`Bearer ${ACCESS_TOKEN}`);
  });

  it('serves cache within TTL (a second call within cacheSec does not refetch)', async () => {
    writeCreds(clock + 3_600_000);
    const fetchFn = vi.fn(async () => jsonResponse(200, usageBody()));
    const svc = new UsageService({
      logger: createLogger('usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      cacheSec: 180,
      now,
    });

    await svc.getUsage();
    clock += 179_000; // still within 180s
    const second = await svc.getUsage();

    expect(fetchFn).toHaveBeenCalledTimes(1); // no refetch
    expect((second as UsageSnapshot).fiveHour?.utilization).toBe(42);

    // After the TTL elapses, it refetches.
    clock += 2_000; // now 181s past the first fetch
    await svc.getUsage();
    expect(fetchFn).toHaveBeenCalledTimes(2);
  });

  it('on HTTP 429 backs off, serves last-good cache, and does not throw', async () => {
    writeCreds(clock + 3_600_000);
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(200, usageBody())) // seed cache
      .mockResolvedValueOnce(jsonResponse(429, {})); // throttle
    const { lines, sink } = captureSink();
    const svc = new UsageService({
      logger: createLogger('usage', { sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      cacheSec: 180,
      now,
    });

    const first = await svc.getUsage();
    expect((first as UsageSnapshot).fiveHour?.utilization).toBe(42);

    clock += 181_000; // TTL elapsed → refetch attempt → 429
    const second = await svc.getUsage();

    // Last-good cache is served, no throw.
    expect((second as UsageSnapshot).fiveHour?.utilization).toBe(42);
    expect(fetchFn).toHaveBeenCalledTimes(2);
    expect(lines.some((l) => l.includes('rate-limited'))).toBe(true);

    // Backoff doubled the effective interval to 360s (measured from the last good
    // fetch at t=0). At t=+300s we are past the normal 180s TTL but still inside the
    // backed-off 360s window, so the service must serve cache and NOT refetch.
    clock += 119_000; // now t = +300s (181s + 119s)
    const third = await svc.getUsage();
    expect((third as UsageSnapshot).fiveHour?.utilization).toBe(42);
    expect(fetchFn).toHaveBeenCalledTimes(2);
  });

  it('no credentials file → isAvailable() false, getUsage() unavailable, no fetch attempted', async () => {
    const fetchFn = vi.fn();
    const svc = new UsageService({
      logger: createLogger('usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath, // never created
      readKeychain: () => null, // hermetic: never touch the real macOS Keychain
      now,
    });

    expect(svc.isAvailable()).toBe(false);
    const result = await svc.getUsage();
    expect(result).toEqual({ available: false, reason: 'no-credentials' });
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it('refreshes an expired token, then calls the usage endpoint', async () => {
    writeCreds(clock - 1_000); // already expired
    const fetchFn = vi.fn(async (url: string) => {
      if (url === TOKEN_URL) {
        return jsonResponse(200, { access_token: NEW_ACCESS_TOKEN, refresh_token: REFRESH_TOKEN, expires_in: 3600 });
      }
      return jsonResponse(200, usageBody());
    });
    const svc = new UsageService({
      logger: createLogger('usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      now,
    });

    const result = await svc.getUsage();
    expect('available' in result).toBe(false);

    // Refresh endpoint hit first, then usage — with the NEW token.
    expect(fetchFn).toHaveBeenCalledTimes(2);
    expect(calls(fetchFn)[0][0]).toBe(TOKEN_URL);
    expect(calls(fetchFn)[1][0]).toBe(USAGE_URL);
    const usageInit = calls(fetchFn)[1][1] as RequestInit;
    expect((usageInit.headers as Record<string, string>).Authorization).toBe(`Bearer ${NEW_ACCESS_TOKEN}`);

    // The refreshed token was persisted back to the credentials file.
    const persisted = JSON.parse(fs.readFileSync(credsPath, 'utf-8'));
    expect(persisted.claudeAiOauth.accessToken).toBe(NEW_ACCESS_TOKEN);
  });

  it('never leaks the access or refresh token into logged output', async () => {
    writeCreds(clock - 1_000); // force a refresh so both tokens are in play
    const fetchFn = vi.fn(async (url: string) => {
      if (url === TOKEN_URL) {
        return jsonResponse(200, { access_token: NEW_ACCESS_TOKEN, expires_in: 3600 });
      }
      // Return a 500 so the fetch path also logs a status warning.
      return jsonResponse(500, {});
    });
    const { lines, sink } = captureSink();
    const svc = new UsageService({
      logger: createLogger('usage', { level: 'debug', sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      now,
    });

    await svc.getUsage();
    const joined = lines.join('\n');
    expect(joined).not.toContain(ACCESS_TOKEN);
    expect(joined).not.toContain(REFRESH_TOKEN);
    expect(joined).not.toContain(NEW_ACCESS_TOKEN);
  });

  it('degrades gracefully on a malformed credentials file (no throw, unavailable)', async () => {
    fs.writeFileSync(credsPath, '{ not valid json', 'utf-8');
    const fetchFn = vi.fn();
    const svc = new UsageService({
      logger: createLogger('usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      credentialsPath: credsPath,
      readKeychain: () => null, // hermetic: no Keychain fallback for this case
      now,
    });

    expect(svc.isAvailable()).toBe(false);
    await expect(svc.getUsage()).resolves.toEqual({ available: false, reason: 'no-credentials' });
    expect(fetchFn).not.toHaveBeenCalled();
  });

  // macOS stores the OAuth credentials in the Keychain, not the file. When the file is
  // absent, the service falls back to an injectable Keychain reader (source of truth on
  // darwin) and writes a refreshed token back to the SAME source.
  describe('macOS Keychain fallback', () => {
    function credsBlob(expiresAt: number): string {
      return JSON.stringify({
        claudeAiOauth: { accessToken: ACCESS_TOKEN, refreshToken: REFRESH_TOKEN, expiresAt },
      });
    }

    it('reads credentials from the Keychain when the file is absent → snapshot', async () => {
      // credsPath is never created; the blob comes only from the injected reader.
      const fetchFn = vi.fn(async () => jsonResponse(200, usageBody()));
      const svc = new UsageService({
        logger: createLogger('usage', { sink: captureSink().sink }),
        fetchFn: fetchFn as unknown as typeof fetch,
        credentialsPath: credsPath,
        readKeychain: () => credsBlob(clock + 3_600_000),
        now,
      });

      expect(svc.isAvailable()).toBe(true);
      const snap = (await svc.getUsage()) as UsageSnapshot;
      expect(snap.fiveHour).toEqual({ utilization: 42, resetsAt: '2026-07-01T12:00:00Z' });
      expect(calls(fetchFn)[0][1]).toBeTruthy();
      const usageInit = calls(fetchFn)[0][1] as RequestInit;
      expect((usageInit.headers as Record<string, string>).Authorization).toBe(`Bearer ${ACCESS_TOKEN}`);
    });

    it('reports unavailable when the file is absent AND the Keychain has nothing', async () => {
      const fetchFn = vi.fn();
      const svc = new UsageService({
        logger: createLogger('usage', { sink: captureSink().sink }),
        fetchFn: fetchFn as unknown as typeof fetch,
        credentialsPath: credsPath,
        readKeychain: () => null,
        now,
      });

      expect(svc.isAvailable()).toBe(false);
      await expect(svc.getUsage()).resolves.toEqual({ available: false, reason: 'no-credentials' });
      expect(fetchFn).not.toHaveBeenCalled();
    });

    it('prefers the file over the Keychain (Keychain reader never consulted)', async () => {
      writeCreds(clock + 3_600_000); // valid file present
      const readKeychain = vi.fn(() => null);
      const fetchFn = vi.fn(async () => jsonResponse(200, usageBody()));
      const svc = new UsageService({
        logger: createLogger('usage', { sink: captureSink().sink }),
        fetchFn: fetchFn as unknown as typeof fetch,
        credentialsPath: credsPath,
        readKeychain,
        now,
      });

      await svc.getUsage();
      expect(readKeychain).not.toHaveBeenCalled(); // file-first short-circuits
    });

    it('write-back: a keychain-sourced refresh persists to the Keychain, NOT the file', async () => {
      // No file; the (expired) creds come from the Keychain, forcing a refresh.
      const readKeychain = () => credsBlob(clock - 1_000);
      const writeKeychain = vi.fn();
      const fetchFn = vi.fn(async (url: string) => {
        if (url === TOKEN_URL) {
          return jsonResponse(200, { access_token: NEW_ACCESS_TOKEN, refresh_token: REFRESH_TOKEN, expires_in: 3600 });
        }
        return jsonResponse(200, usageBody());
      });
      const svc = new UsageService({
        logger: createLogger('usage', { sink: captureSink().sink }),
        fetchFn: fetchFn as unknown as typeof fetch,
        credentialsPath: credsPath,
        readKeychain,
        writeKeychain,
        now,
      });

      await svc.getUsage();

      // Refreshed token written back to the Keychain with the new access token…
      expect(writeKeychain).toHaveBeenCalledTimes(1);
      const written = JSON.parse(writeKeychain.mock.calls[0][0] as string);
      expect(written.claudeAiOauth.accessToken).toBe(NEW_ACCESS_TOKEN);
      // …and NOT to the credentials file (which stays absent).
      expect(fs.existsSync(credsPath)).toBe(false);
    });

    it('write-back: a file-sourced refresh persists to the file, NOT the Keychain', async () => {
      writeCreds(clock - 1_000); // expired file creds → refresh
      const writeKeychain = vi.fn();
      const fetchFn = vi.fn(async (url: string) => {
        if (url === TOKEN_URL) {
          return jsonResponse(200, { access_token: NEW_ACCESS_TOKEN, refresh_token: REFRESH_TOKEN, expires_in: 3600 });
        }
        return jsonResponse(200, usageBody());
      });
      const svc = new UsageService({
        logger: createLogger('usage', { sink: captureSink().sink }),
        fetchFn: fetchFn as unknown as typeof fetch,
        credentialsPath: credsPath,
        writeKeychain,
        now,
      });

      await svc.getUsage();

      expect(writeKeychain).not.toHaveBeenCalled();
      const persisted = JSON.parse(fs.readFileSync(credsPath, 'utf-8'));
      expect(persisted.claudeAiOauth.accessToken).toBe(NEW_ACCESS_TOKEN);
    });

    it('never leaks tokens when a Keychain write-back fails (error name only)', async () => {
      const readKeychain = () => credsBlob(clock - 1_000); // expired → refresh
      const writeKeychain = vi.fn(() => {
        // Simulate `security` failing with a message that echoes the argv (the blob).
        throw new Error(`command failed: security add-generic-password -w ${NEW_ACCESS_TOKEN}`);
      });
      const fetchFn = vi.fn(async (url: string) => {
        if (url === TOKEN_URL) {
          return jsonResponse(200, { access_token: NEW_ACCESS_TOKEN, refresh_token: REFRESH_TOKEN, expires_in: 3600 });
        }
        return jsonResponse(200, usageBody());
      });
      const { lines, sink } = captureSink();
      const svc = new UsageService({
        logger: createLogger('usage', { level: 'debug', sink }),
        fetchFn: fetchFn as unknown as typeof fetch,
        credentialsPath: credsPath,
        readKeychain,
        writeKeychain,
        now,
      });

      // Must not throw despite the write failure.
      await expect(svc.getUsage()).resolves.toBeTruthy();
      const joined = lines.join('\n');
      expect(joined).not.toContain(NEW_ACCESS_TOKEN);
      expect(joined).not.toContain(ACCESS_TOKEN);
      expect(joined).not.toContain(REFRESH_TOKEN);
    });
  });

  it('codexUsageUnavailable() returns the typed codex-unsupported result', () => {
    expect(codexUsageUnavailable()).toEqual({ available: false, reason: 'codex-unsupported' });
  });
});
