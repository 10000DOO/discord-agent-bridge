import type { AgentEvent } from '../../core/contracts.js';
import type { EditableMessage, MessageChannel } from '../ports.js';
import { COLORS, EMBED_DESC_LIMIT, chunkMessage, truncate } from '../format.js';
import { t } from '../i18n.js';

// Live text/thinking embeds, debounced edit then finalize to chunked text (§6).
// Ports A4D StreamHandler behavior: accumulate deltas into a buffer, edit a single
// "Responding…"/"Thinking…" embed on a debounce, and on finalize replace it with
// the plain chunked text (text) or a collapsed "Thought for Ns" embed (thinking).
//
// Injectable timer + clock so tests advance time deterministically without real
// setTimeout. No discord.js: the sink is the MessageChannel port. One handler
// instance per (channel, kind); the dispatcher owns their lifecycle.

// Debounce defaults (A4D: 1s text, 2s thinking).
const TEXT_DEBOUNCE_MS = 1000;
const THINKING_DEBOUNCE_MS = 2000;

export interface StreamEmbedDeps {
  channel: MessageChannel;
  kind: 'text' | 'thinking';
  debounceMs?: number;
  // Injectable timer (default: setTimeout/clearTimeout) so tests fire the flush
  // synchronously. setTimer returns an opaque handle passed back to clearTimer.
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  now?: () => number;
}

export class StreamEmbedHandler {
  private readonly channel: MessageChannel;
  private readonly kind: 'text' | 'thinking';
  private readonly debounceMs: number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;
  private readonly now: () => number;

  private buffer = '';
  private deltaCount = 0;
  private startedAt: number | null = null;
  private timer: unknown = null;
  private message: EditableMessage | null = null;
  // Serializes edits so a flush never overtakes a still-in-flight previous edit.
  private inflight: Promise<void> = Promise.resolve();
  private finalized = false;

  constructor(deps: StreamEmbedDeps) {
    this.channel = deps.channel;
    this.kind = deps.kind;
    this.debounceMs =
      deps.debounceMs ?? (deps.kind === 'thinking' ? THINKING_DEBOUNCE_MS : TEXT_DEBOUNCE_MS);
    this.setTimer = deps.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
    this.now = deps.now ?? Date.now;
  }

  // Accumulate one delta and (re)arm the debounce timer. delta:false is treated as
  // a full-text push (still buffered, then finalized by the dispatcher on result).
  push(ev: Extract<AgentEvent, { kind: 'text' | 'thinking' }>): void {
    if (this.finalized) return;
    if (this.startedAt === null) this.startedAt = this.now();
    this.buffer += ev.text;
    this.deltaCount += 1;
    this.arm();
  }

  private arm(): void {
    if (this.timer !== null) this.clearTimer(this.timer);
    this.timer = this.setTimer(() => {
      this.timer = null;
      void this.flush();
    }, this.debounceMs);
  }

  // Upsert the live embed with the current buffer preview.
  private flush(): Promise<void> {
    this.inflight = this.inflight.then(async () => {
      if (this.finalized || this.buffer.length === 0) return;
      const desc = truncate(this.buffer, EMBED_DESC_LIMIT);
      const title = this.kind === 'thinking' ? t('stream.thinking') : t('stream.responding');
      const color = this.kind === 'thinking' ? COLORS.thinking : COLORS.streaming;
      const embed = { title, description: desc, color, footer: this.footer() };
      if (this.message) {
        await this.message.edit({ embeds: [embed] });
      } else {
        this.message = await this.channel.send({ embeds: [embed] });
      }
    });
    return this.inflight;
  }

  // Finalize the stream: cancel the timer, then for text replace the live embed
  // with the plain chunked message(s); for thinking collapse to a "Thought for Ns"
  // embed. Idempotent — a second call is a no-op.
  async finalize(): Promise<void> {
    if (this.finalized) return;
    this.finalized = true;
    if (this.timer !== null) {
      this.clearTimer(this.timer);
      this.timer = null;
    }
    await this.inflight;
    if (this.buffer.length === 0) return;

    if (this.kind === 'thinking') {
      const sec = this.elapsedSec();
      const embed = { title: t('stream.thought', { sec }), color: COLORS.thinking };
      if (this.message) await this.message.edit({ embeds: [embed] });
      else await this.channel.send({ embeds: [embed] });
      return;
    }

    // Text: post the full answer as plain chunked message(s). Edit the first chunk
    // into the live embed's message (replacing the streaming embed) and send the
    // remainder as follow-ups.
    const chunks = chunkMessage(this.buffer);
    const [first, ...rest] = chunks;
    if (this.message) {
      await this.message.edit({ content: first, embeds: [] });
    } else {
      await this.channel.send({ content: first });
    }
    for (const chunk of rest) {
      await this.channel.send({ content: chunk });
    }
  }

  private footer(): string {
    const sec = this.elapsedSec();
    return `${sec}s · ${this.deltaCount}`;
  }

  private elapsedSec(): string {
    if (this.startedAt === null) return '0.0';
    return ((this.now() - this.startedAt) / 1000).toFixed(1);
  }
}
