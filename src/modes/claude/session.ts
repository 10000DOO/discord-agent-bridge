import {
  query as realQuery,
  type Options,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { ModeContext, ModeSession, SessionPermMode, TurnInput } from '../../core/contracts.js';
import { makeCanUseTool } from './permissions.js';
import { createMcpFileTool, ATTACH_FILE_TOOL_NAME, type SendFileCallback } from './mcpFileTool.js';
import { resolvePlugins } from './plugins.js';

// The signature of the SDK's query() — narrowed to what we call. Injectable so
// tests can pass a fake that returns a scripted async iterable without touching
// the network (the default is the real SDK query).
export type QueryFn = (params: { prompt: AsyncIterable<SDKUserMessage>; options?: Options }) => Query;

export interface ClaudeSessionDeps {
  // Defaults to the real SDK query; tests inject a fake.
  queryFn?: QueryFn;
  // Wired by the Discord layer; when absent, attach_file is not exposed (the tool
  // is only useful once a transport can actually deliver the file).
  sendFile?: SendFileCallback;
  // Existing backend session id to resume; omitted for a fresh session.
  resumeId?: string;
}

// Map our PermMode straight onto the SDK's native `permissionMode` (§7A). PermMode is
// now DERIVED from the SDK's PermissionMode (contracts.ts), so every value — including
// 'dontAsk'/'auto' — is a valid SDK value and passes through verbatim, faithful to
// terminal `claude`, instead of collapsing everything to 'default' and emulating. The
// config-driven canUseTool auto-allow (permissions.ts) still governs the 'default'
// mode's gate (fixes A8). 'bypassPermissions' additionally requires
// allowDangerouslySkipPermissions (see options below). An unknown value (should not
// happen given the schema) degrades to 'default'.
function toSdkPermissionMode(permMode: SessionPermMode): Options['permissionMode'] {
  switch (permMode) {
    case 'acceptEdits':
    case 'bypassPermissions':
    case 'plan':
    case 'dontAsk':
    case 'auto':
      return permMode;
    case 'default':
    default:
      // A Codex sandbox mode never reaches a Claude session, but degrade safely if so.
      return 'default';
  }
}

// A running Claude session (§9): one persistent query() whose prompt is an async
// stream we feed user turns into. The SDK message iterable is consumed in the
// background and each message is mapped to a normalized AgentEvent via ctx.emit.
export class ClaudeSession implements ModeSession {
  sessionId: string | null = null;

  // The RESOLVED model id reported by the SDK's init message (e.g.
  // 'claude-fable-5[1m]') — better for display than ctx.model, which may be an
  // alias like 'opus'. Carried on context_usage events for the usage panel.
  private activeModel: string | null = null;

  private readonly ctx: ModeContext;
  private readonly query: Query;
  private readonly abortController: AbortController;

  // Prompt-stream handoff: turns are enqueued and handed to the SDK's async
  // prompt generator one at a time. Unlike A4D's single resolveNext (which drops
  // a turn pushed before the generator is waiting), a buffer + optional waiter
  // makes the handoff safe regardless of ordering.
  private readonly pending: SDKUserMessage[] = [];
  private waiter: ((msg: SDKUserMessage) => void) | null = null;
  private closed = false;

  constructor(ctx: ModeContext, deps: ClaudeSessionDeps = {}) {
    this.ctx = ctx;
    this.abortController = new AbortController();

    const queryFn = deps.queryFn ?? (realQuery as QueryFn);

    const mcpServers: NonNullable<Options['mcpServers']> = {};
    const allowedTools = [...(ctx.config.allowedTools ?? [])];
    if (deps.sendFile) {
      mcpServers.discord = createMcpFileTool(ctx.cwd, deps.sendFile);
      if (!allowedTools.includes(ATTACH_FILE_TOOL_NAME)) {
        allowedTools.push(ATTACH_FILE_TOOL_NAME);
      }
    }

    const permissionMode = toSdkPermissionMode(ctx.permMode);
    const options: Options = {
      cwd: ctx.cwd,
      // Pin the model's write target to the selected folder. The SDK forwards `cwd`
      // to the CLI subprocess (verified: process.cwd() and the init `cwd` both equal
      // ctx.cwd), but with an unqualified prompt like "create test.txt" the model
      // resolves the path against $HOME, not process.cwd() — so files landed in HOME
      // regardless of cwd/additionalDirectories/permissionMode. Appending the working
      // directory to the claude_code preset (empirically: 0/N honored without it,
      // N/N with it) makes relative writes land in ctx.cwd. Codex does not need this —
      // it passes the dir to its CLI explicitly via `--cd` (codex/runner.ts).
      systemPrompt: {
        type: 'preset',
        preset: 'claude_code',
        append: `Your working directory is ${ctx.cwd}. Unless the user gives an absolute path, create and edit all files relative to this working directory, NOT the home directory.`,
      },
      permissionMode,
      // The SDK REQUIRES this flag to be true when permissionMode is
      // 'bypassPermissions' (sdk.d.ts: "Must be set to true when using
      // permissionMode: 'bypassPermissions'"). Set it only for that mode so the
      // dangerous bypass is never enabled implicitly.
      ...(permissionMode === 'bypassPermissions' ? { allowDangerouslySkipPermissions: true } : {}),
      includePartialMessages: true,
      abortController: this.abortController,
      canUseTool: makeCanUseTool(ctx),
      // Load the project's .claude/ (subagents, hooks, MCP, CLAUDE.md) plus user
      // and local settings, exactly like the terminal `claude`. 'project' is
      // required for CLAUDE.md; all three cover subagents/hooks/skills/MCP.
      settingSources: ['user', 'project', 'local'],
      plugins: resolvePlugins(ctx.logger),
      ...(ctx.model !== undefined ? { model: ctx.model } : {}),
      // Reasoning effort chosen in the wizard (§9). The wizard only sets a valid Claude
      // EffortLevel for the Claude backend; empty/absent lets the SDK use its default.
      ...(ctx.effort !== undefined && ctx.effort.length > 0
        ? { effort: ctx.effort as Options['effort'] }
        : {}),
      ...(Object.keys(mcpServers).length > 0 ? { mcpServers } : {}),
      ...(allowedTools.length > 0 ? { allowedTools } : {}),
      ...(deps.resumeId !== undefined ? { resume: deps.resumeId } : {}),
    };
    if (deps.resumeId !== undefined) {
      this.sessionId = deps.resumeId;
    }

    // Log the working directory actually handed to the SDK so a live run shows the
    // effective cwd (must match the status-embed cwd and the folder files land in).
    ctx.logger.info('claude session cwd', { cwd: options.cwd, ctxCwd: ctx.cwd, permissionMode });

    this.query = queryFn({ prompt: this.promptStream(), options });
    void this.consume();
  }

  // The SDK pulls user turns from this generator. It yields a buffered turn
  // immediately, otherwise parks until send() pushes one. Ends when the session
  // is closed so the SDK can wind down cleanly.
  private async *promptStream(): AsyncGenerator<SDKUserMessage> {
    while (!this.closed) {
      const next = this.pending.shift();
      if (next) {
        yield next;
        continue;
      }
      const msg = await new Promise<SDKUserMessage | null>((resolve) => {
        this.waiter = resolve as (m: SDKUserMessage) => void;
        this.closeResolve = () => resolve(null);
      });
      this.waiter = null;
      this.closeResolve = null;
      if (msg === null) return; // closed while waiting
      yield msg;
    }
  }

  private closeResolve: (() => void) | null = null;

  // Consume the SDK message stream and map each message to a normalized
  // AgentEvent (§5a). A stream/SDK error becomes a single retryable error event
  // rather than an unhandled rejection (the consume loop owns error handling).
  private async consume(): Promise<void> {
    try {
      for await (const msg of this.query) {
        this.mapMessage(msg);
      }
    } catch (err) {
      // An abort (from stop()) is expected shutdown, not a failure to surface.
      if (this.closed || this.abortController.signal.aborted) return;
      this.ctx.emit({
        kind: 'error',
        message: err instanceof Error ? err.message : String(err),
        retryable: true,
      });
    }
  }

  // One SDK message → zero or more AgentEvents. Unknown/other message types are
  // ignored (with a debug log) so a new SDK message kind never crashes the loop.
  private mapMessage(msg: SDKMessage): void {
    switch (msg.type) {
      case 'system': {
        if (msg.subtype === 'init' && msg.session_id) {
          if (typeof msg.model === 'string' && msg.model.length > 0) this.activeModel = msg.model;
          const first = this.sessionId === null;
          this.sessionId = msg.session_id;
          // Only the FIRST capture notifies the orchestrator so it can persist the
          // real backend sessionId to the ChannelRegistry (start() saved the binding
          // with sessionId=null since init arrives asynchronously after start).
          if (first) this.ctx.onSessionIdReady?.(msg.session_id);
        }
        return;
      }
      case 'stream_event': {
        this.mapStreamEvent(msg);
        return;
      }
      case 'assistant': {
        this.mapAssistant(msg);
        return;
      }
      case 'user': {
        this.mapUser(msg);
        return;
      }
      case 'result': {
        this.mapResult(msg);
        return;
      }
      case 'rate_limit_event': {
        const info = msg.rate_limit_info;
        this.ctx.emit({
          kind: 'rate_limit',
          ...(info.resetsAt !== undefined
            ? { resetAt: new Date(info.resetsAt * 1000).toISOString() }
            : {}),
          ...(info.rateLimitType !== undefined ? { rateLimitType: info.rateLimitType } : {}),
          ...(info.utilization !== undefined ? { utilization: info.utilization } : {}),
        });
        return;
      }
      default: {
        this.ctx.logger.debug('claude: unmapped SDK message', { type: (msg as { type: string }).type });
        return;
      }
    }
  }

  // stream_event content_block_delta → text/thinking deltas (§5a). The SDK wraps
  // the raw Anthropic stream event; delta shapes vary by version, so we navigate
  // structurally and defensively (mirrors A4D eventHandler.ts:175-184).
  private mapStreamEvent(msg: SDKMessage & { type: 'stream_event' }): void {
    const event = (msg as { event?: unknown }).event as
      | { type?: string; delta?: { type?: string; text?: string; thinking?: string } }
      | undefined;
    if (!event || event.type !== 'content_block_delta' || !event.delta) return;
    const delta = event.delta;
    if (delta.type === 'text_delta' && typeof delta.text === 'string') {
      this.ctx.emit({ kind: 'text', text: delta.text, delta: true });
    } else if (delta.type === 'thinking_delta' && typeof delta.thinking === 'string') {
      this.ctx.emit({ kind: 'thinking', text: delta.thinking, delta: true });
    }
  }

  // assistant tool_use blocks → tool_use events (§5a). Text blocks arrive via
  // stream_event deltas, so they are not re-emitted here.
  private mapAssistant(msg: SDKMessage & { type: 'assistant' }): void {
    const content = (msg.message as { content?: unknown }).content;
    if (!Array.isArray(content)) return;
    for (const block of content as Array<Record<string, unknown>>) {
      if (block.type === 'tool_use') {
        this.ctx.emit({
          kind: 'tool_use',
          id: String(block.id ?? ''),
          name: String(block.name ?? 'unknown'),
          input: block.input ?? {},
        });
      }
    }
  }

  // user tool_result blocks → tool_result events (§5a). is_error flips ok=false;
  // content is flattened to a string for the normalized event.
  private mapUser(msg: SDKMessage & { type: 'user' }): void {
    const content = (msg.message as { content?: unknown }).content;
    if (!Array.isArray(content)) return;
    for (const block of content as Array<Record<string, unknown>>) {
      if (block.type !== 'tool_result') continue;
      this.ctx.emit({
        kind: 'tool_result',
        id: String(block.tool_use_id ?? ''),
        ok: block.is_error !== true,
        content: flattenToolResult(block.content),
      });
    }
  }

  // result → result event with cost/tokens/duration, then context_usage from
  // query.getContextUsage() (§5a, §7.4). getContextUsage is best-effort: a
  // failure never turns a completed turn into an error.
  private mapResult(msg: SDKMessage & { type: 'result' }): void {
    const usage = (msg as { usage?: { input_tokens?: number; output_tokens?: number } }).usage ?? {};
    const resultText = msg.subtype === 'success' ? msg.result : undefined;
    this.ctx.emit({
      kind: 'result',
      ...(resultText !== undefined ? { text: resultText } : {}),
      ...(msg.total_cost_usd !== undefined ? { costUsd: msg.total_cost_usd } : {}),
      ...(usage.input_tokens !== undefined ? { tokensIn: usage.input_tokens } : {}),
      ...(usage.output_tokens !== undefined ? { tokensOut: usage.output_tokens } : {}),
      ...(msg.duration_ms !== undefined ? { durationMs: msg.duration_ms } : {}),
    });

    void this.query
      .getContextUsage()
      .then((ctx) => {
        this.ctx.emit({
          kind: 'context_usage',
          totalTokens: ctx.totalTokens,
          maxTokens: ctx.maxTokens,
          percentage: ctx.percentage,
          ...(this.activeModel !== null ? { model: this.activeModel } : {}),
        });
      })
      .catch(() => {
        // Best-effort: no context panel this turn if the SDK cannot report it.
      });
  }

  // Deliver a user turn: enqueue it and hand it to the prompt stream. A turn
  // pushed while the generator is parked wakes it; otherwise it buffers until the
  // generator pulls next (fixes A4D's drop-if-not-waiting race).
  async send(turn: TurnInput): Promise<void> {
    if (this.closed) throw new Error('Claude session is closed.');
    const message: SDKUserMessage = {
      type: 'user',
      message: { role: 'user', content: turn.text },
      parent_tool_use_id: null,
    };
    if (this.waiter) {
      const resolve = this.waiter;
      this.waiter = null;
      resolve(message);
    } else {
      this.pending.push(message);
    }
  }

  // Change the model on the LIVE query mid-session (SDK setModel). A model name or
  // alias ('opus'/'sonnet'/'haiku') is accepted; the SDK resolves it. Takes effect on
  // the next turn of this same session — no restart, no lost context. activeModel is
  // updated so the usage panel reflects the new choice.
  async setModel(model?: string): Promise<void> {
    if (this.closed) throw new Error('Claude session is closed.');
    await this.query.setModel(model);
    if (typeof model === 'string' && model.length > 0) this.activeModel = model;
  }

  // Abort the underlying query and wind down the prompt stream (§7.5 kill switch).
  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.abortController.abort();
    this.closeResolve?.();
    try {
      this.query.close();
    } catch {
      // Closing an already-finished query is a no-op we can ignore.
    }
  }
}

// Flatten a tool_result `content` (string, or an array of text blocks, or other)
// into a plain string for the normalized tool_result event.
function flattenToolResult(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (typeof b === 'string') return b;
        if (b && typeof b === 'object' && typeof (b as { text?: unknown }).text === 'string') {
          return (b as { text: string }).text;
        }
        return '';
      })
      .join('');
  }
  return content == null ? '' : String(content);
}
