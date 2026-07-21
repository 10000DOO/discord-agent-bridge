import { describe, it, expect } from 'vitest';
import { ToolThreadHandler } from './toolThread.js';
import { TurnThreadRegistry } from './turnThread.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { MessageChannel, MessageThread, OutgoingMessage } from '../ports.js';

type ToolEvent = Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>;
const ev = (e: ToolEvent): ToolEvent => e;

function setup() {
  const threadPosts: Array<OutgoingMessage & { threadName: string }> = [];
  const threadNames: string[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send() {
      throw new Error('tool activity must post to the thread, not the channel');
    },
    async startThread(name) {
      threadNames.push(name);
      const id = `t${++seq}`;
      const thread: MessageThread = {
        id,
        async send(message) {
          threadPosts.push({ ...message, threadName: name });
          return { id: `tm${++seq}`, async edit() {} };
        },
      };
      return thread;
    },
  };
  const registry = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
  const h = new ToolThreadHandler({ registry });
  return { h, registry, threadPosts, threadNames };
}

const flush = () => new Promise((r) => setImmediate(r));

describe('ToolThreadHandler', () => {
  it('posts a summary header + input and the result into the shared thread', async () => {
    const { h, threadPosts, threadNames } = setup();
    await h.handle(ev({ kind: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls -la' } }));
    await h.handle(ev({ kind: 'tool_result', id: 't1', ok: true, content: 'output' }));
    expect(threadNames).toEqual(['작업 내역']);
    const posts = threadPosts.map((m) => m.content ?? '');
    expect(posts.some((c) => c.includes('Bash: ls -la'))).toBe(true); // summary header before input
    expect(posts.some((c) => c.includes('결과'))).toBe(true);
    expect(posts.some((c) => c.includes('output'))).toBe(true);
  });

  it('reuses one shared thread across multiple main tools in a turn', async () => {
    const { h, threadNames } = setup();
    await h.handle(ev({ kind: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls' } }));
    await h.handle(ev({ kind: 'tool_use', id: 't2', name: 'Grep', input: { pattern: 'x' } }));
    expect(threadNames).toHaveLength(1);
  });

  it('buffers a result that arrives before its thread and flushes on open, naming the tool', async () => {
    const { h, threadPosts } = setup();
    // Result first (out of order) → no thread yet, nothing posted.
    await h.handle(ev({ kind: 'tool_result', id: 't9', ok: true, content: 'early' }));
    expect(threadPosts).toHaveLength(0);
    // The tool_use opens the thread and the buffered result is flushed.
    await h.handle(ev({ kind: 'tool_use', id: 't9', name: 'Read', input: { file_path: '/ws/x' } }));
    await flush();
    const posts = threadPosts.map((m) => m.content ?? '');
    expect(posts.some((c) => c.includes('early'))).toBe(true);
    expect(posts.some((c) => c.includes('Read'))).toBe(true); // result header names the tool
  });

  it('skips raw input for diff-rendered tools but still posts their result', async () => {
    const { h, threadPosts } = setup();
    await h.handle(ev({ kind: 'tool_use', id: 't1', name: 'Edit', input: { file_path: '/ws/a.ts', old_string: 'a', new_string: 'b' } }));
    await h.handle(ev({ kind: 'tool_result', id: 't1', ok: true, content: 'done' }));
    const posts = threadPosts.map((m) => m.content ?? '');
    // No raw input JSON for the edit (DiffViewHandler renders the diff instead).
    expect(posts.some((c) => c.includes('"file_path"'))).toBe(false);
    // The result header is still shown so success/failure stays visible.
    expect(posts.some((c) => c.includes('결과'))).toBe(true);
  });

  it('posts an error header for a failed result', async () => {
    const { h, threadPosts } = setup();
    await h.handle(ev({ kind: 'tool_use', id: 't1', name: 'Bash', input: { command: 'nope' } }));
    await h.handle(ev({ kind: 'tool_result', id: 't1', ok: false, content: 'boom' }));
    const posts = threadPosts.map((m) => m.content ?? '');
    expect(posts.some((c) => c.includes('오류'))).toBe(true);
    expect(posts.some((c) => c.includes('boom'))).toBe(true);
  });

  it('resetTurn drops a buffered result so it cannot misfire into the next turn', async () => {
    const { h, threadPosts } = setup();
    // An out-of-order result buffers (no thread yet); the turn then ends.
    await h.handle(ev({ kind: 'tool_result', id: 't1', ok: true, content: 'stale' }));
    h.resetTurn();
    // Next turn: a tool_use opens the thread — the stale buffered result must NOT resurface.
    await h.handle(ev({ kind: 'tool_use', id: 't2', name: 'Bash', input: { command: 'ls' } }));
    const posts = threadPosts.map((m) => m.content ?? '');
    expect(posts.some((c) => c.includes('stale'))).toBe(false);
  });

  it('routes spawn tools and nested parent tools to separate named threads', async () => {
    const { h, threadNames, threadPosts } = setup();
    await h.handle(ev({ kind: 'tool_use', id: 'main1', name: 'Bash', input: { command: 'ls' } }));
    await h.handle(
      ev({
        kind: 'tool_use',
        id: 'spawn1',
        name: 'Task',
        input: { subagent_type: 'developer', description: 'Fix bug' },
      }),
    );
    await h.handle(
      ev({
        kind: 'tool_use',
        id: 'nested1',
        name: 'Read',
        input: { file_path: '/ws/x' },
        parentToolUseId: 'spawn1',
      }),
    );
    await h.handle(
      ev({ kind: 'tool_result', id: 'nested1', ok: true, content: 'nested-out', parentToolUseId: 'spawn1' }),
    );
    expect(threadNames).toEqual(['작업 내역', 'developer']);
    // Nested tool posts go to the spawn thread, not main.
    expect(
      threadPosts.some((m) => m.threadName === 'developer' && (m.content ?? '').includes('nested-out')),
    ).toBe(true);
    expect(
      threadPosts.some((m) => m.threadName === '작업 내역' && (m.content ?? '').includes('nested-out')),
    ).toBe(false);
  });
});
