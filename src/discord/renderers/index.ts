import type { AgentEvent, Capabilities, Logger } from '../../core/contracts.js';
import type { MessageChannel } from '../ports.js';
import type { EventBus } from '../../core/eventBus.js';
import type { UsageResult, UsageSnapshot, UsageLimit } from '../../core/usageService.js';
import { StreamEmbedHandler } from './streamEmbed.js';
import { ToolThreadHandler } from './toolThread.js';
import { PermissionButtonsHandler } from './permissionButtons.js';
import { DiffViewHandler } from './diffView.js';
import { TranscriptFeedHandler } from './transcriptFeed.js';
import { MentionOnCompleteHandler } from './mentionOnComplete.js';
import { buildResultLine } from './resultLine.js';
import { buildUsageEmbed } from './usageEmbed.js';
import { chunkMessage } from '../format.js';

// The capability dispatcher (§6): subscribes a channel's AgentEvent stream and, for
// each event, invokes the matching renderer ONLY IF the mode's Capabilities flag is
// set — capability dispatch is the sole role of capabilities. Renderers are pure
// consumers of AgentEvent; none touches a backend.
//
// The renderer set is INJECTABLE (RendererSet) so tests assert "event kind ×
// capability → which renderer fired" with spies, and 7b can swap real handlers.
// createDefaultRendererSet wires the concrete handlers over a MessageChannel port.

// The set of renderer actions the dispatcher can invoke. Each is capability-gated
// by dispatch() below; a set may implement only the subset a test cares about.
export interface RendererSet {
  // caps: streaming (text) / thinking (thinking)
  stream(ev: Extract<AgentEvent, { kind: 'text' | 'thinking' }>): void;
  // A non-streaming backend's final text → plain channel message.
  plainText(ev: Extract<AgentEvent, { kind: 'text' }>): void;
  // caps: toolThreads
  toolThread(ev: Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>): void;
  // caps: fileDiff (tool_use tracked, diff rendered on tool_result)
  diff(ev: Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>): void;
  // caps: permissionPrompts
  permission(ev: Extract<AgentEvent, { kind: 'permission_request' }>): void;
  // caps: transcript / progress
  transcript(ev: Extract<AgentEvent, { kind: 'progress' | 'result' }>): void;
  // Always: the done-line (cap-aware fields inside).
  result(ev: Extract<AgentEvent, { kind: 'result' }>): void;
  // caps: usagePanel
  usage(ev: Extract<AgentEvent, { kind: 'context_usage' }>): void;
  // Always: @mention the owner on completion.
  mention(ev: Extract<AgentEvent, { kind: 'result' }>): void;
  // Always: surface an error.
  error(ev: Extract<AgentEvent, { kind: 'error' }>): void;
  // Always: surface a rate-limit update (usage %, reset time) — NOT an error.
  rateLimit(ev: Extract<AgentEvent, { kind: 'rate_limit' }>): void;
  // Tear down any armed timers (stream/thinking debounce) so a detach mid-stream
  // cannot fire a late send/edit or leave an orphan "Responding…" embed. Called by
  // the wiring layer on detach, after unsubscribe. Optional so a partial spy set
  // used in a dispatch test need not implement it.
  dispose?(): void;
}

export class RendererDispatcher {
  constructor(
    private readonly renderers: RendererSet,
    private readonly capabilities: Capabilities,
  ) {}

  // Subscribe this dispatcher to a channel's event stream. Returns the unsubscribe.
  subscribe(bus: EventBus, guildId: string, channelId: string): () => void {
    return bus.on(guildId, channelId, (ev) => this.dispatch(ev));
  }

  // Capability-gated dispatch. This is the ONE place capabilities decide which
  // renderer fires. A backend that lacks a capability simply has that path skipped;
  // for text specifically, a non-streaming backend routes the final text to a plain
  // message and progress to the transcript feed (Codex degraded UX, §5c).
  dispatch(ev: AgentEvent): void {
    const caps = this.capabilities;
    switch (ev.kind) {
      case 'text':
        if (caps.streaming) this.renderers.stream(ev);
        else this.renderers.plainText(ev);
        break;
      case 'thinking':
        if (caps.thinking) this.renderers.stream(ev);
        break;
      case 'tool_use':
      case 'tool_result':
        if (caps.toolThreads) this.renderers.toolThread(ev);
        if (caps.fileDiff) this.renderers.diff(ev);
        break;
      case 'permission_request':
        if (caps.permissionPrompts) this.renderers.permission(ev);
        break;
      case 'progress':
        if (caps.progress || caps.transcript) this.renderers.transcript(ev);
        break;
      case 'result':
        // Non-streaming/transcript backends post their final text via the feed.
        if (!caps.streaming && (caps.transcript || caps.progress)) this.renderers.transcript(ev);
        this.renderers.result(ev);
        this.renderers.mention(ev);
        break;
      case 'context_usage':
        if (caps.usagePanel) this.renderers.usage(ev);
        break;
      case 'error':
        this.renderers.error(ev);
        break;
      case 'rate_limit':
        this.renderers.rateLimit(ev);
        break;
    }
  }
}

