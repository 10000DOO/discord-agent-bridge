import type { AgentEvent, Logger } from '../../core/contracts.js';

// Map `codex app-server` notifications → AgentEvent[]. Pure: never throws; unknown
// methods/items yield empty events (caller may log). Wire shapes use camelCase item
// types and fields (codex 0.143.0 spike): agentMessage, commandExecution, aggregatedOutput,
// exitCode, item/agentMessage/delta, turn/completed, etc.

export interface MapContext {
  mainThreadId?: string;
  // childThreadId → parent spawn tool_use id
  parentByThread?: Map<string, string>;
  // Register when a collab spawn completes (child thread linked to spawn tool id).
  onSpawnThread?: (childThreadId: string, spawnToolId: string) => void;
  // Optional logger for unknown notifications (never required for purity).
  logger?: Logger;
  // Stable id mint when an item carries none.
  idFor?: (item: Record<string, unknown>) => string;
}

export interface MappedNotification {
  events: AgentEvent[];
  turnCompleted?: boolean;
  turnFailed?: boolean;
  turnId?: string;
  threadId?: string;
  // Latest token usage snapshot for the session. appSession stores this and posts
  // a single context_usage event at turn end (tokenUsage/updated fires many times
  // mid-turn and must not spam the Discord usage panel).
  tokenUsage?: {
    totalTokens: number;
    maxTokens: number;
    percentage: number;
    model?: string;
  };
}

const EMPTY: MappedNotification = { events: [] };

const PROGRESS_LABELS = {
  commandExecution: '명령 실행 중',
  fileChange: '파일 수정 중',
  fileSearch: '파일 탐색 중',
  webSearch: '웹 검색 중',
  image: '이미지 생성 중',
  mcpToolCall: '도구 실행 중',
  collabAgentToolCall: '서브에이전트 작업 중',
} as const;

// Default monotonic id helper for callers that do not inject one.
let defaultToolSeq = 0;
function defaultIdFor(item: Record<string, unknown>): string {
  if (typeof item.id === 'string' && item.id.length > 0) return item.id;
  if (typeof item.itemId === 'string' && item.itemId.length > 0) return item.itemId;
  return `codex-tool-${++defaultToolSeq}`;
}

export function mapAppServerNotification(
  method: string,
  params: unknown,
  ctx?: MapContext,
): MappedNotification {
  try {
    return mapInner(method, params, ctx);
  } catch {
    // Never throw from the mapper.
    return EMPTY;
  }
}

