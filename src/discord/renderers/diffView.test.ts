import { describe, it, expect } from 'vitest';
import { DiffViewHandler } from './diffView.js';
import { TurnThreadRegistry } from './turnThread.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { MessageChannel, MessageThread, OutgoingMessage } from '../ports.js';

type ToolUse = Extract<AgentEvent, { kind: 'tool_use' }>;
type ToolResult = Extract<AgentEvent, { kind: 'tool_result' }>;

function setup() {
  const threadPosts: OutgoingMessage[] = [];
  const threadNames: string[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send() {
      throw new Error('diff must post to the thread, not the channel');
    },
    async startThread(name) {
      threadNames.push(name);
      const id = `t${++seq}`;
      const thread: MessageThread = {
        id,
        async send(message) {
          threadPosts.push(message);
          return { id: `tm${++seq}`, async edit() {} };
        },
      };
      return thread;
    },
  };
  const registry = new TurnThreadRegistry({ channel, mainName: '작업 내역' });
  const h = new DiffViewHandler({ registry });
  return { h, registry, threadPosts, threadNames };
}

const use = (e: ToolUse): ToolUse => e;
const result = (e: ToolResult): ToolResult => e;

describe('DiffViewHandler', () => {
  it('renders an old→new diff for a successful Edit into the shared thread', async () => {
    const { h, threadPosts, threadNames } = setup();
    h.noteToolUse(use({ kind: 'tool_use', id: 't1', name: 'Edit', input: { file_path: '/ws/a.ts', old_string: 'a', new_string: 'b' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't1', ok: true, content: 'ok' }));
    expect(threadNames).toEqual(['작업 내역']);
    expect(threadPosts).toHaveLength(1);
    const body = threadPosts[0].content ?? '';
    expect(body).toContain('```diff');
    expect(body).toContain('- a');
    expect(body).toContain('+ b');
  });

  it('renders additions-only for a Write with content', async () => {
    const { h, threadPosts } = setup();
    h.noteToolUse(use({ kind: 'tool_use', id: 't2', name: 'Write', input: { file_path: '/ws/n.ts', content: 'line1\nline2' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't2', ok: true, content: 'ok' }));
    expect(threadPosts[0].content).toContain('+ line1');
    expect(threadPosts[0].content).toContain('+ line2');
  });

  it('renders nothing (and opens no thread) for a non-edit tool', async () => {
    const { h, threadPosts, threadNames } = setup();
    h.noteToolUse(use({ kind: 'tool_use', id: 't3', name: 'Bash', input: { command: 'ls' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't3', ok: true, content: 'files' }));
    expect(threadPosts).toHaveLength(0);
    expect(threadNames).toHaveLength(0);
  });

  it('renders nothing for a failed edit result', async () => {
    const { h, threadPosts, threadNames } = setup();
    h.noteToolUse(use({ kind: 'tool_use', id: 't4', name: 'Edit', input: { file_path: '/ws/a.ts', old_string: 'a', new_string: 'b' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't4', ok: false, content: 'error' }));
    expect(threadPosts).toHaveLength(0);
    expect(threadNames).toHaveLength(0);
  });

  it('posts a nested edit diff into the parent spawn thread', async () => {
    const { h, registry, threadNames, threadPosts } = setup();
    // Spawn first so the named thread exists with the right display name.
    await registry.getForToolUse({
      kind: 'tool_use',
      id: 'spawn1',
      name: 'Task',
      input: { subagent_type: 'reviewer' },
    });
    h.noteToolUse(
      use({
        kind: 'tool_use',
        id: 'e1',
        name: 'Edit',
        input: { file_path: '/ws/a.ts', old_string: 'x', new_string: 'y' },
        parentToolUseId: 'spawn1',
      }),
    );
    await h.handleResult(result({ kind: 'tool_result', id: 'e1', ok: true, content: 'ok', parentToolUseId: 'spawn1' }));
    expect(threadNames).toEqual(['reviewer']);
    expect(threadPosts[0].content).toContain('+ y');
  });

  it('renders Codex apply_patch changes[] as a unified diff', async () => {
    const { h, threadPosts } = setup();
    h.noteToolUse(
      use({
        kind: 'tool_use',
        id: 'p1',
        name: 'apply_patch',
        input: {
          changes: [{ path: 'src/a.ts', kind: { type: 'update' }, diff: '- old\n+ new' }],
        },
      }),
    );
    await h.handleResult(result({ kind: 'tool_result', id: 'p1', ok: true, content: 'ok' }));
    expect(threadPosts).toHaveLength(1);
    const body = threadPosts[0].content ?? '';
    expect(body).toContain('```diff');
    expect(body).toContain('--- src/a.ts');
    expect(body).toContain('- old');
    expect(body).toContain('+ new');
  });
});