// Options for the default renderer set. `getUsage` supplies the latest UsageResult
// for the usage panel (7b/8 wires it to UsageService.getUsage).
export interface DefaultRendererSetOptions {
  channel: MessageChannel;
  ownerId: string;
  // Returns the latest usage snapshot (or unavailable) at render time; may be null
  // when usage is not yet known. Sync or async — the callee fetches fresh each call
  // (UsageService's own TTL coalesces rapid re-reads), so the panel reflects the
  // current turn rather than an attach-time snapshot.
  getUsage?: () => UsageResult | null | Promise<UsageResult | null>;
  // Optional: threaded into each StreamEmbedHandler so a swallowed best-effort preview
  // failure (deleted channel race / REST timeout) is debug-logged rather than silent.
  logger?: Logger;
}

// Wire the concrete handlers over one channel. Async handler work is fire-and-forget
// with a swallowed rejection so a rendering hiccup never breaks the event stream —
// the orchestrator's error events remain the user-visible failure signal.
export function createDefaultRendererSet(options: DefaultRendererSetOptions): RendererSet {
  const { channel, ownerId, logger } = options;
  // `let`: finalize() permanently closes a StreamEmbedHandler, so one instance
  // serves exactly one turn — the result renderer swaps in fresh instances.
  let textStream = new StreamEmbedHandler({ channel, kind: 'text', logger });
  let thinkingStream = new StreamEmbedHandler({ channel, kind: 'thinking', logger });
  // Ended-but-still-finalizing handlers from a previous turn: dispose() must cancel
  // these too, or an armed debounce timer could fire a late send/edit after detach (§6).
  const endedStreams = new Set<StreamEmbedHandler>();
  const toolThread = new ToolThreadHandler({ channel });
  const permission = new PermissionButtonsHandler({ channel });
  const diff = new DiffViewHandler({ channel });
  const transcript = new TranscriptFeedHandler({ channel });
  const mention = new MentionOnCompleteHandler({ channel, ownerId });
  // Serializes the turn's terminal sends (done-line, mention, usage panel) BEHIND the
  // stream's finalized answer chunks, so none of them ever lands mid-answer. Each link
  // settles and is GC'd once done; only the latest reference is held, so no leak.
  let tail: Promise<unknown> = Promise.resolve();

  const swallow = (p: Promise<unknown>) => {
    void p.catch(() => {});
  };

  return {
    stream(ev) {
      if (ev.kind === 'thinking') thinkingStream.push(ev);
      else textStream.push(ev);
    },
    plainText(ev) {
      // Non-streaming backends (Codex) deliver the whole answer in one text event.
      // Split to Discord's 2000-char limit or the send is rejected and swallowed —
      // same chunking the transcript feed uses. Empty text → chunkMessage returns [].
      for (const chunk of chunkMessage(ev.text)) {
        swallow(channel.send({ content: chunk }));
      }
    },
    toolThread(ev) {
      swallow(toolThread.handle(ev));
    },
    diff(ev) {
      if (ev.kind === 'tool_use') diff.noteToolUse(ev);
      else swallow(diff.handleResult(ev));
    },
    permission(ev) {
      // The dispatcher path posts the buttons; the returned promise is resolved by
      // the orchestrator's requestPermission hookup (7b). Here we just surface them.
      swallow(permission.request(ev));
    },
    transcript(ev) {
      swallow(transcript.handle(ev));
    },
    result(ev) {
      // Finalize any open text stream, then post the done-line AFTER it via the shared
      // `tail` so the done-line (and the mention/usage that chain behind it) never lands
      // in the middle of a multi-chunk answer. The `.catch()` before the done-line link
      // keeps a finalize-chain error from dropping the done-line.
      // Fallback: if the stream never emitted (no text deltas arrived — e.g. Claude
      // Code result-only path), post ev.text as plain chunked messages so the user
      // sees the answer instead of a lone done-line.
      // Swap in fresh handlers for the next turn SYNCHRONOUSLY before the async
      // finalize below: a next-turn delta arriving mid-finalize would otherwise
      // hit the already-finalized instance and be dropped. The fallback decision
      // reads the ended instance, so it reflects this turn only.
      const endedText = textStream;
      const endedThinking = thinkingStream;
      endedStreams.add(endedText);
      endedStreams.add(endedThinking);
      textStream = new StreamEmbedHandler({ channel, kind: 'text', logger });
      thinkingStream = new StreamEmbedHandler({ channel, kind: 'thinking', logger });
      const finalized = endedText
        .finalize()
        .then(() => endedThinking.finalize())
        .then(async () => {
          if (!endedText.hasEmitted() && typeof ev.text === 'string' && ev.text.length > 0) {
            for (const chunk of chunkMessage(ev.text)) {
              await channel.send({ content: chunk });
            }
          }
        })
        .finally(() => {
          endedStreams.delete(endedText);
          endedStreams.delete(endedThinking);
        });
      const line = buildResultLine(ev);
      tail = finalized.catch(() => {}).then(() => (line ? channel.send({ content: line }) : undefined));
      swallow(tail);
    },
    usage(ev) {
      // Capture this turn's context event: getUsage is now awaited inside the tail
      // chain, so a subsequent turn's usage event must not mutate what this send renders.
      const ctx = ev;
      tail = tail.catch(() => {}).then(async () => {
        const usage = (await options.getUsage?.()) ?? null;
        const embed = buildUsageEmbed(usage, ctx);
        if (embed) await channel.send({ embeds: [embed] });
      });
      swallow(tail);
    },
    mention(ev) {
      tail = tail.catch(() => {}).then(() => mention.handle(ev));
      swallow(tail);
    },
    error(ev) {
      swallow(channel.send({ content: `⚠️ ${ev.message}` }));
    },
    rateLimit(ev) {
      // Pass the latest usage snapshot so a %-less rate_limit event still shows the
      // utilization for its window (backfilled from the snapshot). getUsage may be async,
      // so await it in a self-invoking wrapper; the send stays immediate (not on tail).
      swallow(
        (async () => {
          const usage = (await options.getUsage?.()) ?? null;
          return channel.send({ content: formatRateLimitLine(ev, usage) });
        })(),
      );
    },
    dispose() {
      // Cancel the streaming/thinking debounce timers so a detach mid-stream cannot
      // fire a late edit/send against a channel that is being torn down. Ended
      // handlers whose finalize chain is still in flight are cancelled too: cancel()
      // is idempotent and turns the pending finalize into a no-op.
      for (const s of endedStreams) s.cancel();
      endedStreams.clear();
      textStream.cancel();
      thinkingStream.cancel();
    },
  };
}

