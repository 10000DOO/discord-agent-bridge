import { describe, it, expect } from 'vitest';
import { StreamEmbedHandler } from './streamEmbed.js';
import type { ButtonSpec, EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';

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

  it('hasEmitted() is false until a flush or finalize actually places content', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    // No push → finalize is a no-op; nothing was emitted.
    await s.finalize();
    expect(s.hasEmitted()).toBe(false);
  });

  it('hasEmitted() flips to true after the debounced flush sends the live embed', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'hi', delta: true });
    expect(s.hasEmitted()).toBe(false); // still buffered
    await h.fire();
    expect(s.hasEmitted()).toBe(true);
  });

  it('hasEmitted() flips to true when finalize sends without a prior flush', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'answer', delta: true });
    await s.finalize();
    expect(s.hasEmitted()).toBe(true);
  });
});

describe('StreamEmbedHandler — per-turn lifecycle', () => {
  // One instance serves exactly one turn: finalize() is terminal, so multi-turn
  // streaming means a fresh instance per turn (the dispatcher swaps on result).
  it('a fresh instance streams turn 2 while the finalized turn-1 instance drops late pushes', async () => {
    const h = harness();
    const t1 = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    t1.push({ kind: 'text', text: 'turn one', delta: true });
    await t1.finalize();
    t1.push({ kind: 'text', text: 'stale', delta: true }); // late delta against the ended turn
    const t2 = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    t2.push({ kind: 'text', text: 'turn two', delta: true });
    await t2.finalize();
    expect(h.sent.map((m) => m.content)).toEqual(['turn one', 'turn two']);
  });

  it('hasEmitted() is per instance: a silent turn-2 instance stays false after an emitting turn 1', async () => {
    const h = harness();
    const t1 = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    t1.push({ kind: 'text', text: 'turn one', delta: true });
    await t1.finalize();
    expect(t1.hasEmitted()).toBe(true);
    const t2 = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    await t2.finalize(); // no deltas this turn
    expect(t2.hasEmitted()).toBe(false);
  });
});

describe('StreamEmbedHandler — interrupt action button (option B)', () => {
  const stopButton: ButtonSpec = { type: 'button', customId: 'interrupt:g1:c1', label: '⏹️ 중단', style: 'secondary' };

  it('renders the enabled action button on the live embed while streaming', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer, actions: [stopButton] });
    s.push({ kind: 'text', text: 'hi', delta: true });
    await h.fire();
    expect(h.sent[0].embeds?.[0].description).toBe('hi');
    expect(h.sent[0].components?.[0].components).toEqual([stopButton]); // enabled on the live embed
  });

  it('re-renders the button DISABLED on finalize so a stale click cannot fire', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer, actions: [stopButton] });
    s.push({ kind: 'text', text: 'answer', delta: true });
    await h.fire();
    await s.finalize();
    const finalEdit = h.edits.at(-1);
    expect(finalEdit?.msg.content).toBe('answer');
    const button = finalEdit?.msg.components?.[0].components?.[0] as ButtonSpec;
    expect(button.disabled).toBe(true);
    expect(button.customId).toBe('interrupt:g1:c1');
  });

  it('adds no components when finalize sends WITHOUT a prior flush (the button was never shown)', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer, actions: [stopButton] });
    s.push({ kind: 'text', text: 'quick', delta: true });
    await s.finalize(); // no debounce flush → plain send, no live embed ever carried a button
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0].content).toBe('quick');
    expect(h.sent[0].components).toBeUndefined();
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

  it('hasEmitted() flips to true after the thinking finalize sends the collapsed embed', async () => {
    const h = harness();
    const s = new StreamEmbedHandler({
      channel: h.channel,
      kind: 'thinking',
      setTimer: h.setTimer,
      clearTimer: h.clearTimer,
      now: () => 1000,
    });
    s.push({ kind: 'thinking', text: 'hmm', delta: true });
    expect(s.hasEmitted()).toBe(false);
    await s.finalize();
    expect(s.hasEmitted()).toBe(true);
  });
});

// Resilience: a channel deleted mid-stream (Unknown Channel 10003) or a REST/network
// timeout makes send/edit REJECT. The debounce flush is unawaited, so a leaked
// rejection would hard-crash the process. flush() must swallow it (keeping `inflight`
// resolved) so streaming continues and no unhandled rejection escapes.
describe('StreamEmbedHandler — send/edit failure resilience', () => {
  // A channel whose send (and the resulting message's edit) reject on demand, driven
  // by the same manual timer as harness().
  function failingHarness(opts: { failSend?: boolean; failEdit?: boolean }) {
    const sent: OutgoingMessage[] = [];
    let seq = 0;
    const channel: MessageChannel = {
      async send(message) {
        if (opts.failSend) throw new Error('DiscordAPIError: Unknown Channel (10003)');
        sent.push(message);
        const id = `m${++seq}`;
        const em: EditableMessage = {
          id,
          async edit() {
            if (opts.failEdit) throw new Error('DiscordAPIError: Unknown Channel (10003)');
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
    return { channel, sent, setTimer, clearTimer, fire };
  }

  it('a failed debounce flush does not poison inflight: a later finalize resolves + delivers', async () => {
    const opts = { failSend: true };
    const h = failingHarness(opts);
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'hi', delta: true });
    await h.fire(); // flush send rejects → swallowed → `inflight` must stay RESOLVED
    expect(s.hasEmitted()).toBe(false); // nothing delivered yet
    opts.failSend = false; // channel recovers
    // finalize awaits `inflight`; if the failed flush had left it rejected, this throws.
    await expect(s.finalize()).resolves.toBeUndefined();
    expect(s.hasEmitted()).toBe(true);
    expect(h.sent.map((m) => m.content)).toEqual(['hi']);
  });

  it('a failing flush never surfaces as an unhandled rejection', async () => {
    const seen: unknown[] = [];
    const onRej = (r: unknown) => seen.push(r);
    process.on('unhandledRejection', onRej);
    try {
      const h = failingHarness({ failEdit: true });
      const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
      s.push({ kind: 'text', text: 'a', delta: true });
      await h.fire(); // first flush: send ok → message created
      s.push({ kind: 'text', text: 'b', delta: true });
      await h.fire(); // second flush: edit rejects → swallowed
      // Give the rejection queue a couple of ticks to surface any leak.
      await new Promise((r) => setTimeout(r, 0));
      await new Promise((r) => setTimeout(r, 0));
      expect(seen).toEqual([]);
    } finally {
      process.off('unhandledRejection', onRej);
    }
  });

  it('keeps streaming after a failed flush: a later successful flush still delivers', async () => {
    // Fail the first send, then flip to success and confirm the stream recovers.
    const opts = { failSend: true };
    const h = failingHarness(opts);
    const s = new StreamEmbedHandler({ channel: h.channel, kind: 'text', setTimer: h.setTimer, clearTimer: h.clearTimer });
    s.push({ kind: 'text', text: 'first', delta: true });
    await h.fire(); // send rejects, swallowed, nothing sent
    expect(h.sent).toHaveLength(0);
    opts.failSend = false; // channel "recovers"
    s.push({ kind: 'text', text: ' second', delta: true });
    await h.fire(); // now succeeds
    expect(h.sent).toHaveLength(1);
    expect(s.hasEmitted()).toBe(true);
  });
});
