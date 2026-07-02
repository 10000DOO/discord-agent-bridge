import { describe, it, expect, vi } from 'vitest';
import type { AgentEvent, ModeContext } from '../../core/contracts.js';
import { ClaudeMode, type ListSessionsFn } from './index.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

// Minimal ModeContext for listResumable (reads cwd/config/logger only).
function makeCtx(cwd = '/work/proj'): { ctx: ModeContext; warnings: unknown[][] } {
  const warnings: unknown[][] = [];
  const events: AgentEvent[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd,
    ownerId: 'u1',
    permMode: 'default',
    emit: (ev) => events.push(ev),
    requestPermission: async () => ({ behavior: 'deny' }),
    config: {},
    logger: { ...nullLogger, warn: (...m: unknown[]) => warnings.push(m) },
    audit: () => {},
  };
  return { ctx, warnings };
}

// A SDKSessionInfo shape (only the fields listResumable maps are required here).
function sess(over: Partial<{
  sessionId: string;
  summary: string;
  lastModified: number;
  cwd: string;
  firstPrompt: string;
}> = {}) {
  return {
    sessionId: over.sessionId ?? 'sid-1',
    summary: over.summary ?? 'Fix the parser',
    lastModified: over.lastModified ?? Date.UTC(2026, 0, 2, 3, 4, 5),
    ...(over.cwd !== undefined ? { cwd: over.cwd } : {}),
    ...(over.firstPrompt !== undefined ? { firstPrompt: over.firstPrompt } : {}),
  };
}

describe('ClaudeMode.listResumable', () => {
  it('calls listSessions({ dir }) and maps SDKSessionInfo → ResumableSession', async () => {
    const listSessionsFn = vi.fn<ListSessionsFn>(async () => [
      sess({ sessionId: 'a', summary: 'Add feature', lastModified: Date.UTC(2026, 0, 2), cwd: '/work/proj' }),
      sess({ sessionId: 'b', summary: 'Refactor', lastModified: Date.UTC(2026, 0, 1) }),
    ]);
    const mode = new ClaudeMode({ listSessionsFn });
    const { ctx } = makeCtx('/work/proj');

    const sessions = await mode.listResumable(ctx);

    // Scoped to the ctx cwd (same call A4D's /resume uses).
    expect(listSessionsFn).toHaveBeenCalledTimes(1);
    expect(listSessionsFn.mock.calls[0]?.[0]).toMatchObject({ dir: '/work/proj' });

    expect(sessions).toEqual([
      { sessionId: 'a', cwd: '/work/proj', label: 'Add feature', updatedAt: new Date(Date.UTC(2026, 0, 2)).toISOString() },
      // 'b' recorded no cwd → falls back to ctx.cwd.
      { sessionId: 'b', cwd: '/work/proj', label: 'Refactor', updatedAt: new Date(Date.UTC(2026, 0, 1)).toISOString() },
    ]);
  });

  it('falls back to firstPrompt for the label when summary is empty', async () => {
    const listSessionsFn = vi.fn<ListSessionsFn>(async () => [
      sess({ sessionId: 'c', summary: '', firstPrompt: 'help me debug' }),
    ]);
    const sessions = await new ClaudeMode({ listSessionsFn }).listResumable(makeCtx().ctx);
    expect(sessions[0]?.label).toBe('help me debug');
  });

  it('returns [] when there are no sessions', async () => {
    const listSessionsFn = vi.fn<ListSessionsFn>(async () => []);
    const sessions = await new ClaudeMode({ listSessionsFn }).listResumable(makeCtx().ctx);
    expect(sessions).toEqual([]);
  });

  it('guards a listSessions failure → [] (SDK listSessions may be unavailable) and warns', async () => {
    const listSessionsFn = vi.fn<ListSessionsFn>(async () => {
      throw new Error('listSessions not supported by this SDK');
    });
    const { ctx, warnings } = makeCtx();
    const sessions = await new ClaudeMode({ listSessionsFn }).listResumable(ctx);
    expect(sessions).toEqual([]);
    expect(warnings.length).toBeGreaterThan(0);
  });
});
