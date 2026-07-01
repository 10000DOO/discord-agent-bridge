import type { AgentEvent } from './contracts.js';

// Typed per-channel pub/sub of AgentEvent (§4, §6). Listeners are keyed by
// "<guildId>:<channelId>" so a channel only ever sees its own events — no
// cross-channel leakage. Kept dependency-light: a Map of listener Sets, not
// Node's EventEmitter (avoids its max-listener warnings and string-keyed API).
export type AgentEventListener = (ev: AgentEvent) => void;

function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

export class EventBus {
  // key "<guildId>:<channelId>" → set of listeners for that channel.
  private readonly listeners = new Map<string, Set<AgentEventListener>>();

  // Subscribe to one channel's event stream. Returns an unsubscribe function;
  // calling it is equivalent to off(guildId, channelId, listener).
  on(guildId: string, channelId: string, listener: AgentEventListener): () => void {
    const key = channelKey(guildId, channelId);
    let set = this.listeners.get(key);
    if (!set) {
      set = new Set();
      this.listeners.set(key, set);
    }
    set.add(listener);
    return () => this.off(guildId, channelId, listener);
  }

  // Remove a previously registered listener. No-op if it was never registered.
  // Drops the channel's set once empty so the map does not grow unbounded.
  off(guildId: string, channelId: string, listener: AgentEventListener): void {
    const key = channelKey(guildId, channelId);
    const set = this.listeners.get(key);
    if (!set) return;
    set.delete(listener);
    if (set.size === 0) {
      this.listeners.delete(key);
    }
  }

  // Deliver an event to exactly the listeners of the given channel. Iterating a
  // snapshot lets a listener safely off() itself (or others) during dispatch.
  emit(guildId: string, channelId: string, ev: AgentEvent): void {
    const set = this.listeners.get(channelKey(guildId, channelId));
    if (!set) return;
    for (const listener of [...set]) {
      listener(ev);
    }
  }
}
