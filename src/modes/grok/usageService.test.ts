import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { GrokUsageService } from './usageService.js';
import type { UsageSnapshot } from '../../core/usageService.js';
import { createLogger, type LogSink, type LogLevel } from '../../core/logger.js';

// Zero-entropy sentinel token (no realistic secret literals in source).
const ACCESS_TOKEN = 'G'.repeat(24);

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

function jsonResponse(status: number, body: unknown): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as unknown as Response;
}

const BILLING_URL = 'https://cli-chat-proxy.grok.com/v1/billing?format=credits';

function billingBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    config: {
      currentPeriod: {
        type: 'USAGE_PERIOD_TYPE_WEEKLY',
        start: '2026-07-14T00:00:00Z',
        end: '2026-07-21T00:00:00Z',
      },
      creditUsagePercent: 6.0,
      productUsage: [
        { product: 'GrokBuild', usagePercent: 3.0 },
        { product: 'GrokChat', usagePercent: 3.0 },
      ],
      billingPeriodEnd: '2026-08-01T00:00:00Z',
      ...overrides,
    },
  };
}

describe('GrokUsageService', () => {
  let dir: string;
  let authPath: string;
  let clock: number;

  const now = () => clock;

  function writeAuth(key: string = ACCESS_TOKEN): void {
    fs.writeFileSync(authPath, JSON.stringify({ account1: { key } }), 'utf-8');
  }

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-grok-usage-'));
    authPath = path.join(dir, 'auth.json');
    clock = 1_000_000;
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('maps creditUsagePercent (account weekly) to sevenDay; period end to resetsAt', async () => {
    writeAuth();
    const fetchFn = vi.fn(async () => jsonResponse(200, billingBody()));
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
    });

    const result = await svc.getUsage();
    expect('available' in result).toBe(false);
    const snap = result as UsageSnapshot;

    // Prefer total creditUsagePercent (6) over productUsage GrokBuild (3).
    expect(snap.sevenDay).toEqual({ utilization: 6.0, resetsAt: '2026-07-21T00:00:00Z' });
    expect(snap.fiveHour).toBeUndefined();
    expect(snap.sevenDayOpus).toBeUndefined();
    expect(snap.sevenDaySonnet).toBeUndefined();
    expect(snap.fetchedAt).toBe(clock);

    expect(fetchFn).toHaveBeenCalledTimes(1);
    const [url, init] = fetchFn.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe(BILLING_URL);
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe(`Bearer ${ACCESS_TOKEN}`);
    expect(headers.Accept).toBe('application/json');
    expect(headers['x-grok-client-mode']).toBe('cli');
  });

  it('falls back to GrokBuild productUsage when creditUsagePercent is absent', async () => {
    writeAuth();
    const fetchFn = vi.fn(async () =>
      jsonResponse(
        200,
        billingBody({
          productUsage: [{ product: 'GrokBuild', usagePercent: 12.5 }],
          creditUsagePercent: null,
        }),
      ),
    );
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
    });

    const snap = (await svc.getUsage()) as UsageSnapshot;
    expect(snap.sevenDay?.utilization).toBe(12.5);
  });

  it('falls back to billingPeriodEnd when currentPeriod.end is missing', async () => {
    writeAuth();
    const fetchFn = vi.fn(async () =>
      jsonResponse(
        200,
        billingBody({
          currentPeriod: { type: 'USAGE_PERIOD_TYPE_WEEKLY', start: '2026-07-14T00:00:00Z' },
          billingPeriodEnd: '2026-08-01T00:00:00Z',
        }),
      ),
    );
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
    });

    const snap = (await svc.getUsage()) as UsageSnapshot;
    expect(snap.sevenDay?.resetsAt).toBe('2026-08-01T00:00:00Z');
  });

  it('never sets fiveHour / opus / sonnet windows', async () => {
    writeAuth();
    const fetchFn = vi.fn(async () => jsonResponse(200, billingBody()));
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
    });

    const snap = (await svc.getUsage()) as UsageSnapshot;
    expect(Object.keys(snap).sort()).toEqual(['fetchedAt', 'sevenDay']);
  });

  it('missing auth → isAvailable() false, getUsage() unavailable, no fetch attempted', async () => {
    const fetchFn = vi.fn(async () => jsonResponse(200, billingBody()));
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath: path.join(dir, 'missing.json'),
      now,
    });

    expect(svc.isAvailable()).toBe(false);
    await expect(svc.getUsage()).resolves.toEqual({ available: false, reason: 'no-credentials' });
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it('empty key in auth map → unavailable', async () => {
    fs.writeFileSync(authPath, JSON.stringify({ account1: { key: '' } }), 'utf-8');
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      authPath,
      now,
    });
    expect(svc.isAvailable()).toBe(false);
    await expect(svc.getUsage()).resolves.toEqual({ available: false, reason: 'no-credentials' });
  });

  it('serves cache within TTL and refetches after cacheSec', async () => {
    writeAuth();
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(200, billingBody({ creditUsagePercent: 1 })))
      .mockResolvedValueOnce(jsonResponse(200, billingBody({ creditUsagePercent: 9 })));
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
      cacheSec: 15,
    });

    const first = (await svc.getUsage()) as UsageSnapshot;
    expect(first.sevenDay?.utilization).toBe(1);
    expect(fetchFn).toHaveBeenCalledTimes(1);

    clock += 5_000;
    const second = (await svc.getUsage()) as UsageSnapshot;
    expect(second.sevenDay?.utilization).toBe(1);
    expect(fetchFn).toHaveBeenCalledTimes(1);

    clock += 11_000;
    const third = (await svc.getUsage()) as UsageSnapshot;
    expect(third.sevenDay?.utilization).toBe(9);
    expect(fetchFn).toHaveBeenCalledTimes(2);
  });

  it('on non-OK status returns last cache, else unavailable', async () => {
    writeAuth();
    const fetchFn = vi
      .fn()
      .mockResolvedValueOnce(jsonResponse(200, billingBody()))
      .mockResolvedValueOnce(jsonResponse(500, { error: 'boom' }));
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
      cacheSec: 0,
    });

    const first = (await svc.getUsage()) as UsageSnapshot;
    expect(first.sevenDay?.utilization).toBe(6.0);

    clock += 1;
    const second = await svc.getUsage();
    expect(second).toEqual(first);
  });

  it('401 soft-fails without throwing; warns and returns unavailable when no cache', async () => {
    writeAuth();
    const { lines, sink } = captureSink();
    const fetchFn = vi.fn(async () => jsonResponse(401, { error: 'unauthorized' }));
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
    });

    await expect(svc.getUsage()).resolves.toEqual({ available: false, reason: 'no-credentials' });
    expect(lines.some((l) => l.includes('401'))).toBe(true);
    // Token must never appear in logs.
    expect(lines.join('\n')).not.toContain(ACCESS_TOKEN);
  });

  it('missing percent → unavailable', async () => {
    writeAuth();
    const fetchFn = vi.fn(async () =>
      jsonResponse(200, {
        config: {
          productUsage: [{ product: 'GrokChat', usagePercent: null }],
          creditUsagePercent: null,
        },
      }),
    );
    const svc = new GrokUsageService({
      logger: createLogger('grok-usage', { sink: captureSink().sink }),
      fetchFn: fetchFn as unknown as typeof fetch,
      authPath,
      now,
    });

    await expect(svc.getUsage()).resolves.toEqual({ available: false, reason: 'no-credentials' });
  });
});
