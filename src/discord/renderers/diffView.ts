import type { AgentEvent } from '../../core/contracts.js';
import { chunkMessage } from '../format.js';
import type { TurnThreadRegistry } from './turnThread.js';

// File-change diff view (§6, §5a — Claude, cap fileDiff): when a file-editing tool
// (Edit/Write/NotebookEdit) completes successfully, post a diff of the change into the
// thread resolved by TurnThreadRegistry (main or the subagent thread that owns the edit).
// The diff must be built from the tool INPUT (old/new strings), which lives on the
// `tool_use` event, not the `tool_result` — so this handler tracks edit inputs by id and
// renders on the matching successful result (mirrors A4D's changeTracker → diffViewer
// flow). No discord.js: the sink is the MessageThread port (via TurnThreadRegistry).

// The tools whose input this handler renders as a pretty diff. Exported so
// ToolThreadHandler skips their raw input (rendering it too would duplicate the change).
// `apply_patch` is Codex app-server fileChange (changes[] with unified diffs).
export const FILE_EDIT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit', 'apply_patch']);

interface EditInput {
  filePath: string;
  oldString?: string;
  newString?: string;
  content?: string;
  // Pre-formatted unified diff body (Codex apply_patch). When set, renderDiff uses it as-is.
  unifiedDiff?: string;
}

export interface DiffViewDeps {
  registry: TurnThreadRegistry;
}

export class DiffViewHandler {
  private readonly registry: TurnThreadRegistry;
  // toolUseId → the edit input, kept until the matching result arrives.
  private readonly edits = new Map<string, EditInput>();

  constructor(deps: DiffViewDeps) {
    this.registry = deps.registry;
  }

  // Record a file-edit tool_use so its result can be diffed. Non-edit tools are
  // ignored (nothing tracked → nothing rendered). Also binds the tool to its thread
  // key so handleResult can open the right thread even if toolThreads is off.
  noteToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): void {
    if (!FILE_EDIT_TOOLS.has(ev.name)) return;
    const parsed = parseEditInput(ev.input);
    if (parsed) this.edits.set(ev.id, parsed);
    this.registry.bindToolUse(ev);
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
    // Always open the resolved thread (diff posts even when toolThread would buffer).
    const key = this.registry.resolveResultKey(ev);
    const thread = await this.registry.get(key);
    for (const chunk of chunkMessage('```diff\n' + diff + '\n```')) {
      await thread.send({ content: chunk });
    }
  }
}

// Build a unified-ish diff body (no headers) from an edit input. Write/create with
// only `content` renders all lines as additions; an Edit renders old→new.
// Codex apply_patch supplies a pre-formatted unifiedDiff string.
function renderDiff(edit: EditInput): string | null {
  if (edit.unifiedDiff !== undefined && edit.unifiedDiff.length > 0) {
    return edit.unifiedDiff;
  }
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

  // Codex apply_patch: { changes: [{ path, kind, diff }, ...] }
  if (Array.isArray(obj.changes)) {
    const parts: string[] = [];
    for (const c of obj.changes) {
      if (typeof c !== 'object' || c === null || Array.isArray(c)) continue;
      const rec = c as Record<string, unknown>;
      const pathStr = typeof rec.path === 'string' ? rec.path : '';
      const diff = typeof rec.diff === 'string' ? rec.diff : '';
      if (diff.length > 0) {
        parts.push(pathStr.length > 0 ? `--- ${pathStr}\n${diff}` : diff);
      } else if (pathStr.length > 0) {
        parts.push(pathStr);
      }
    }
    if (parts.length === 0) return null;
    const first = obj.changes[0];
    const firstPath =
      typeof first === 'object' &&
      first !== null &&
      typeof (first as { path?: unknown }).path === 'string'
        ? (first as { path: string }).path
        : 'patch';
    return { filePath: firstPath, unifiedDiff: parts.join('\n\n') };
  }

  const filePath =
    typeof obj.file_path === 'string'
      ? obj.file_path
      : typeof obj.path === 'string'
        ? obj.path
        : undefined;
  if (!filePath) return null;
  const out: EditInput = { filePath };
  if (typeof obj.old_string === 'string') out.oldString = obj.old_string;
  else if (typeof obj.oldText === 'string') out.oldString = obj.oldText;
  if (typeof obj.new_string === 'string') out.newString = obj.new_string;
  else if (typeof obj.newText === 'string') out.newString = obj.newText;
  if (typeof obj.content === 'string') out.content = obj.content;
  return out;
}
