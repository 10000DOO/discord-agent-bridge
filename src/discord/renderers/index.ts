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
  const textStream = new StreamEmbedHandler({ channel, kind: 'text' });
  const thinkingStream = new StreamEmbedHandler({ channel, kind: 'thinking' });
  const toolThread = new ToolThreadHandler({ channel });
  const permission = new PermissionButtonsHandler({ channel });
  const diff = new DiffViewHandler({ channel });
  const transcript = new TranscriptFeedHandler({ channel });
  const mention = new MentionOnCompleteHandler({ channel, ownerId });
  let lastCtxUsage: Extract<AgentEvent, { kind: 'context_usage' }> | null = null;

  const swallow = (p: Promise<unknown>) => {
    void p.catch(() => {});
  };

  return {
    stream(ev) {
      if (ev.kind === 'thinking') thinkingStream.push(ev);
      else textStream.push(ev);
    },
    plainText(ev) {
      swallow(channel.send({ content: ev.text }));
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
      // Finalize any open text stream before the done-line, so the answer lands first.
      swallow(textStream.finalize().then(() => thinkingStream.finalize()));
      const line = buildResultLine(ev);
      if (line) swallow(channel.send({ content: line }));
    },
    usage(ev) {
      lastCtxUsage = ev;
      const usage = options.getUsage?.() ?? null;
      const embed = buildUsageEmbed(usage, lastCtxUsage);
      if (embed) swallow(channel.send({ embeds: [embed] }));
    },
    mention(ev) {
      swallow(mention.handle(ev));
    },
    error(ev) {
      swallow(channel.send({ content: `⚠️ ${ev.message}` }));
    },
  };
}

// Re-export the permission handler for 7b to wire orchestrator.requestPermission
// and button-interaction resolution (the request/resolve round-trip lives there).
export { PermissionButtonsHandler } from './permissionButtons.js';
