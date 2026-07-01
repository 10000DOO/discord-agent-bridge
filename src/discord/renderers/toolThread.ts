import type { AgentEvent } from '../../core/contracts.js';
import type { MessageChannel, MessageThread } from '../ports.js';
import { chunkMessage, toolThreadName } from '../format.js';
import { t } from '../i18n.js';

// Per-tool threads (§6): a tool_use opens a thread named from tool+input and posts
// the input; the matching tool_result (by id) posts back into that thread. A result
// that arrives before its thread is registered is buffered and flushed on open, so
// out-of-order delivery never drops a result (ports A4D's pendingResults map).
//
// No discord.js: the sink is the MessageChannel port. One handler per channel; the
// dispatcher routes tool_use / tool_result events here when the toolThreads cap is set.

export interface ToolThreadDeps {
  channel: MessageChannel;
}

interface PendingResult {
  ok: boolean;
  content: string;
}

export class ToolThreadHandler {
  private readonly channel: MessageChannel;
  // toolUseId → its thread, once opened.
  private readonly threads = new Map<string, MessageThread>();
  // toolUseId → results that arrived before the thread was registered.
  private readonly pending = new Map<string, PendingResult[]>();

  constructor(deps: ToolThreadDeps) {
    this.channel = deps.channel;
  }

  async handle(ev: Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>): Promise<void> {
    if (ev.kind === 'tool_use') return this.onToolUse(ev);
    return this.onToolResult(ev);
  }

  private async onToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): Promise<void> {
    const thread = await this.channel.startThread(toolThreadName(ev.name, ev.input));
    this.threads.set(ev.id, thread);
    // Post the input as the thread's opening message.
    for (const chunk of chunkMessage(formatInput(ev.input))) {
      await thread.send({ content: chunk });
    }
    // Flush any results that raced ahead of the thread.
    const buffered = this.pending.get(ev.id);
    if (buffered) {
      this.pending.delete(ev.id);
      for (const r of buffered) await this.postResult(thread, r);
    }
  }

  private async onToolResult(ev: Extract<AgentEvent, { kind: 'tool_result' }>): Promise<void> {
    const thread = this.threads.get(ev.id);
    const result: PendingResult = { ok: ev.ok, content: ev.content };
    if (thread) {
      await this.postResult(thread, result);
      return;
    }
    // Thread not open yet — buffer until onToolUse registers it.
    const list = this.pending.get(ev.id) ?? [];
    list.push(result);
    this.pending.set(ev.id, list);
  }

  private async postResult(thread: MessageThread, r: PendingResult): Promise<void> {
    const header = r.ok ? `**${t('tool.result')}**` : `**${t('tool.error')}**`;
    const body = `${header}\n${r.content}`;
    for (const chunk of chunkMessage(body)) {
      await thread.send({ content: chunk });
    }
  }
}

// Format tool input for the thread's opening message. Plain JSON pretty-print keeps
// this mode-agnostic; per-tool prettifying (diff blocks, code fences) is the
// diffView renderer's job, not this one.
function formatInput(input: unknown): string {
  if (typeof input === 'string') return input;
  try {
    return '```json\n' + JSON.stringify(input, null, 2) + '\n```';
  } catch {
    return String(input);
  }
}