function mapInner(method: string, params: unknown, ctx?: MapContext): MappedNotification {
  const p = asRecord(params) ?? {};
  const idFor = ctx?.idFor ?? defaultIdFor;
  const threadId = optString(p.threadId);
  const turnId = optString(p.turnId);
  const parentToolUseId = resolveParent(threadId, ctx);

  switch (method) {
    case 'item/agentMessage/delta': {
      const delta = optString(p.delta) ?? '';
      if (delta.length === 0) return { events: [], ...(threadId ? { threadId } : {}), ...(turnId ? { turnId } : {}) };
      return {
        events: [{ kind: 'text', text: delta, delta: true }],
        ...(threadId ? { threadId } : {}),
        ...(turnId ? { turnId } : {}),
      };
    }

    case 'item/started':
      return {
        ...mapItemStarted(p, parentToolUseId),
        ...(threadId ? { threadId } : {}),
        ...(turnId ? { turnId } : {}),
      };

    case 'item/completed':
      return {
        ...mapItemCompleted(p, idFor, parentToolUseId, ctx),
        ...(threadId ? { threadId } : {}),
        ...(turnId ? { turnId } : {}),
      };

    case 'turn/started':
      return {
        events: [{ kind: 'progress', label: '작업 중' }],
        ...(threadId ? { threadId } : {}),
        ...(turnId ? { turnId } : {}),
      };

    case 'turn/completed': {
      const usage = asRecord(p.usage);
      const result: Extract<AgentEvent, { kind: 'result' }> = { kind: 'result' };
      if (usage) {
        // Prefer camelCase (app-server); accept snake_case for tolerance.
        if (typeof usage.inputTokens === 'number') result.tokensIn = usage.inputTokens;
        else if (typeof usage.input_tokens === 'number') result.tokensIn = usage.input_tokens;
        if (typeof usage.outputTokens === 'number') result.tokensOut = usage.outputTokens;
        else if (typeof usage.output_tokens === 'number') result.tokensOut = usage.output_tokens;
      }
      // Nested turn object may also carry usage / id.
      const turn = asRecord(p.turn);
      const completedTurnId = turnId ?? (turn && optString(turn.id));
      if (!result.tokensIn && !result.tokensOut && turn) {
        const tUsage = asRecord(turn.usage);
        if (tUsage) {
          if (typeof tUsage.inputTokens === 'number') result.tokensIn = tUsage.inputTokens;
          if (typeof tUsage.outputTokens === 'number') result.tokensOut = tUsage.outputTokens;
        }
      }
      return {
        events: [result],
        turnCompleted: true,
        ...(completedTurnId ? { turnId: completedTurnId } : {}),
        ...(threadId ? { threadId } : {}),
      };
    }

    case 'turn/failed':
    case 'thread/failed':
    case 'error': {
      const error = asRecord(p.error);
      const message =
        (error && optString(error.message)) ??
        optString(p.message) ??
        'Codex turn failed.';
      return {
        events: [{ kind: 'error', message, retryable: false }],
        turnFailed: true,
        turnCompleted: true,
        ...(turnId ? { turnId } : {}),
        ...(threadId ? { threadId } : {}),
      };
    }

    case 'thread/started': {
      // May announce main or child threads (parentThreadId for subagents).
      const startedId =
        threadId ??
        optString(p.id) ??
        (asRecord(p.thread) ? optString((p.thread as Record<string, unknown>).id) : undefined);
      const parentThreadId = optString(p.parentThreadId);
      if (startedId && parentThreadId && ctx?.parentByThread) {
        // If we already know a spawn tool for the parent thread's latest spawn, leave
        // mapping to collabAgentToolCall; parentThreadId alone does not give spawn tool id.
      }
      return {
        events: [],
        ...(startedId ? { threadId: startedId } : {}),
      };
    }

    case 'item/reasoning/delta':
    case 'item/agentReasoning/delta':
    case 'item/reasoning/textDelta':
    case 'item/reasoning/summaryTextDelta': {
      const delta = optString(p.delta) ?? '';
      if (delta.length === 0) {
        return { events: [], ...(threadId ? { threadId } : {}), ...(turnId ? { turnId } : {}) };
      }
      return {
        events: [{ kind: 'thinking', text: delta, delta: true }],
        ...(threadId ? { threadId } : {}),
        ...(turnId ? { turnId } : {}),
      };
    }

    case 'thread/tokenUsage/updated': {
      // Do NOT emit context_usage here — app-server streams this many times per turn.
      // Return a snapshot for appSession to post once at turn end.
      const usage = asRecord(p.tokenUsage);
      if (!usage) return EMPTY;
      const total = asRecord(usage.total);
      const totalTokens =
        typeof total?.totalTokens === 'number' ? total.totalTokens : undefined;
      const maxTokens =
        typeof usage.modelContextWindow === 'number' ? usage.modelContextWindow : undefined;
      // No snapshot without a positive context window (same guard as grok).
      if (totalTokens === undefined || maxTokens === undefined || maxTokens <= 0) return EMPTY;
      return {
        events: [],
        tokenUsage: {
          totalTokens,
          maxTokens,
          percentage: Math.min(100, Math.round((totalTokens / maxTokens) * 100)),
        },
        ...(threadId ? { threadId } : {}),
        ...(turnId ? { turnId } : {}),
      };
    }

    default:
      ctx?.logger?.debug('unrecognized codex app-server notification', { method });
      return EMPTY;
  }
}

function mapItemStarted(p: Record<string, unknown>, parentToolUseId?: string): MappedNotification {
  const item = asRecord(p.item) ?? p;
  const itemType = typeof item.type === 'string' ? item.type : '';
  const progress = progressForItem(itemType, item);
  if (!progress) return EMPTY;
  // parentToolUseId does not attach to progress events (contracts omit it).
  void parentToolUseId;
  return { events: [progress] };
}

