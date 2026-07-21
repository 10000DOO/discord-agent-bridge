import { describe, it, expect } from 'vitest';
import {
  TurnThreadHolder,
  TurnThreadRegistry,
  subagentThreadName,
  isSubagentSpawnTool,
  MAIN_THREAD_KEY,
} from './turnThread.js';
import type { MessageChannel, MessageThread } from '../ports.js';

// A channel whose startThread counts calls and can be made to fail once, so the
// holder's create-once and retry-after-failure guarantees are observable.
function fakeChannel(opts: { failTimes?: number } = {}) {
  let creates = 0;
  let failsLeft = opts.failTimes ?? 0;
  const names: string[] = [];
  const channel: MessageChannel = {
    async send() {
      throw new Error('unused');
    },
    async startThread(name) {
      creates += 1;
      names.push(name);
      if (failsLeft > 0) {
        failsLeft -= 1;
        throw new Error('open failed');
      }
      const thread: MessageThread = {
        id: `t${creates}`,
        async send() {
          return { id: 'm', async edit() {} };
        },
      };
      return thread;
    },
  };
  return { channel, creates: () => creates, names };
}

describe('TurnThreadHolder', () => {
  it('creates the thread exactly once across concurrent first accesses', async () => {
    const { channel, creates } = fakeChannel();
    const holder = new TurnThreadHolder({ channel, name: 'work' });
    const [a, b] = await Promise.all([holder.get(), holder.get()]);
    expect(creates()).toBe(1);
    expect(a).toBe(b); // the same thread instance for every caller
  });

  it('opens a fresh thread after reset (next turn)', async () => {
    const { channel, creates } = fakeChannel();
    const holder = new TurnThreadHolder({ channel, name: 'work' });
    await holder.get();
    expect(holder.opened).toBe(true);
    holder.reset();
    expect(holder.opened).toBe(false);
    await holder.get();
    expect(creates()).toBe(2);
  });

  it('reset before any access is a no-op (no thread created)', () => {
    const { channel, creates } = fakeChannel();
    const holder = new TurnThreadHolder({ channel, name: 'work' });
    holder.reset();
    expect(holder.opened).toBe(false);
    expect(creates()).toBe(0);
  });

  it('retries on the next access when the first open fails (turn not poisoned)', async () => {
    const { channel, creates } = fakeChannel({ failTimes: 1 });
    const holder = new TurnThreadHolder({ channel, name: 'work' });
    await expect(holder.get()).rejects.toThrow('open failed');
    expect(holder.opened).toBe(false); // cache cleared so a retry can open
    const thread = await holder.get();
    expect(thread.id).toBe('t2');
    expect(creates()).toBe(2);
  });

  it('a late rejection from a previous turn does not poison the next turn', async () => {
    // A channel whose opens resolve/reject on demand, so a turn-1 open can settle AFTER
    // turn 2 has already opened its own live thread.
    const attempts: { resolve: (t: MessageThread) => void; reject: (e: unknown) => void }[] = [];
    let creates = 0;
    const channel: MessageChannel = {
      async send() {
        throw new Error('unused');
      },
      startThread() {
        creates += 1;
        return new Promise<MessageThread>((resolve, reject) => {
          attempts.push({ resolve, reject });
        });
      },
    };
    const holder = new TurnThreadHolder({ channel, name: 'work' });

    // Turn 1: begin opening (attempt 0), then the turn ends before it settles.
    const turn1 = holder.get();
    const turn1Settled = turn1.catch(() => 'rejected'); // swallow the eventual rejection
    holder.reset();

    // Turn 2: open a fresh thread (attempt 1) that resolves to a live thread.
    const turn2 = holder.get();
    const liveThread: MessageThread = { id: 't2', async send() { return { id: 'm', async edit() {} }; } };
    attempts[1].resolve(liveThread);
    await expect(turn2).resolves.toBe(liveThread);

    // Turn 1's open finally FAILS — the identity guard must keep this late rejection from
    // clearing turn 2's live creation (which would let the next access open a 3rd thread).
    attempts[0].reject(new Error('late open failure'));
    await turn1Settled;

    expect(holder.opened).toBe(true);
    await expect(holder.get()).resolves.toBe(liveThread);
    expect(creates).toBe(2); // no third startThread
  });
});

