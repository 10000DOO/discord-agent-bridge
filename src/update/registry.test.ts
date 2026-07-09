import { describe, it, expect, vi } from 'vitest';
import { fetchLatestVersion } from './registry.js';

// A fetch double returning a scripted Response-like object.
function fetchReturning(res: Partial<Response> & { json?: () => Promise<unknown> }): typeof fetch {
  return (async () => res) as unknown as typeof fetch;
}

describe('fetchLatestVersion', () => {
  it('returns the version from a 200 response', async () => {
    const fetchFn = fetchReturning({ ok: true, status: 200, json: async () => ({ version: '1.2.3' }) });
    expect(await fetchLatestVersion(fetchFn)).toBe('1.2.3');
  });

  it('sends the URL, Accept, and User-Agent when provided', async () => {
    const spy = vi.fn(async (_url: string, _init?: RequestInit) => ({
      ok: true,
      status: 200,
      json: async () => ({ version: '9.9.9' }),
    }));
    await fetchLatestVersion(spy as unknown as typeof fetch, { userAgent: 'dab/1.0.0' });
    const call = spy.mock.calls[0]!;
    const headers = call[1]!.headers as Record<string, string>;
    expect(call[0]).toBe('https://registry.npmjs.org/discord-agent-bridge/latest');
    expect(headers['User-Agent']).toBe('dab/1.0.0');
    expect(headers['Accept']).toBe('application/json');
  });

  it('returns null on a non-OK status', async () => {
    const fetchFn = fetchReturning({ ok: false, status: 500, json: async () => ({}) });
    expect(await fetchLatestVersion(fetchFn)).toBeNull();
  });

  it('returns null when the body has no version field', async () => {
    const fetchFn = fetchReturning({ ok: true, status: 200, json: async () => ({ name: 'x' }) });
    expect(await fetchLatestVersion(fetchFn)).toBeNull();
  });

  it('returns null (never throws) on invalid JSON', async () => {
    const fetchFn = fetchReturning({
      ok: true,
      status: 200,
      json: async () => {
        throw new Error('Unexpected token');
      },
    });
    await expect(fetchLatestVersion(fetchFn)).resolves.toBeNull();
  });

  it('returns null (never throws) when the request rejects (offline/timeout)', async () => {
    const fetchFn = (async () => {
      throw new Error('ENOTFOUND');
    }) as unknown as typeof fetch;
    await expect(fetchLatestVersion(fetchFn)).resolves.toBeNull();
  });

  it('aborts via signal when the timeout elapses (never throws)', async () => {
    // A fetch that rejects with an AbortError once the injected signal fires.
    const fetchFn = ((_url: string, init?: RequestInit) =>
      new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
      })) as unknown as typeof fetch;
    await expect(fetchLatestVersion(fetchFn, { timeoutMs: 1 })).resolves.toBeNull();
  });
});
