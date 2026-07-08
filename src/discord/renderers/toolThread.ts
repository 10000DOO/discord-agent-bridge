import type { AgentEvent } from '../../core/contracts.js';
import type { MessageThread } from '../ports.js';
import { chunkMessage, toolThreadName } from '../format.js';
import { t } from '../i18n.js';
import { FILE_EDIT_TOOLS } from './diffView.js';
import type { TurnThreadHolder } from './turnThread.js';

// Tool-activity feed (§6): every tool_use/tool_result of a turn is written into that
// turn's ONE shared work thread (TurnThreadHolder), not a thread per tool. Because a
// single thread can't identify a tool by its name, each post carries an inline header:
// a tool-summary header before the input, and the result/error header before the result.
// A `toolUseId → name` map lets a result name its tool. A result that arrives before the
// thread exists (out-of-order delivery, first tool_use not seen yet) is buffered and
// flushed when the thread opens.
//
// Edit/Write/NotebookEdit render as a pretty diff (DiffViewHandler) into the SAME thread,
// so this handler skips their raw input to avoid showing the change twice; their result
// header is still posted here so success/failure stays visible.
//
// No discord.js: the sink is the MessageThread port (via TurnThreadHolder). The dispatcher
// routes tool_use / tool_result events here when the toolThreads cap is set.

export interface ToolThreadDeps {
  thread: TurnThreadHolder;
}

interface PendingResult {
  id: string;
  ok: boolean;
  content: string;
}

export class ToolThreadHandler {
  private readonly thread: TurnThreadHolder;
  // toolUseId → tool name, so a result can name its tool in the header.
  private readonly toolNames = new Map<string, string>();
  // Results that arrived before the shared thread was opened (out-of-order delivery).
  // Flushed once the first tool_use opens the thread.
  private pending: PendingResult[] = [];

  constructor(deps: ToolThreadDeps) {
    this.thread = deps.thread;
  }

  async handle(ev: Extract<AgentEvent, { kind: 'tool_use' | 'tool_result' }>): Promise<void> {
    if (ev.kind === 'tool_use') return this.onToolUse(ev);
    return this.onToolResult(ev);
  }

  // Turn boundary: clear turn-local state alongside TurnThreadHolder.reset(). Drops any
  // buffered result that never found its thread (so it can't misfire into the next turn's
  // thread) and the toolUseId→name map (so a long session doesn't grow it unbounded).
  resetTurn(): void {
    this.pending = [];
    this.toolNames.clear();
  }

  private async onToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): Promise<void> {
    this.toolNames.set(ev.id, ev.name);
    const thread = await this.thread.get();
    // Edit/Write/NotebookEdit are rendered as a diff by DiffViewHandler — skip their raw
    // input here so the same change isn't shown twice in the thread. This dedup assumes
    // DiffViewHandler actually runs, which holds only when the toolThreads AND fileDiff
    // caps are both on (the pairing this renderer set is wired for — see index.ts dispatch).
    if (!FILE_EDIT_TOOLS.has(ev.name)) {
      const header = `**${toolThreadName(ev.name, ev.input)}**`;
      for (const chunk of chunkMessage(`${header}\n${formatInput(ev.input)}`)) {
        await thread.send({ content: chunk });
      }
    }
    // Flush any results that raced ahead of the thread.
    if (this.pending.length > 0) {
      const buffered = this.pending;
      this.pending = [];
      for (const r of buffered) await this.postResult(thread, r);
    }
  }

  private async onToolResult(ev: Extract<AgentEvent, { kind: 'tool_result' }>): Promise<void> {
    const result: PendingResult = { id: ev.id, ok: ev.ok, content: ev.content };
    if (this.thread.opened) {
      const thread = await this.thread.get();
      await this.postResult(thread, result);
      return;
    }
    // No shared thread yet (result before the first tool_use) — buffer until it opens.
    this.pending.push(result);
  }

  private async postResult(thread: MessageThread, r: PendingResult): Promise<void> {
    const name = this.toolNames.get(r.id);
    const label = r.ok ? t('tool.result') : t('tool.error');
    const header = name ? `**${name} · ${label}**` : `**${label}**`;
    for (const chunk of chunkMessage(`${header}\n${r.content}`)) {
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
