import { describe, it, expect } from 'vitest';
import { ToolThreadHandler } from './toolThread.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { MessageChannel, MessageThread, OutgoingMessage } from '../ports.js';

type ToolEvent = Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>;
const ev = (e: ToolEvent): ToolEvent => e;

function fakeChannel() {
  const threadPosts: Record<string, OutgoingMessage[]> = {};
  const threadNames: string[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send() {
      return { id: `m${++seq}`, async edit() {} };
    },
    async startThread(name) {
      threadNames.push(name);
      const id = `t${++seq}`;
      threadPosts[id] = [];
      const thread: MessageThread = {
        id,
        async send(message) {
          threadPosts[id].push(message);
          return { id: `tm${++seq}`, async edit() {} };
        },
      };
      return thread;
    },
  };
  return { channel, threadPosts, threadNames };
}

const flush = () => new Promise((r) => setImmediate(r));

describe('ToolThreadHandler', () => {
  it('opens a thread named from tool+input and posts the result back', async () => {
    const { channel, threadPosts, threadNames } = fakeChannel();
    const h = new ToolThreadHandler({ channel });
    await h.handle(ev({ kind: 'tool_use', id: 't1', name: 'Bash', input: { command: 'ls -la' } }));
    await h.handle(ev({ kind: 'tool_result', id: 't1', ok: true, content: 'output' }));
    expect(threadNames[0]).toBe('Bash: ls -la');
    const posts = Object.values(threadPosts)[0].map((m) => m.content ?? '');
    expect(posts.some((c) => c.includes('결과'))).toBe(true);
    expect(posts.some((c) => c.includes('output'))).toBe(true);
  });

  it('buffers a result that arrives before its thread and flushes on open', async () => {
    const { channel, threadPosts } = fakeChannel();
    const h = new ToolThreadHandler({ channel });
    // Result first (out of order).
    await h.handle(ev({ kind: 'tool_result', id: 't9', ok: true, content: 'early' }));
    // No thread yet → no posts.
    expect(Object.keys(threadPosts)).toHaveLength(0);
    // Now the tool_use opens the thread and the buffered result is flushed.
    await h.handle(ev({ kind: 'tool_use', id: 't9', name: 'Read', input: { file_path: '/ws/x' } }));
    await flush();
    const posts = Object.values(threadPosts)[0].map((m) => m.content ?? '');
    expect(posts.some((c) => c.includes('early'))).toBe(true);
  });
});
