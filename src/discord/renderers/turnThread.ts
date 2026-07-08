import type { MessageChannel, MessageThread } from '../ports.js';

// The per-turn work thread shared by the tool-activity renderers (§6). One turn opens
// exactly ONE thread the first time any tool activity happens, and every later tool
// input/result/diff appends to that SAME thread — so a tool-heavy turn no longer floods
// the channel with a thread per tool.
//
// Concurrency: dispatch() invokes toolThread and diff synchronously back-to-back and
// both handlers are async, so their first accesses can race. get() caches the in-flight
// startThread PROMISE and hands the same one to every concurrent caller, so the thread
// is created exactly once. A failed open clears the cache so the next tool activity can
// retry rather than poisoning the whole turn.
//
// No discord.js: the sink is the MessageChannel port. Injected into both ToolThreadHandler
// and DiffViewHandler so they post into the identical thread.

export interface TurnThreadDeps {
  channel: MessageChannel;
  name: string;
}

export class TurnThreadHolder {
  private readonly channel: MessageChannel;
  private readonly name: string;
  // The in-flight-or-settled creation promise for this turn's thread; null until the
  // first get() and again after reset() (turn boundary).
  private creating: Promise<MessageThread> | null = null;

  constructor(deps: TurnThreadDeps) {
    this.channel = deps.channel;
    this.name = deps.name;
  }

  // Open (once) or return this turn's shared thread. Concurrent first callers share the
  // single in-flight promise, so exactly one thread is created.
  get(): Promise<MessageThread> {
    if (!this.creating) {
      const attempt: Promise<MessageThread> = this.channel.startThread(this.name).catch((err) => {
        // A failed open must not poison the turn: drop the cache so the next tool
        // activity retries, but rethrow so this caller still sees the failure. Guard on
        // identity — a late rejection from a PREVIOUS turn's attempt (reset() already
        // cleared it, a new turn set a live promise) must not clear the current turn's
        // creation, which would let it open twice.
        if (this.creating === attempt) this.creating = null;
        throw err;
      });
      this.creating = attempt;
    }
    return this.creating;
  }

  // Whether the thread has been opened (or started opening) this turn. ToolThreadHandler
  // reads this to decide whether an early tool_result can post now or must be buffered.
  get opened(): boolean {
    return this.creating !== null;
  }

  // Turn boundary: drop the reference so the next turn opens a fresh thread. An in-flight
  // fire-and-forget send from the old turn already captured its thread and completes
  // safely. A turn with no tool activity never called get(), so this is a no-op.
  reset(): void {
    this.creating = null;
  }
}