// Re-export the permission handler for 7b to wire orchestrator.requestPermission
// and button-interaction resolution (the request/resolve round-trip lives there).
export { PermissionButtonsHandler } from './permissionButtons.js';

// Human-readable label for the SDK's rateLimitType codes. Unknown types pass through
// verbatim so a future SDK addition still renders something (not silently dropped).
export function rateLimitTypeLabel(type: string): string {
  switch (type) {
    case 'five_hour':
      return '5시간 한도';
    case 'seven_day':
      return '주간 한도';
    case 'seven_day_opus':
      return '주간 한도 (Opus)';
    case 'seven_day_sonnet':
      return '주간 한도 (Sonnet)';
    case 'overage':
      return '추가 사용량';
    default:
      return type; // unknown/future type → render verbatim rather than drop it
  }
}

// A UsageResult is a snapshot only when it is not the {available:false} unavailable
// marker (which is the sole member carrying an `available` field).
export function isUsageSnapshot(usage: UsageResult | null | undefined): usage is UsageSnapshot {
  return !!usage && !('available' in usage);
}

// Format a window's reset time: HH:mm when it falls today, else M/D HH:mm (ko-KR, 24h).
// Returns null when absent/unparseable so the caller drops the reset parenthetical.
function formatResetTime(resetsAt: string | undefined): string | null {
  if (!resetsAt) return null;
  const ms = Date.parse(resetsAt);
  if (Number.isNaN(ms)) return null;
  const d = new Date(ms);
  const now = new Date();
  const hhmm = d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false });
  const sameDay =
    d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  return sameDay ? hhmm : `${d.getMonth() + 1}/${d.getDate()} ${hhmm}`;
}

// Render every present usage window as `라벨 {util}% (리셋 …)` segments joined by ' · ',
// or null when there is no snapshot / no window to show. Shared by the rate-limit alert
// (renderers) and the status-channel notifier so both read identically.
export function formatUsageWindows(usage: UsageResult | null): string | null {
  if (!isUsageSnapshot(usage)) return null;
  const segments: string[] = [];
  const add = (limit: UsageLimit | undefined, label: string): void => {
    if (!limit) return;
    const reset = formatResetTime(limit.resetsAt);
    segments.push(`${label} ${Math.round(limit.utilization)}%${reset ? ` (리셋 ${reset})` : ''}`);
  };
  add(usage.fiveHour, '5시간');
  add(usage.sevenDay, '주간');
  add(usage.sevenDayOpus, '주간(Opus)');
  add(usage.sevenDaySonnet, '주간(Sonnet)');
  return segments.length > 0 ? segments.join(' · ') : null;
}

// One-line summary of a rate_limit event. When a usage snapshot is available, show ALL
// windows with their resets (the full picture, independent of the event's own type/util
// — those are usually empty). Otherwise (API-key / non-macOS / no data yet) fall back to
// the event's own label + utilization + reset. Kept as a plain function (not on
// RendererSet) so the notifier path reuses the same phrasing.
export function formatRateLimitLine(
  ev: Extract<AgentEvent, { kind: 'rate_limit' }>,
  usage?: UsageResult | null,
): string {
  const windows = formatUsageWindows(usage ?? null);
  if (windows) return `📊 사용량 한도 알림 · ${windows}`;

  let line = '📊 사용량 한도 알림';
  if (ev.rateLimitType) line += ` · ${rateLimitTypeLabel(ev.rateLimitType)}`;
  if (typeof ev.utilization === 'number') line += ` · 사용량 ${Math.round(ev.utilization)}%`;
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
