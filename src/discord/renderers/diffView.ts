import type { AgentEvent } from '../../core/contracts.js';
import { chunkMessage } from '../format.js';
import type { TurnThreadHolder } from './turnThread.js';

// File-change diff view (§6, §5a — Claude, cap fileDiff): when a file-editing tool
// (Edit/Write/NotebookEdit) completes successfully, post a diff of the change into the
// turn's shared work thread. The diff must be built from the tool INPUT (old/new
// strings), which lives on the `tool_use` event, not the `tool_result` — so this
// handler tracks edit inputs by id and renders on the matching successful result
// (mirrors A4D's changeTracker → diffViewer flow). No discord.js: the sink is the
// MessageThread port (via TurnThreadHolder).

// The tools whose input this handler renders as a pretty diff. Exported so
// ToolThreadHandler skips their raw input (rendering it too would duplicate the change).
export const FILE_EDIT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit']);

interface EditInput {
  filePath: string;
  oldString?: string;
  newString?: string;
  content?: string;
}

export interface DiffViewDeps {
  thread: TurnThreadHolder;
}

export class DiffViewHandler {
  private readonly thread: TurnThreadHolder;
  // toolUseId → the edit input, kept until the matching result arrives.
  private readonly edits = new Map<string, EditInput>();

  constructor(deps: DiffViewDeps) {
    this.thread = deps.thread;
  }

  // Record a file-edit tool_use so its result can be diffed. Non-edit tools are
  // ignored (nothing tracked → nothing rendered).
  noteToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): void {
    if (!FILE_EDIT_TOOLS.has(ev.name)) return;
    const parsed = parseEditInput(ev.input);
    if (parsed) this.edits.set(ev.id, parsed);
  }

  // On a successful result for a tracked edit, post its diff. A failed result or an
  // untracked id renders nothing.
  async handleResult(ev: Extract<AgentEvent, { kind: 'tool_result' }>): Promise<void> {
    const edit = this.edits.get(ev.id);
    if (!edit) return;
    this.edits.delete(ev.id);
    if (!ev.ok) return;
    const diff = renderDiff(edit);
    if (!diff) return;
    const thread = await this.thread.get();
    for (const chunk of chunkMessage('```diff\n' + diff + '\n```')) {
      await thread.send({ content: chunk });
    }
  }
}

// Build a unified-ish diff body (no headers) from an edit input. Write/create with
// only `content` renders all lines as additions; an Edit renders old→new.
function renderDiff(edit: EditInput): string | null {
  const header = `--- ${edit.filePath}`;
  if (edit.oldString !== undefined || edit.newString !== undefined) {
    const removed = (edit.oldString ?? '').split('\n').map((l) => `- ${l}`);
    const added = (edit.newString ?? '').split('\n').map((l) => `+ ${l}`);
    return [header, ...removed, ...added].join('\n');
  }
  if (edit.content !== undefined) {
    const added = edit.content.split('\n').map((l) => `+ ${l}`);
    return [header, ...added].join('\n');
  }
  return null;
}

function parseEditInput(input: unknown): EditInput | null {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return null;
  const obj = input as Record<string, unknown>;
  const filePath = typeof obj.file_path === 'string' ? obj.file_path : undefined;
  if (!filePath) return null;
  const out: EditInput = { filePath };
  if (typeof obj.old_string === 'string') out.oldString = obj.old_string;
  if (typeof obj.new_string === 'string') out.newString = obj.new_string;
  if (typeof obj.content === 'string') out.content = obj.content;
  return out;
}
