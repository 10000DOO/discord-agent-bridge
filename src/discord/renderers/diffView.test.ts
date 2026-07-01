import { describe, it, expect } from 'vitest';
import { DiffViewHandler } from './diffView.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';

type ToolUse = Extract<AgentEvent, { kind: 'tool_use' }>;
type ToolResult = Extract<AgentEvent, { kind: 'tool_result' }>;

function fakeChannel() {
  const sent: OutgoingMessage[] = [];
  const channel: MessageChannel = {
    async send(message) {
      sent.push(message);
      const em: EditableMessage = { id: 'm1', async edit() {} };
      return em;
    },
    async startThread() {
      throw new Error('not used');
    },
  };
  return { channel, sent };
}

const use = (e: ToolUse): ToolUse => e;
const result = (e: ToolResult): ToolResult => e;

describe('DiffViewHandler', () => {
  it('renders an old→new diff for a successful Edit', async () => {
    const { channel, sent } = fakeChannel();
    const h = new DiffViewHandler({ channel });
    h.noteToolUse(use({ kind: 'tool_use', id: 't1', name: 'Edit', input: { file_path: '/ws/a.ts', old_string: 'a', new_string: 'b' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't1', ok: true, content: 'ok' }));
    expect(sent).toHaveLength(1);
    const body = sent[0].content ?? '';
    expect(body).toContain('```diff');
    expect(body).toContain('- a');
    expect(body).toContain('+ b');
  });

  it('renders additions-only for a Write with content', async () => {
    const { channel, sent } = fakeChannel();
    const h = new DiffViewHandler({ channel });
    h.noteToolUse(use({ kind: 'tool_use', id: 't2', name: 'Write', input: { file_path: '/ws/n.ts', content: 'line1\nline2' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't2', ok: true, content: 'ok' }));
    expect(sent[0].content).toContain('+ line1');
    expect(sent[0].content).toContain('+ line2');
  });

  it('renders nothing for a non-edit tool', async () => {
    const { channel, sent } = fakeChannel();
    const h = new DiffViewHandler({ channel });
    h.noteToolUse(use({ kind: 'tool_use', id: 't3', name: 'Bash', input: { command: 'ls' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't3', ok: true, content: 'files' }));
    expect(sent).toHaveLength(0);
  });

  it('renders nothing for a failed edit result', async () => {
    const { channel, sent } = fakeChannel();
    const h = new DiffViewHandler({ channel });
    h.noteToolUse(use({ kind: 'tool_use', id: 't4', name: 'Edit', input: { file_path: '/ws/a.ts', old_string: 'a', new_string: 'b' } }));
    await h.handleResult(result({ kind: 'tool_result', id: 't4', ok: false, content: 'error' }));
    expect(sent).toHaveLength(0);
  });
});
