import { describe, it, expect } from 'vitest';
import { TurnThreadHolder } from './turnThread.js';
import type { MessageChannel, MessageThread } from '../ports.js';

// A channel whose startThread counts calls and can be made to fail once, so the
// holder's create-once and retry-after-failure guarantees are observable.
function fakeChannel(opts: { failTimes?: number } = {}) {
  let creates = 0;
  let failsLeft = opts.failTimes ?? 0;
  const channel: MessageChannel = {
    async send() {
      throw new Error('unused');
    },
    async startThread() {
      creates += 1;
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
  return { channel, creates: () => creates };
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
