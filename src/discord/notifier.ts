import type { AgentEvent } from '../core/contracts.js';
import type { EventBus } from '../core/eventBus.js';
import type { ServerConfig } from '../core/configSchema.js';
import type { MessageChannel } from './ports.js';

// Per-guild event notifier: forwards key AgentEvents (result, error; tool_use only when
// enabled) from a session channel to ONE per-guild status channel as compact, one-line
// summaries. It is a pure consumer of the event stream (like the renderers): the wiring
// layer resolves the status channel + the guild's notifications config and hands both in,
// then subscribes this to the eventBus for a session channel and stores the unsubscribe.
//
// discord.js never appears here — the status channel is a MessageChannel port, resolved
// by the wiring layer via the same resolveChannel seam the renderers use.

// The resolved notifications config (defaults applied). channelId is the resolved status
// channel id (falls back to channels.statusChannelId upstream); it is not read here — the
// wiring layer resolves it to a MessageChannel before constructing the notifier.
export interface ResolvedNotifications {
  enabled: boolean;
  channelId: string | null;
  events: { result: boolean; error: boolean; toolUse: boolean };
}

// Resolve a guild's per-server notifications block to the effective config, applying the
// defaults: enabled=true; channelId falls back to channels.statusChannelId when null/
// absent; events = {result:true, error:true, toolUse:false}. Kept here so the wiring layer
// and tests resolve identically.
export function resolveNotifications(server: ServerConfig | null): ResolvedNotifications {
  const n = server?.notifications;
  const statusFallback = server?.channels?.statusChannelId ?? null;
  return {
    enabled: n?.enabled ?? true,
    channelId: n?.channelId ?? statusFallback,
    events: {
      result: n?.events?.result ?? true,
      error: n?.events?.error ?? true,
      toolUse: n?.events?.toolUse ?? false,
    },
  };
}

// Build the compact one-line summary for an event, or null when this event kind is
// not forwarded (filtered off by config, or a kind we do not summarize). Korean,
// one line each, linking back to the SESSION channel it came from.
export function formatNotification(
  ev: AgentEvent,
  sessionChannelId: string,
  events: ResolvedNotifications['events'],
): string | null {
  switch (ev.kind) {
    case 'result': {
      if (!events.result) return null;
      let line = `✅ <#${sessionChannelId}> 완료`;
      if (ev.tokensIn !== undefined && ev.tokensOut !== undefined) {
        line += ` · ${ev.tokensIn}/${ev.tokensOut} tok`;
      }
      if (ev.durationMs !== undefined) line += ` · ${ev.durationMs}ms`;
      if (ev.costUsd !== undefined) line += ` · $${ev.costUsd}`;
      return line;
    }
    case 'error': {
      if (!events.error) return null;
      return `❌ <#${sessionChannelId}> 에러: ${ev.message.slice(0, 500)}`;
    }
    case 'rate_limit': {
      // Gated by events.error (per minimal-change guidance): a rate-limit update is
      // not an error semantically, but it's operational status of the same "something
      // to be aware of" kind, and adding a new filter here would ripple into config
      // schema / defaults. If differentiation is needed later, split the flag.
      if (!events.error) return null;
      let line = `📊 <#${sessionChannelId}> 사용량 한도`;
      if (typeof ev.utilization === 'number') line += ` · ${Math.round(ev.utilization)}%`;
      if (ev.resetAt) {
        const ms = Date.parse(ev.resetAt);
        if (!Number.isNaN(ms)) {
          const hhmm = new Date(ms).toLocaleTimeString('ko-KR', {
            hour: '2-digit',
            minute: '2-digit',
            hour12: false,
          });
          line += ` · 리셋 ${hhmm}`;
        }
      }
      return line;
    }
    case 'tool_use': {
      if (!events.toolUse) return null;
      return `🔧 <#${sessionChannelId}> ${ev.name}`;
    }
    default:
      return null;
  }
}

export interface SessionNotifierOptions {
  // The resolved status channel sink (resolved by the wiring layer).
  statusChannel: MessageChannel;
  // The session channel these events belong to (linked in the summary line).
  sessionChannelId: string;
  // The resolved event filter (which kinds to forward).
  events: ResolvedNotifications['events'];
}

// One session's notification forwarder. On each AgentEvent, formats a summary line
// (filtered by config) and posts it to the status channel. Posting is fire-and-forget
// with a swallowed rejection so a status-channel hiccup never breaks the event stream —
// exactly like the renderer set.
export class SessionNotifier {
  constructor(private readonly opts: SessionNotifierOptions) {}

  // Subscribe to a session channel's event stream. Returns the unsubscribe function
  // (stored by the wiring layer, called on detach).
  subscribe(bus: EventBus, guildId: string, channelId: string): () => void {
    return bus.on(guildId, channelId, (ev) => this.notify(ev));
  }

  private notify(ev: AgentEvent): void {
    const line = formatNotification(ev, this.opts.sessionChannelId, this.opts.events);
    if (line === null) return;
    void this.opts.statusChannel.send({ content: line }).catch(() => {});
  }
}
