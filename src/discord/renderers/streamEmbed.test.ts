import { describe, it, expect } from 'vitest';
import { StreamEmbedHandler } from './streamEmbed.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';

// A fake channel + a manual timer: the handler's debounce is driven by firing the
// captured timer callback explicitly, so no real time passes.
function harness() {
  const sent: OutgoingMessage[] = [];
  const edits: { id: string; msg: OutgoingMessage }[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send(message) {
      sent.push(message);
      const id = `m${++seq}`;
      const em: EditableMessage = {
        id,
        async edit(m) {
          edits.push({ id, msg: m });
        },
      };
      return em;
    },
    async startThread() {
      throw new Error('not used');
    },
  };
  let pending: (() => void) | null = null;
  const setTimer = (fn: () => void) => {
    pending = fn;
    return 1;
  };
  const clearTimer = () => {
    pending = null;
  };
  const fire = async () => {
    const fn = pending;
    pending = null;
    fn?.();
    await new Promise((r) => setImmediate(r));
  };
  return { channel, sent, edits, setTimer, clearTimer, fire };
}

describe('StreamEmbedHandler (text)', () => {
  it('debounces: one embed sent on flush, edited on subsequent flush', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'Hel', delta: true });
    s.push({ kind: 'text', text: 'lo', delta: true });
    await h.fire();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0].embeds?.[0].description).toBe('Hello');

    s.push({ kind: 'text', text: ' world', delta: true });
    await h.fire();
    expect(h.sent).toHaveLength(1); // still one message
    expect(h.edits.at(-1)?.msg.embeds?.[0].description).toBe('Hello world');
  });

  it('finalize replaces the streaming embed with plain text content', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'answer', delta: true });
    await h.fire();
    await s.finalize();
    const finalEdit = h.edits.at(-1);
    expect(finalEdit?.msg.content).toBe('answer');
    expect(finalEdit?.msg.embeds).toEqual([]); // embed cleared
  });

  it('finalize with no prior flush sends plain content directly', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'quick', delta: true });
    await s.finalize();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0].content).toBe('quick');
  });

  it('is a no-op with no buffered text', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    await s.finalize();
    expect(h.sent).toHaveLength(0);
  });
});

describe('StreamEmbedHandler (thinking)', () => {
  it('finalize collapses to a "thought for" embed', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({
      channel: h.channel,
      kind: 'thinking',
      setTimer: h.setTimer,
      clearTimer: h.clearTimer,
      now: () => 1000,
    });
    s.push({ kind: 'thinking', text: 'hmm', delta: true });
    await h.fire();
    await s.finalize();
    const finalEdit = h.edits.at(-1);
    expect(finalEdit?.msg.embeds?.[0].title).toContain('생각함');
  });
});