function progressForItem(itemType: string, item: Record<string, unknown>): AgentEvent | null {
  switch (itemType) {
    case 'commandExecution':
    case 'command_execution': {
      const detail = optString(item.command);
      return progress(PROGRESS_LABELS.commandExecution, detail);
    }
    case 'fileChange':
    case 'file_change':
      return progress(PROGRESS_LABELS.fileChange, fileChangeDetail(item));
    case 'webSearch':
    case 'web_search': {
      const detail = optString(item.query);
      return progress(PROGRESS_LABELS.webSearch, detail);
    }
    case 'mcpToolCall':
    case 'mcp_tool_call': {
      const detail = optString(item.tool) ?? optString(item.server) ?? optString(item.name);
      return progress(PROGRESS_LABELS.mcpToolCall, detail);
    }
    case 'collabAgentToolCall':
    case 'collab_agent_tool_call':
      return progress(PROGRESS_LABELS.collabAgentToolCall, optString(item.agentRole) ?? optString(item.tool));
    case 'image':
      return progress(PROGRESS_LABELS.image);
    case 'fileSearch':
    case 'file_search':
      return progress(PROGRESS_LABELS.fileSearch);
    default:
      return null;
  }
}

function mapItemCompleted(
  p: Record<string, unknown>,
  idFor: (item: Record<string, unknown>) => string,
  parentToolUseId: string | undefined,
  ctx?: MapContext,
): MappedNotification {
  const item = asRecord(p.item) ?? p;
  const itemType = typeof item.type === 'string' ? item.type : '';
  const parent = parentToolUseId ? { parentToolUseId } : {};

  switch (itemType) {
    case 'agentMessage':
    case 'agent_message': {
      // Prefer streamed deltas; only emit a full text if present (no prior stream guarantee).
      const text = optString(item.text);
      if (text === undefined || text.length === 0) return EMPTY;
      return { events: [{ kind: 'text', text, delta: false }] };
    }

    case 'userMessage':
    case 'user_message':
    case 'reasoning':
      return EMPTY;

    case 'commandExecution':
    case 'command_execution': {
      const id = idFor(item);
      const command = optString(item.command) ?? '';
      const output =
        optString(item.aggregatedOutput) ??
        optString(item.aggregated_output) ??
        '';
      const exitCode =
        typeof item.exitCode === 'number'
          ? item.exitCode
          : typeof item.exit_code === 'number'
            ? item.exit_code
            : null;
      return {
        events: [
          { kind: 'tool_use', id, name: 'shell', input: { command }, ...parent },
          { kind: 'tool_result', id, ok: exitCode === 0, content: output, ...parent },
        ],
      };
    }

    case 'fileChange':
    case 'file_change': {
      const id = idFor(item);
      const changes = Array.isArray(item.changes) ? item.changes : [];
      const body = formatFileChangeDiffs(changes);
      const ok = item.status !== 'failed' && item.status !== 'declined';
      return {
        events: [
          { kind: 'tool_use', id, name: 'apply_patch', input: { changes }, ...parent },
          { kind: 'tool_result', id, ok, content: body, ...parent },
        ],
      };
    }

    case 'mcpToolCall':
    case 'mcp_tool_call': {
      const id = idFor(item);
      const name = optString(item.tool) ?? optString(item.name) ?? 'mcp_tool_call';
      const input = item.arguments ?? item.input ?? {};
      const events: AgentEvent[] = [{ kind: 'tool_use', id, name, input, ...parent }];
      const result = optString(item.result) ?? optString(item.output);
      if (result !== undefined) {
        const ok = item.status !== 'failed' && item.error === undefined;
        events.push({ kind: 'tool_result', id, ok, content: result, ...parent });
      }
      return { events };
    }

    case 'webSearch':
    case 'web_search': {
      const id = idFor(item);
      const query = optString(item.query);
      return {
        events: [
          {
            kind: 'tool_use',
            id,
            name: 'web_search',
            input: query !== undefined ? { query } : {},
            ...parent,
          },
        ],
      };
    }

    case 'collabAgentToolCall':
    case 'collab_agent_tool_call': {
      return mapCollabAgent(item, idFor, parent, ctx);
    }

    case 'subAgentActivity':
    case 'sub_agent_activity': {
      const statusRaw = optString(item.status) ?? optString(item.state);
      const summary =
        optString(item.summary) ??
        optString(item.message) ??
        optString(item.text) ??
        'subagent activity';
      const toolUseId = optString(item.toolUseId) ?? optString(item.parentToolUseId) ?? parentToolUseId;
      if (statusRaw === 'completed' || statusRaw === 'failed' || statusRaw === 'stopped') {
        return {
          events: [
            {
              kind: 'subagent_result',
              taskId: optString(item.taskId) ?? optString(item.id) ?? 'subagent',
              status: statusRaw,
              summary,
              ...(toolUseId ? { toolUseId } : {}),
            },
          ],
        };
      }
      return {
        events: [progress('서브에이전트', summary)],
      };
    }

    case 'error': {
      const message = optString(item.message) ?? 'Codex reported an error.';
      return { events: [{ kind: 'error', message, retryable: false }] };
    }

    default:
      return EMPTY;
  }
}

