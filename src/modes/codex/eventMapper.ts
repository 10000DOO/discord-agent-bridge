import type { AgentEvent, Logger } from '../../core/contracts.js';

// Codex `exec --json` stream → normalized AgentEvent mapping (§5b).
//
// This parses the EXPERIMENTAL JSON event stream (`thread.*` / `turn.*` /
// `item.*`) that `codex exec --json` prints to stdout — NOT the on-disk rollout
// schema (`response_item` / `event_msg`), which is what discovery.ts reads.
// The mapper is a pure function: one raw stdout line in, zero-or-more
// AgentEvents (plus an optionally-captured sessionId) out. It NEVER throws and
// NEVER silently drops — an unrecognized line is logged at debug and skipped so
// a future Codex event kind can never crash the stream (C2, §5b).
//
// Tolerance note: the primary schema is the `thread.*`/`turn.*`/`item.*` stream,
// but a small fallback also understands the alternate on-disk-ish
// `event_msg`/`response_item` agent-message shapes (as CDC's runner does) in
// case of stream drift between CLI versions.

// The Korean operation-progress labels surfaced for in-flight items (§5b).
const PROGRESS_LABELS = {
  commandExecution: '명령 실행 중',
  fileChange: '파일 수정 중',
  fileSearch: '파일 탐색 중',
  webSearch: '웹 검색 중',
  image: '이미지 생성 중',
  mcpToolCall: '도구 실행 중',
} as const;

// The result of mapping one stdout line: the AgentEvents it produced and, when
// the line was a `thread.started`, the captured backend session id.
export interface MappedLine {
  events: AgentEvent[];
  sessionId?: string;
}

const EMPTY: MappedLine = { events: [] };

// A file change entry within a `file_change` item.
interface FileChange {
  path?: unknown;
  kind?: unknown;
}

// The `usage` block on `turn.completed`.
interface CodexUsage {
  input_tokens?: unknown;
  output_tokens?: unknown;
  total_tokens?: unknown;
}

// Map a single raw stdout line to AgentEvents. `line` is a raw string (possibly
// non-JSON, e.g. the deprecation warning); parsing and shape-guarding happen
// here. `idFor` mints a stable id for tool_use/tool_result correlation when the
// item carries none (the AgentEvent union requires an id on those kinds).
export function mapCodexLine(line: string, logger: Logger, idFor: (item: Record<string, unknown>) => string): MappedLine {
  const trimmed = line.trim();
  if (trimmed.length === 0) return EMPTY;

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    // Non-JSON line (e.g. a CLI deprecation warning). Log, never throw.
    logger.debug('unrecognized codex event', { type: 'non-json', line: trimmed });
    return EMPTY;
  }

  if (typeof parsed !== 'object' || parsed === null) {
    logger.debug('unrecognized codex event', { type: 'non-object' });
    return EMPTY;
  }

  const event = parsed as Record<string, unknown>;
  const type = typeof event.type === 'string' ? event.type : undefined;

  switch (type) {
    case 'thread.started':
      return typeof event.thread_id === 'string'
        ? { events: [], sessionId: event.thread_id }
        : EMPTY;

    case 'turn.started':
      // Optional coarse progress; a bare "working…" tick.
      return EMPTY;

    case 'item.started':
      return mapItemStarted(event);

    case 'item.completed':
      return mapItemCompleted(event, idFor);

    case 'turn.completed':
      return mapTurnCompleted(event);

    case 'turn.failed':
    case 'thread.failed':
      return mapFailure(event);

    // Fallback: alternate on-disk-ish shapes in case of stream drift (CDC parity).
    case 'event_msg':
    case 'response_item': {
      const text = fallbackAgentMessage(event);
      if (text !== null) return { events: [{ kind: 'text', text, delta: false }] };
      logger.debug('unrecognized codex event', { type });
      return EMPTY;
    }

    default:
      logger.debug('unrecognized codex event', { type: type ?? 'missing' });
      return EMPTY;
  }
}

// `item.started` → a coarse progress event classified by item type. Unknown
// item types are dropped (in-flight progress is best-effort, not authoritative).
function mapItemStarted(event: Record<string, unknown>): MappedLine {
  const item = asRecord(event.item);
  if (!item) return EMPTY;
  const itemType = typeof item.type === 'string' ? item.type : '';

  const progress = progressForItem(itemType, item);
  return progress ? { events: [progress] } : EMPTY;
}

// Build the operation-progress event for an in-flight item, or null if the item
// type carries no meaningful progress label.
function progressForItem(itemType: string, item: Record<string, unknown>): AgentEvent | null {
  switch (itemType) {
    case 'command_execution': {
      const detail = optString(item.command);
      return progress(PROGRESS_LABELS.commandExecution, detail);
    }
    case 'file_change':
      return progress(PROGRESS_LABELS.fileChange, fileChangeDetail(item));
    case 'web_search': {
      const detail = optString(item.query);
      return progress(PROGRESS_LABELS.webSearch, detail);
    }
    case 'mcp_tool_call': {
      const detail = optString(item.tool) ?? optString(item.server);
      return progress(PROGRESS_LABELS.mcpToolCall, detail);
    }
    case 'image':
      return progress(PROGRESS_LABELS.image);
    case 'file_search':
      return progress(PROGRESS_LABELS.fileSearch);
    default:
      return null;
  }
}

