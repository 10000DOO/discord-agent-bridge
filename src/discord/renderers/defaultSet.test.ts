import { describe, it, expect } from 'vitest';
import { RendererDispatcher, createDefaultRendererSet } from './index.js';
import type { AgentEvent, Capabilities } from '../../core/contracts.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';

function fakeChannel() {
  const sent: OutgoingMessage[] = [];
  const edits: OutgoingMessage[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send(message) {
      sent.push(message);
      const em: EditableMessage = {
        id: `m${++seq}`,
        async edit(m) {
          edits.push(m);
        },
      };
      return em;
    },
    async startThread(name) {
      const id = `t${++seq}`;
      return {
        id,
        async send(message) {
          sent.push({ ...message, content: `[thread:${name}] ${message.content ?? ''}` });
          return { id: `tm${++seq}`, async edit() {} };
        },
      };
    },
  };
  return { channel, sent, edits };
}

const flush = () => new Promise((r) => setImmediate(r));

const codexCaps: Capabilities = {
  streaming: false,
  thinking: false,
  toolThreads: false,
  permissionPrompts: false,
  progress: true,
  transcript: true,
  sessionResume: true,
  fileAttach: false,
  fileDiff: false,
  usagePanel: false,
  permissionModes: ['default', 'plan'],
};

const claudeCaps: Capabilities = {
  streaming: true,
  thinking: true,
  toolThreads: true,
  permissionPrompts: true,
  progress: false,
  transcript: false,
  sessionResume: true,
  fileAttach: true,
  fileDiff: true,
  usagePanel: true,
  permissionModes: ['default', 'plan'],
};

describe('default renderer set — Codex-like routing', () => {
  it('routes final text to a plain channel message and progress to the transcript feed', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, codexCaps);

    dispatcher.dispatch({ kind: 'text', text: 'the answer', delta: false } as AgentEvent);
    dispatcher.dispatch({ kind: 'progress', label: 'editing file' } as AgentEvent);
    await flush();

    const contents = sent.map((m) => m.content);
    expect(contents).toContain('the answer'); // plain message, not an embed
    expect(contents).toContain('editing file'); // transcript status line
    expect(sent.every((m) => !m.embeds)).toBe(true); // no streaming embeds for Codex
  });

  it('does not open tool threads or usage panel for Codex caps', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, codexCaps);
    dispatcher.dispatch({ kind: 'tool_use', id: 't1', name: 'Edit', input: {} } as AgentEvent);
    dispatcher.dispatch({ kind: 'context_usage', totalTokens: 1, maxTokens: 2, percentage: 50 } as AgentEvent);
    await flush();
    expect(sent.some((m) => (m.content ?? '').startsWith('[thread:'))).toBe(false);
    expect(sent.some((m) => m.embeds?.[0].title?.includes('사용량'))).toBe(false);
  });
});

describe('default renderer set — result line + mention', () => {
  it('posts a done-line with only the fields present and @mentions the owner', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'owner-9' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    dispatcher.dispatch({ kind: 'result', costUsd: 0.1234, durationMs: 3000 } as AgentEvent);
    await flush();
    const line = sent.find((m) => (m.content ?? '').includes('완료'));
    expect(line?.content).toContain('$0.1234');
    expect(line?.content).toContain('3.0s');
    expect(line?.content).not.toContain('토큰'); // tokens absent → not rendered
    const mention = sent.find((m) => m.content === '<@owner-9>');
    expect(mention?.mentionUserIds).toEqual(['owner-9']);
  });
});
