import { describe, it, expect, vi, beforeEach } from 'vitest';
import type { ModeContext } from '../../core/contracts.js';
import type { QueryFn } from '../claude/session.js';
import { CustomMode, type ListSessionsFn } from './index.js';
import { claudeCatalog } from '../../core/providerCatalog.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

function makeCtx(overrides: Partial<ModeContext> = {}): ModeContext {
  return {
    guildId: 'g1',
    channelId: 'c1',
    cwd: '/tmp/ws',
    ownerId: 'u1',
    permMode: 'default',
    emit: () => {},
    requestPermission: async () => ({ behavior: 'deny' }),
    config: {},
    logger: nullLogger,
    audit: () => {},
    ...overrides,
  };
}

function fakeQueryFn(): { queryFn: QueryFn; captured: { options?: unknown }; state: { closed: boolean } } {
  const captured: { options?: unknown } = {};
  const state = { closed: false };
  const queryFn: QueryFn = ({ options }) => {
    captured.options = options;
    return {
      async *[Symbol.asyncIterator]() {},
      close() { state.closed = true; },
      async getContextUsage() { return { totalTokens: 0, maxTokens: 0, percentage: 0 }; },
    } as unknown as ReturnType<QueryFn>;
  };
  return { queryFn, captured, state };
}

vi.mock('./shellEnv.js', () => ({
  resolveCustomEnv: vi.fn(),
}));

import { resolveCustomEnv } from './shellEnv.js';

describe('CustomMode', () => {
  beforeEach(() => {
    vi.mocked(resolveCustomEnv).mockReset();
  });

  it('has name "custom" and Claude-compatible capabilities', () => {
    const mode = new CustomMode();
    expect(mode.name).toBe('custom');
    expect(mode.capabilities.sessionResume).toBe(true);
    expect(mode.capabilities.usagePanel).toBe(true);
    expect(mode.capabilities.permissionModes).toContain('bypassPermissions');
    // Reuses the Claude SDK, so it shares Claude's UI vocabulary (§6).
    expect(mode.catalog).toBe(claudeCatalog);
  });

  it('start() injects resolved env and prefers ANTHROPIC_MODEL over ctx.model', async () => {
    vi.mocked(resolveCustomEnv).mockReturnValue({
      env: { ANTHROPIC_MODEL: 'kimi-k2.7-code', ANTHROPIC_BASE_URL: 'https://api.example.com' },
      source: '.zshrc',
      hasDangerousFlag: false,
    });

    const { queryFn, captured } = fakeQueryFn();
    const ctx = makeCtx({ model: 'opus' });
    const mode = new CustomMode({ queryFn });
    const session = await mode.start(ctx);

    expect(session.sessionId).toBeNull();
    const options = captured.options as { env?: Record<string, string>; model?: string };
    expect(options.model).toBe('kimi-k2.7-code');
    expect(options.env?.ANTHROPIC_BASE_URL).toBe('https://api.example.com');
    expect(options.env?.ANTHROPIC_MODEL).toBe('kimi-k2.7-code');
  });

  it('warns when the alias contains --dangerously-skip-permissions and permMode is not bypassPermissions', async () => {
    const warnings: unknown[][] = [];
    vi.mocked(resolveCustomEnv).mockReturnValue({
      env: { ANTHROPIC_MODEL: 'kimi' },
      source: '.zshrc',
      hasDangerousFlag: true,
    });

    const { queryFn } = fakeQueryFn();
    const ctx = makeCtx({
      permMode: 'default',
      logger: { ...nullLogger, warn: (...m: unknown[]) => warnings.push(m) },
    });
    await new CustomMode({ queryFn }).start(ctx);
    expect(warnings.length).toBe(1);
  });

  it('does not warn about the dangerous flag when permMode is bypassPermissions', async () => {
    const warnings: unknown[][] = [];
    vi.mocked(resolveCustomEnv).mockReturnValue({
      env: { ANTHROPIC_MODEL: 'kimi' },
      source: '.zshrc',
      hasDangerousFlag: true,
    });

    const { queryFn } = fakeQueryFn();
    const ctx = makeCtx({
      permMode: 'bypassPermissions',
      logger: { ...nullLogger, warn: (...m: unknown[]) => warnings.push(m) },
    });
    await new CustomMode({ queryFn }).start(ctx);
    expect(warnings.length).toBe(0);
  });

  it('resume() passes resumeId through and keeps the injected env', async () => {
    vi.mocked(resolveCustomEnv).mockReturnValue({
      env: { ANTHROPIC_MODEL: 'kimi' },
      source: '.zshrc',
      hasDangerousFlag: false,
    });

    const { queryFn, captured } = fakeQueryFn();
    const ctx = makeCtx();
    const session = await new CustomMode({ queryFn }).resume(ctx, 'sess-prev');

    expect(session.sessionId).toBe('sess-prev');
    const options = captured.options as { resume?: string; env?: Record<string, string> };
    expect(options.resume).toBe('sess-prev');
    expect(options.env?.ANTHROPIC_MODEL).toBe('kimi');
  });

  it('listResumable() maps SDK sessions like ClaudeMode', async () => {
    const listSessionsFn = vi.fn<ListSessionsFn>(async () => [
      { sessionId: 'a', summary: 'Work', lastModified: Date.UTC(2026, 0, 2), cwd: '/tmp/ws' },
    ]);
    const sessions = await new CustomMode({ listSessionsFn }).listResumable(makeCtx({ cwd: '/tmp/ws' }));
    expect(listSessionsFn).toHaveBeenCalledWith({ dir: '/tmp/ws', limit: 25 });
    expect(sessions).toEqual([
      { sessionId: 'a', cwd: '/tmp/ws', label: 'Work', updatedAt: new Date(Date.UTC(2026, 0, 2)).toISOString() },
    ]);
  });

  it('listResumable() returns [] on failure', async () => {
    const listSessionsFn = vi.fn<ListSessionsFn>(async () => { throw new Error('unsupported'); });
    const sessions = await new CustomMode({ listSessionsFn }).listResumable(makeCtx());
    expect(sessions).toEqual([]);
  });
});