// `item.completed` → the terminal events for a finished item (§5b).
function mapItemCompleted(event: Record<string, unknown>, idFor: (item: Record<string, unknown>) => string): MappedLine {
  const item = asRecord(event.item);
  if (!item) return EMPTY;
  const itemType = typeof item.type === 'string' ? item.type : '';

  switch (itemType) {
    case 'agent_message': {
      const text = optString(item.text);
      return text !== undefined ? { events: [{ kind: 'text', text, delta: false }] } : EMPTY;
    }

    case 'reasoning':
      // Codex Capabilities.thinking is false (§5b): never surface thinking.
      return EMPTY;

    case 'command_execution': {
      const id = idFor(item);
      const command = optString(item.command) ?? '';
      const output = optString(item.aggregated_output) ?? '';
      const exitCode = typeof item.exit_code === 'number' ? item.exit_code : null;
      return {
        events: [
          { kind: 'tool_use', id, name: 'shell', input: { command } },
          { kind: 'tool_result', id, ok: exitCode === 0, content: output },
        ],
      };
    }

    case 'file_change': {
      const id = idFor(item);
      const changes = Array.isArray(item.changes) ? (item.changes as FileChange[]) : [];
      return { events: [{ kind: 'tool_use', id, name: 'apply_patch', input: { changes } }] };
    }

    case 'mcp_tool_call': {
      const id = idFor(item);
      const name = optString(item.tool) ?? optString(item.name) ?? 'mcp_tool_call';
      const input = item.arguments ?? item.input ?? {};
      const events: AgentEvent[] = [{ kind: 'tool_use', id, name, input }];
      const result = optString(item.result) ?? optString(item.output);
      if (result !== undefined) {
        const ok = item.status !== 'failed' && item.error === undefined;
        events.push({ kind: 'tool_result', id, ok, content: result });
      }
      return { events };
    }

    case 'web_search': {
      const id = idFor(item);
      const query = optString(item.query);
      return { events: [{ kind: 'tool_use', id, name: 'web_search', input: query !== undefined ? { query } : {} }] };
    }

    case 'error': {
      const message = optString(item.message) ?? 'Codex reported an error.';
      return { events: [{ kind: 'error', message, retryable: false }] };
    }

    default:
      // Unknown item type — logged by the caller only for the top-level `type`;
      // an unrecognized item subtype is a benign drop of a completed item.
      return EMPTY;
  }
}

// `turn.completed` → a result event carrying token counts only. Codex has no
// usage/context panel (usagePanel:false), so NO context_usage is ever emitted
// and the result text is left to the runner (authoritative -o file).
function mapTurnCompleted(event: Record<string, unknown>): MappedLine {
  const usage = asRecord(event.usage) as CodexUsage | undefined;
  const result: Extract<AgentEvent, { kind: 'result' }> = { kind: 'result' };
  if (usage) {
    if (typeof usage.input_tokens === 'number') result.tokensIn = usage.input_tokens;
    if (typeof usage.output_tokens === 'number') result.tokensOut = usage.output_tokens;
  }
  return { events: [result] };
}

// `turn.failed` / `thread.failed` → a non-retryable error event.
function mapFailure(event: Record<string, unknown>): MappedLine {
  const error = asRecord(event.error);
  const message = (error && optString(error.message)) ?? optString(event.message) ?? 'Codex turn failed.';
  return { events: [{ kind: 'error', message, retryable: false }] };
}

// Fallback agent-message extraction for the alternate `event_msg`/`response_item`
// shapes, mirroring CDC's tolerant runner. Returns null when the line is not an
// agent message under either shape.
function fallbackAgentMessage(event: Record<string, unknown>): string | null {
  const payload = asRecord(event.payload);
  if (!payload) return null;
  const payloadType = typeof payload.type === 'string' ? payload.type : '';

  if (event.type === 'event_msg') {
    if (payloadType === 'agent_message') {
      const text = optString(payload.message);
      if (text !== undefined && text.trim().length > 0) return text.trim();
    }
    if (payloadType === 'task_complete') {
      const text = optString(payload.last_agent_message);
      if (text !== undefined && text.trim().length > 0) return text.trim();
    }
    return null;
  }

  // response_item message from the assistant.
  if (payloadType === 'message' && payload.role === 'assistant') {
    const text = contentText(payload.content);
    return text.length > 0 ? text : null;
  }
  return null;
}

// ---- shape helpers ----------------------------------------------------------

function progress(label: string, detail?: string): AgentEvent {
  return detail !== undefined ? { kind: 'progress', label, detail } : { kind: 'progress', label };
}

// A compact single-line detail for a file_change item's affected paths.
function fileChangeDetail(item: Record<string, unknown>): string | undefined {
  if (!Array.isArray(item.changes)) return undefined;
  const paths = (item.changes as FileChange[])
    .map((c) => (typeof c.path === 'string' ? c.path : ''))
    .filter((p) => p.length > 0);
  if (paths.length === 0) return undefined;
  return paths.length === 1 ? paths[0] : `${paths.length}개 파일`;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

// A non-empty trimmed string, or undefined. Used to guard optional string fields.
function optString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

// Flatten a `response_item` content (string, or array of text blocks) to a string.
function contentText(content: unknown): string {
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => {
      if (typeof part === 'string') return part;
      const rec = asRecord(part);
      return rec && typeof rec.text === 'string' ? rec.text : '';
    })
    .map((t) => t.trim())
    .filter((t) => t.length > 0)
    .join('\n');
}
