import { describe, it, expect, vi } from 'vitest';
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

  it('splits a >2000-char final text into ordered plain-message chunks', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, codexCaps);

    const longText = 'z'.repeat(3000); // > MSG_LIMIT (2000)
    dispatcher.dispatch({ kind: 'text', text: longText, delta: false } as AgentEvent);
    await flush();

    const chunkSends = sent.filter((m) => (m.content ?? '').startsWith('z'));
    expect(chunkSends.length).toBeGreaterThanOrEqual(2);
    expect(chunkSends.every((m) => (m.content ?? '').length <= 2000)).toBe(true);
    expect(chunkSends.map((m) => m.content ?? '').join('')).toBe(longText); // order preserved
    expect(sent.every((m) => !m.embeds)).toBe(true);
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

describe('default renderer set — rate limit line', () => {
  it('shows the snapshot windows from getUsage when the event omits utilization', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({
      channel,
      ownerId: 'u1',
      getUsage: () => ({ fetchedAt: 0, fiveHour: { utilization: 73 } }),
    });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    dispatcher.dispatch({ kind: 'rate_limit', rateLimitType: 'five_hour' } as AgentEvent);
    await flush();
    const line = sent.find((m) => (m.content ?? '').includes('사용량 한도 알림'));
    expect(line?.content).toBe('📊 사용량 한도 알림 · 5시간 73%');
  });
});

describe('default renderer set — result text fallback', () => {
  // A finalize()/hasEmitted() sequence is async: promise chain, then chunked send.
  // Two microtask flushes reliably drain both stages under the fake channel.
  const flushTwice = async () => {
    await new Promise((r) => setImmediate(r));
    await new Promise((r) => setImmediate(r));
  };

  it('posts ev.text as a plain message when no text deltas ever arrived', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    dispatcher.dispatch({ kind: 'result', text: 'hello world', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    expect(sent.some((m) => m.content === 'hello world')).toBe(true);
    // Done-line is also posted alongside the fallback text.
    expect(sent.some((m) => (m.content ?? '').includes('완료'))).toBe(true);
  });

  it('does NOT post ev.text as a fallback when the stream already emitted content', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    // A prior text delta drives the stream; finalize emits the buffered text.
    // ev.text uses a distinct marker so a fallback send would be observable —
    // stream-buffered text and ev.text almost always differ in real backends
    // (delta stream is partial, ev.text is the full canonical answer).
    dispatcher.dispatch({ kind: 'text', text: 'buffered', delta: true } as AgentEvent);
    dispatcher.dispatch({ kind: 'result', text: 'FALLBACK_MARKER_TEXT', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    expect(sent.some((m) => m.content === 'FALLBACK_MARKER_TEXT')).toBe(false);
  });

  it('renders text deltas of the next turn after a result (handlers swapped per turn)', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    dispatcher.dispatch({ kind: 'text', text: 'first answer', delta: true } as AgentEvent);
    dispatcher.dispatch({ kind: 'result', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    dispatcher.dispatch({ kind: 'text', text: 'second answer', delta: true } as AgentEvent);
    dispatcher.dispatch({ kind: 'result', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    const contents = sent.map((m) => m.content);
    expect(contents).toContain('first answer');
    expect(contents).toContain('second answer');
  });

  it('renders a turn-2 delta that arrives before the turn-1 finalize settles', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    dispatcher.dispatch({ kind: 'text', text: 'first answer', delta: true } as AgentEvent);
    dispatcher.dispatch({ kind: 'result', costUsd: 0.01 } as AgentEvent);
    // No flush: the turn-2 delta lands while turn 1 is still finalizing.
    dispatcher.dispatch({ kind: 'text', text: 'second answer', delta: true } as AgentEvent);
    await flushTwice();
    dispatcher.dispatch({ kind: 'result', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    const contents = sent.map((m) => m.content);
    expect(contents).toContain('first answer');
    expect(contents).toContain('second answer');
  });

  it('fires the ev.text fallback on turn 2 when only turn 1 streamed deltas', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    dispatcher.dispatch({ kind: 'text', text: 'first answer', delta: true } as AgentEvent);
    dispatcher.dispatch({ kind: 'result', text: 'T1_FALLBACK', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    dispatcher.dispatch({ kind: 'result', text: 'T2_FALLBACK', costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    const contents = sent.map((m) => m.content);
    expect(contents).not.toContain('T1_FALLBACK'); // turn 1 streamed → no fallback
    expect(contents).toContain('T2_FALLBACK'); // turn 2 never streamed → fallback fires
  });

  it('chunks long ev.text into multiple sends when the stream never emitted', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    const longText = 'a'.repeat(3000); // > MSG_LIMIT (2000)
    dispatcher.dispatch({ kind: 'result', text: longText, costUsd: 0.01 } as AgentEvent);
    await flushTwice();
    const chunkSends = sent.filter((m) => (m.content ?? '').startsWith('a'));
    expect(chunkSends.length).toBeGreaterThanOrEqual(2);
    const joined = chunkSends.map((m) => m.content ?? '').join('');
    expect(joined).toBe(longText);
  });
});

describe('default renderer set — rate_limit rendering', () => {
  it('renders a rate_limit event with 📊 (not ⚠️) and a human-readable summary', async () => {
    const { channel, sent } = fakeChannel();
    const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
    const dispatcher = new RendererDispatcher(set, claudeCaps);
    // Fixed epoch → deterministic HH:mm; the label test is locale-stable because we
    // reuse the same toLocaleTimeString call the renderer uses.
    const resetAt = new Date(1000 * 1000).toISOString();
    const expectedHHmm = new Date(1000 * 1000).toLocaleTimeString('ko-KR', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });
    dispatcher.dispatch({
      kind: 'rate_limit',
      utilization: 87,
      rateLimitType: 'five_hour',
      resetAt,
    } as AgentEvent);
    await flush();
    const line = sent.find((m) => (m.content ?? '').startsWith('📊'));
    expect(line?.content).toBe(`📊 사용량 한도 알림 · 5시간 한도 · 사용량 87% · 리셋 ${expectedHHmm}`);
    // No error emoji ever, for either the same or any other message.
    expect(sent.some((m) => (m.content ?? '').startsWith('⚠️'))).toBe(false);
  });
});

describe('default renderer set — dispose after result (§6)', () => {
  it('cancels ended handlers still finalizing: no late thinking embed after dispose', async () => {
    vi.useFakeTimers();
    try {
      const { channel, sent, edits } = fakeChannel();
      const set = createDefaultRendererSet({ channel, ownerId: 'u1' });
      const dispatcher = new RendererDispatcher(set, claudeCaps);
      // The thinking delta arms the 2s debounce; result swaps in fresh handlers while
      // the ended thinking handler is NOT yet finalized (its finalize is chained
      // behind the ended text finalize). dispose before that chain settles must
      // cancel the ended pair, not just the fresh one.
      dispatcher.dispatch({ kind: 'thinking', text: 'hmm', delta: true } as AgentEvent);
      dispatcher.dispatch({ kind: 'result', costUsd: 0.01 } as AgentEvent);
      set.dispose?.();
      await vi.advanceTimersByTimeAsync(5000); // a leaked debounce timer would fire here
      expect(sent.every((m) => !m.embeds)).toBe(true); // no "Thinking…"/"Thought for" embed
      expect(edits).toHaveLength(0);
    } finally {
      vi.useRealTimers();
    }
  });
});
