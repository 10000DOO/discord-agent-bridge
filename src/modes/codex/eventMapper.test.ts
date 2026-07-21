import { describe, it, expect } from 'vitest';
import { mapAppServerNotification, type MapContext } from './eventMapper.js';

const idFor = (item: Record<string, unknown>): string =>
  typeof item.id === 'string' ? item.id : 'gen';

describe('mapAppServerNotification', () => {
  it('maps item/agentMessage/delta to streaming text', () => {
    const r = mapAppServerNotification('item/agentMessage/delta', {
      threadId: 't1',
      turnId: 'u1',
      itemId: 'i1',
      delta: 'Hello',
    });
    expect(r.events).toEqual([{ kind: 'text', text: 'Hello', delta: true }]);
    expect(r.threadId).toBe('t1');
    expect(r.turnId).toBe('u1');
  });

  it('maps commandExecution (camelCase) to shell tool_use + tool_result', () => {
    const r = mapAppServerNotification(
      'item/completed',
      {
        threadId: 't1',
        item: {
          type: 'commandExecution',
          id: 'c1',
          command: 'ls',
          aggregatedOutput: 'a\nb',
          exitCode: 0,
        },
      },
      { idFor },
    );
    expect(r.events).toEqual([
      { kind: 'tool_use', id: 'c1', name: 'shell', input: { command: 'ls' } },
      { kind: 'tool_result', id: 'c1', ok: true, content: 'a\nb' },
    ]);
  });

  it('maps failed commandExecution exitCode !== 0 to ok:false', () => {
    const r = mapAppServerNotification(
      'item/completed',
      {
        item: {
          type: 'commandExecution',
          id: 'c2',
          command: 'false',
          aggregatedOutput: 'err',
          exitCode: 1,
        },
      },
      { idFor },
    );
    expect(r.events).toContainEqual({ kind: 'tool_result', id: 'c2', ok: false, content: 'err' });
  });

  it('maps turn/completed to result + turnCompleted flag', () => {
    const r = mapAppServerNotification('turn/completed', {
      threadId: 't1',
      turnId: 'turn-9',
      usage: { inputTokens: 10, outputTokens: 5 },
    });
    expect(r.turnCompleted).toBe(true);
    expect(r.turnId).toBe('turn-9');
    expect(r.events).toEqual([{ kind: 'result', tokensIn: 10, tokensOut: 5 }]);
  });

  it('maps fileChange to apply_patch tool_use + tool_result with unified diffs', () => {
    const r = mapAppServerNotification(
      'item/completed',
      {
        item: {
          type: 'fileChange',
          id: 'f1',
          status: 'completed',
          changes: [{ path: 'a.ts', kind: { type: 'add' }, diff: '+ line' }],
        },
      },
      { idFor },
    );
    expect(r.events).toEqual([
      {
        kind: 'tool_use',
        id: 'f1',
        name: 'apply_patch',
        input: { changes: [{ path: 'a.ts', kind: { type: 'add' }, diff: '+ line' }] },
      },
      { kind: 'tool_result', id: 'f1', ok: true, content: '--- a.ts\n+ line' },
    ]);
  });

  it('maps reasoning deltas to thinking', () => {
    for (const method of [
      'item/reasoning/delta',
      'item/agentReasoning/delta',
      'item/reasoning/textDelta',
      'item/reasoning/summaryTextDelta',
    ]) {
      const r = mapAppServerNotification(method, { delta: 'hmm', threadId: 't1', turnId: 'u1' });
      expect(r.events).toEqual([{ kind: 'thinking', text: 'hmm', delta: true }]);
    }
  });

  it('exposes tokenUsage snapshot (no context_usage event) when modelContextWindow is known', () => {
    const r = mapAppServerNotification('thread/tokenUsage/updated', {
      threadId: 't1',
      turnId: 'u1',
      tokenUsage: {
        total: { totalTokens: 2500, inputTokens: 2000, outputTokens: 500, cachedInputTokens: 0, reasoningOutputTokens: 0 },
        last: { totalTokens: 100, inputTokens: 80, outputTokens: 20, cachedInputTokens: 0, reasoningOutputTokens: 0 },
        modelContextWindow: 10000,
      },
    });
    // Mid-turn updates must not emit context_usage events (panel spam).
    expect(r.events).toEqual([]);
    expect(r.tokenUsage).toEqual({
      totalTokens: 2500,
      maxTokens: 10000,
      percentage: 25,
    });
  });

  it('skips tokenUsage when modelContextWindow is missing', () => {
    const r = mapAppServerNotification('thread/tokenUsage/updated', {
      tokenUsage: {
        total: { totalTokens: 100, inputTokens: 100, outputTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0 },
        last: { totalTokens: 100, inputTokens: 100, outputTokens: 0, cachedInputTokens: 0, reasoningOutputTokens: 0 },
      },
    });
    expect(r.events).toEqual([]);
    expect(r.tokenUsage).toBeUndefined();
  });

  it('maps webSearch and mcpToolCall', () => {
    const web = mapAppServerNotification(
      'item/completed',
      { item: { type: 'webSearch', id: 'w1', query: 'cats' } },
      { idFor },
    );
    expect(web.events).toEqual([
      { kind: 'tool_use', id: 'w1', name: 'web_search', input: { query: 'cats' } },
    ]);

    const mcp = mapAppServerNotification(
      'item/completed',
      {
        item: {
          type: 'mcpToolCall',
          id: 'm1',
          tool: 'search',
          arguments: { q: 'x' },
          result: 'ok',
          status: 'completed',
        },
      },
      { idFor },
    );
    expect(mcp.events).toEqual([
      { kind: 'tool_use', id: 'm1', name: 'search', input: { q: 'x' } },
      { kind: 'tool_result', id: 'm1', ok: true, content: 'ok' },
    ]);
  });

  it('maps collabAgentToolCall spawnAgent and registers child thread', () => {
    const spawns: Array<{ child: string; tool: string }> = [];
    const ctx: MapContext = {
      idFor,
      onSpawnThread: (child, tool) => spawns.push({ child, tool }),
    };
    const r = mapAppServerNotification(
      'item/completed',
      {
        item: {
          type: 'collabAgentToolCall',
          id: 'spawn-1',
          tool: 'spawnAgent',
          agentRole: 'explorer',
          agentNickname: 'Scout',
          threadId: 'child-thread-9',
          status: 'completed',
        },
      },
      ctx,
    );
    expect(r.events[0]).toMatchObject({
      kind: 'tool_use',
      id: 'spawn-1',
      name: 'spawnAgent',
      input: expect.objectContaining({
        subagent_type: 'explorer',
        agentNickname: 'Scout',
        threadId: 'child-thread-9',
      }),
    });
    expect(spawns).toEqual([{ child: 'child-thread-9', tool: 'spawn-1' }]);
  });

  it('attaches parentToolUseId when threadId is in parentByThread', () => {
    const parentByThread = new Map([['child-t', 'spawn-1']]);
    const r = mapAppServerNotification(
      'item/completed',
      {
        threadId: 'child-t',
        item: {
          type: 'commandExecution',
          id: 'c9',
          command: 'pwd',
          aggregatedOutput: '/',
          exitCode: 0,
        },
      },
      { idFor, parentByThread },
    );
    expect(r.events[0]).toMatchObject({ parentToolUseId: 'spawn-1' });
    expect(r.events[1]).toMatchObject({ parentToolUseId: 'spawn-1' });
  });

  it('maps item/started commandExecution to progress', () => {
    const r = mapAppServerNotification('item/started', {
      item: { type: 'commandExecution', command: 'ls -la' },
    });
    expect(r.events).toEqual([{ kind: 'progress', label: '명령 실행 중', detail: 'ls -la' }]);
  });

  it('maps turn/failed to error and turnCompleted', () => {
    const r = mapAppServerNotification('turn/failed', {
      turnId: 'u1',
      error: { message: 'boom' },
    });
    expect(r.events).toEqual([{ kind: 'error', message: 'boom', retryable: false }]);
    expect(r.turnCompleted).toBe(true);
  });

  it('returns empty events for unknown methods (never throws)', () => {
    expect(() => mapAppServerNotification('future/thing', { x: 1 })).not.toThrow();
    expect(mapAppServerNotification('future/thing', { x: 1 }).events).toEqual([]);
  });

  it('drops reasoning (thinking phase 2)', () => {
    const r = mapAppServerNotification(
      'item/completed',
      { item: { type: 'reasoning', text: 'secret' } },
      { idFor },
    );
    expect(r.events).toEqual([]);
  });
});
