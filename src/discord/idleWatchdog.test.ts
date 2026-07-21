import { describe, it, expect, afterEach } from 'vitest';
import { IdleWatchdog, IDLE_WATCHDOG_MS } from './idleWatchdog.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from './ports.js';
import { setLocale, t } from './i18n.js';

// Manual timer harness (same pattern as streamEmbed tests): capture the pending
// callback and fire it explicitly so no real wall-clock time passes.
function harness() {
  const sent: OutgoingMessage[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send(message) {
      sent.push(message);
      const em: EditableMessage = {
        id: `m${++seq}`,
        async edit() {},
      };
      return em;
    },
    async startThread() {
      throw new Error('not used');
    },
  };
  let pending: (() => void) | null = null;
  let lastMs: number | null = null;
  const setTimer = (fn: () => void, ms: number) => {
    pending = fn;
    lastMs = ms;
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
  const hasPending = () => pending !== null;
  return { channel, sent, setTimer, clearTimer, fire, hasPending, getLastMs: () => lastMs };
}

function makeWatchdog(h: ReturnType<typeof harness>, timeoutMs = 1000): IdleWatchdog {
  return new IdleWatchdog({
    channel: h.channel,
    timeoutMs,
    setTimer: h.setTimer,
    clearTimer: h.clearTimer,
  });
}

describe('IdleWatchdog', () => {
  afterEach(() => setLocale('ko'));

  it('exports the 3-minute default timeout', () => {
    expect(IDLE_WATCHDOG_MS).toBe(3 * 60 * 1000);
  });

  it('arm + no activity + fire timer → one send with watchdog.idle content', async () => {
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    expect(h.hasPending()).toBe(true);
    expect(h.getLastMs()).toBe(50);
    await h.fire();
    expect(h.sent).toHaveLength(1);
    expect(h.sent[0]?.content).toBe(t('watchdog.idle'));
  });

  it('arm + noteActivity before fire → timer reset, no premature fire', async () => {
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    // Capture first callback, then noteActivity should replace it without sending.
    const firstPending = h.hasPending();
    expect(firstPending).toBe(true);
    w.noteActivity();
    expect(h.hasPending()).toBe(true);
    expect(h.sent).toHaveLength(0);
    // Only after the (reset) timer fires do we get a send.
    await h.fire();
    expect(h.sent).toHaveLength(1);
  });

  it('fires only once even if the timer callback re-triggers incorrectly', async () => {
    const h = harness();
    // Capture every scheduled callback so we can re-invoke the fired one.
    const callbacks: Array<() => void> = [];
    const w = new IdleWatchdog({
      channel: h.channel,
      timeoutMs: 50,
      setTimer: (fn) => {
        callbacks.push(fn);
        return callbacks.length;
      },
      clearTimer: () => {},
    });
    w.arm();
    expect(callbacks).toHaveLength(1);
    callbacks[0]!();
    await new Promise((r) => setImmediate(r));
    expect(h.sent).toHaveLength(1);
    // Re-invoke the same callback — must not send again.
    callbacks[0]!();
    await new Promise((r) => setImmediate(r));
    expect(h.sent).toHaveLength(1);
  });

  it('stop before fire → no send', async () => {
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    w.stop();
    expect(h.hasPending()).toBe(false);
    // Even if a stale callback somehow ran, stop disarmed so fire is a no-op —
    // but with our harness, clearTimer drops pending so fire does nothing.
    await h.fire();
    expect(h.sent).toHaveLength(0);
  });

  it('arm again after fire allows a second notification on next idle period', async () => {
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    await h.fire();
    expect(h.sent).toHaveLength(1);
    // Second turn: arm again; another idle period should notify once more.
    w.arm();
    expect(h.hasPending()).toBe(true);
    await h.fire();
    expect(h.sent).toHaveLength(2);
    expect(h.sent[1]?.content).toBe(t('watchdog.idle'));
  });

  it('noteActivity after fire is a no-op (no second timer until re-arm)', async () => {
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    await h.fire();
    expect(h.sent).toHaveLength(1);
    w.noteActivity();
    expect(h.hasPending()).toBe(false);
  });

  it('uses English string when locale is en', async () => {
    setLocale('en');
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    await h.fire();
    expect(h.sent[0]?.content).toBe(
      'No new activity for about 3 minutes. It may still be working on a long task, or it may have stalled. Check above in the channel and any threads, or ask the agent whether the work finished.',
    );
  });

  it('dispose stops the timer like stop', async () => {
    const h = harness();
    const w = makeWatchdog(h, 50);
    w.arm();
    w.dispose();
    await h.fire();
    expect(h.sent).toHaveLength(0);
  });
});