describe('subagentThreadName / isSubagentSpawnTool', () => {
  it('recognizes Task, Agent, spawn_subagent, spawnAgent case-sensitively', () => {
    expect(isSubagentSpawnTool('Task')).toBe(true);
    expect(isSubagentSpawnTool('Agent')).toBe(true);
    expect(isSubagentSpawnTool('spawn_subagent')).toBe(true);
    expect(isSubagentSpawnTool('spawnAgent')).toBe(true);
    expect(isSubagentSpawnTool('task')).toBe(false);
    expect(isSubagentSpawnTool('Bash')).toBe(false);
  });

  it('prefers subagent_type then subagentType then agentRole/nickname then description then name', () => {
    expect(subagentThreadName('Task', { subagent_type: 'developer', description: 'x' })).toBe('developer');
    expect(subagentThreadName('Task', { subagentType: 'reviewer' })).toBe('reviewer');
    expect(subagentThreadName('spawnAgent', { agentRole: 'explorer' })).toBe('explorer');
    expect(subagentThreadName('spawnAgent', { agentNickname: 'Scout' })).toBe('Scout');
    expect(subagentThreadName('Task', { description: 'Fix the bug' })).toBe('Fix the bug');
    expect(subagentThreadName('spawn_subagent', {})).toBe('spawn_subagent');
  });
});

describe('TurnThreadRegistry', () => {
  it('opens main + two named spawn threads (3 names)', async () => {
    const { channel, names } = fakeChannel();
    const reg = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
    await reg.getForToolUse({ kind: 'tool_use', id: 'm1', name: 'Bash', input: { command: 'ls' } });
    await reg.getForToolUse({
      kind: 'tool_use',
      id: 's1',
      name: 'Task',
      input: { subagent_type: 'developer' },
    });
    await reg.getForToolUse({
      kind: 'tool_use',
      id: 's2',
      name: 'spawn_subagent',
      input: { subagent_type: 'architect' },
    });
    expect(names).toEqual(['작업 내역', 'developer', 'architect']);
    expect(reg.hasOpened(MAIN_THREAD_KEY)).toBe(true);
    expect(reg.hasOpened('s1')).toBe(true);
    expect(reg.hasOpened('s2')).toBe(true);
  });

  it('routes nested parentToolUseId tools to the spawn thread', async () => {
    const { channel, names, creates } = fakeChannel();
    const reg = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
    await reg.getForToolUse({
      kind: 'tool_use',
      id: 'spawn1',
      name: 'Task',
      input: { subagent_type: 'developer' },
    });
    const nested = await reg.getForToolUse({
      kind: 'tool_use',
      id: 'n1',
      name: 'Read',
      input: { file_path: '/x' },
      parentToolUseId: 'spawn1',
    });
    // Nested reuses the spawn holder — no third startThread.
    expect(creates()).toBe(1);
    expect(names).toEqual(['developer']);
    expect(nested.id).toBe('t1');

    // Result for nested resolves to the same open spawn thread (not buffered).
    const resultThread = await reg.getForToolResult({
      kind: 'tool_result',
      id: 'n1',
      ok: true,
      content: 'ok',
      parentToolUseId: 'spawn1',
    });
    expect(resultThread?.id).toBe('t1');
  });

  it('returns null from getForToolResult when the target thread is not opened yet', async () => {
    const { channel } = fakeChannel();
    const reg = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
    const early = await reg.getForToolResult({ kind: 'tool_result', id: 't1', ok: true, content: 'x' });
    expect(early).toBeNull();
  });

  it('reset clears maps so the next turn opens fresh threads', async () => {
    const { channel, creates, names } = fakeChannel();
    const reg = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
    await reg.getForToolUse({ kind: 'tool_use', id: 'm1', name: 'Bash', input: {} });
    await reg.getForToolUse({
      kind: 'tool_use',
      id: 's1',
      name: 'Task',
      input: { subagent_type: 'dev' },
    });
    expect(creates()).toBe(2);
    reg.reset();
    expect(reg.hasOpened(MAIN_THREAD_KEY)).toBe(false);
    expect(reg.hasOpened('s1')).toBe(false);
    await reg.getForToolUse({ kind: 'tool_use', id: 'm2', name: 'Bash', input: {} });
    expect(creates()).toBe(3);
    expect(names[names.length - 1]).toBe('작업 내역');
  });

  it('reuses one main thread for ordinary tools without parent', async () => {
    const { channel, creates, names } = fakeChannel();
    const reg = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
    await reg.getForToolUse({ kind: 'tool_use', id: 't1', name: 'Bash', input: {} });
    await reg.getForToolUse({ kind: 'tool_use', id: 't2', name: 'Grep', input: {} });
    expect(creates()).toBe(1);
    expect(names).toEqual(['작업 내역']);
  });
});
