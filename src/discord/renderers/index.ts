import type { AgentEvent, Capabilities } from '../../core/contracts.js';
import type { MessageChannel } from '../ports.js';
import type { EventBus } from '../../core/eventBus.js';
import type { UsageResult } from '../../core/usageService.js';
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
    }
  }
}

// Options for the default renderer set. `getUsage` supplies the latest UsageResult
// for the usage panel (7b/8 wires it to UsageService.getUsage; the poll trigger
// lives there, not here).
export interface DefaultRendererSetOptions {
  channel: MessageChannel;
  ownerId: string;
  // Returns the latest usage snapshot (or unavailable) at render time; may be null
  // until the poller has a value. Sync — the caller caches the last poll result.
  getUsage?: () => UsageResult | null;
}

// Wire the concrete handlers over one channel. Async handler work is fire-and-forget
// with a swallowed rejection so a rendering hiccup never breaks the event stream —
// the orchestrator's error events remain the user-visible failure signal.
export function createDefaultRendererSet(options: DefaultRendererSetOptions): RendererSet {
  const { channel, ownerId } = options;
  // `let`: finalize() permanently closes a StreamEmbedHandler, so one instance
  // serves exactly one turn — the result renderer swaps in fresh instances.
  let textStream = new StreamEmbedHandler({ channel, kind: 'text' });
  let thinkingStream = new StreamEmbedHandler({ channel, kind: 'thinking' });
  // Ended-but-still-finalizing handlers from a previous turn: dispose() must cancel
  // these too, or an armed debounce timer could fire a late send/edit after detach (§6).
  const endedStreams = new Set<StreamEmbedHandler>();
  const toolThread = new ToolThreadHandler({ channel });
  const permission = new PermissionButtonsHandler({ channel });
  const diff = new DiffViewHandler({ channel });
  const transcript = new TranscriptFeedHandler({ channel });
  const mention = new MentionOnCompleteHandler({ channel, ownerId });
  let lastCtxUsage: Extract<AgentEvent, { kind: 'context_usage' }> | null = null;
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
      textStream = new StreamEmbedHandler({ channel, kind: 'text' });
      thinkingStream = new StreamEmbedHandler({ channel, kind: 'thinking' });
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
      lastCtxUsage = ev;
      const usage = options.getUsage?.() ?? null;
      const embed = buildUsageEmbed(usage, lastCtxUsage);
      if (!embed) return;
      tail = tail.catch(() => {}).then(() => channel.send({ embeds: [embed] }));
      swallow(tail);
    },
    mention(ev) {
      tail = tail.catch(() => {}).then(() => mention.handle(ev));
      swallow(tail);
    },
    error(ev) {
      swallow(channel.send({ content: `⚠️ ${ev.message}` }));
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