function mapCollabAgent(
  item: Record<string, unknown>,
  idFor: (item: Record<string, unknown>) => string,
  parent: { parentToolUseId?: string },
  ctx?: MapContext,
): MappedNotification {
  const tool = optString(item.tool) ?? optString(item.name) ?? optString(item.toolName) ?? '';
  const isSpawn =
    tool === 'spawnAgent' ||
    tool === 'spawn_agent' ||
    item.type === 'spawnAgent' ||
    optString(item.action) === 'spawnAgent';

  const id = idFor(item);
  const agentRole = optString(item.agentRole) ?? optString(item.agent_role);
  const agentNickname = optString(item.agentNickname) ?? optString(item.agent_nickname) ?? optString(item.nickname);
  const subagentType = agentRole ?? optString(item.subagent_type) ?? optString(item.subagentType);

  if (isSpawn || tool.length === 0) {
    const input: Record<string, unknown> = {};
    if (subagentType) input.subagent_type = subagentType;
    if (agentNickname) input.agentNickname = agentNickname;
    if (agentRole) input.agentRole = agentRole;
    const description = optString(item.description);
    if (description) input.description = description;
    // Pass through remaining known fields for the thread name helper.
    const childThreadId =
      optString(item.threadId) ??
      optString(item.childThreadId) ??
      optString(item.agentThreadId) ??
      (asRecord(item.thread) ? optString((item.thread as Record<string, unknown>).id) : undefined);
    if (childThreadId) {
      input.threadId = childThreadId;
      ctx?.onSpawnThread?.(childThreadId, id);
    }

    const events: AgentEvent[] = [
      { kind: 'tool_use', id, name: 'spawnAgent', input, ...parent },
    ];
    // Completed spawn may include a result payload.
    const resultText = optString(item.result) ?? optString(item.output);
    if (resultText !== undefined || item.status === 'completed' || item.status === 'failed') {
      const ok = item.status !== 'failed' && item.error === undefined;
      events.push({
        kind: 'tool_result',
        id,
        ok,
        content: resultText ?? (ok ? 'spawned' : 'failed'),
        ...parent,
      });
    }
    return { events };
  }

  // Non-spawn collab tool call.
  const name = tool.length > 0 ? tool : 'collabAgentToolCall';
  const input = item.arguments ?? item.input ?? item;
  const events: AgentEvent[] = [{ kind: 'tool_use', id, name, input, ...parent }];
  const result = optString(item.result) ?? optString(item.output);
  if (result !== undefined) {
    const ok = item.status !== 'failed' && item.error === undefined;
    events.push({ kind: 'tool_result', id, ok, content: result, ...parent });
  }
  return { events };
}

function resolveParent(threadId: string | undefined, ctx?: MapContext): string | undefined {
  if (!threadId || !ctx?.parentByThread) return undefined;
  return ctx.parentByThread.get(threadId);
}

function progress(label: string, detail?: string): AgentEvent {
  return detail !== undefined ? { kind: 'progress', label, detail } : { kind: 'progress', label };
}

function fileChangeDetail(item: Record<string, unknown>): string | undefined {
  if (!Array.isArray(item.changes)) return undefined;
  const paths = item.changes
    .map((c) => {
      const rec = asRecord(c);
      return rec && typeof rec.path === 'string' ? rec.path : '';
    })
    .filter((p) => p.length > 0);
  if (paths.length === 0) return undefined;
  return paths.length === 1 ? paths[0] : `${paths.length}개 파일`;
}

// Join FileUpdateChange entries ({path, kind, diff}) into a tool_result body for tool
// threads / DiffView. Codex only ships unified-diff strings (no old/new text).
function formatFileChangeDiffs(changes: unknown[]): string {
  const parts: string[] = [];
  for (const c of changes) {
    const rec = asRecord(c);
    if (!rec) continue;
    const pathStr = optString(rec.path) ?? '';
    const diff = optString(rec.diff) ?? '';
    if (diff.length > 0) {
      parts.push(pathStr.length > 0 ? `--- ${pathStr}\n${diff}` : diff);
    } else if (pathStr.length > 0) {
      parts.push(pathStr);
    }
  }
  return parts.join('\n\n');
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function optString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}
