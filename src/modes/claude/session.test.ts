import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import type { AgentEvent, ModeContext, PermissionDecision } from '../../core/contracts.js';
import { ClaudeMode } from './index.js';
import { ClaudeSession, type QueryFn } from './session.js';
import { makeCanUseTool } from './permissions.js';
import { attachFileConfined } from './mcpFileTool.js';

// ---- Test doubles ------------------------------------------------------------

// A no-op logger matching the contract.
const nullLogger = {
  debug() {},
  info() {},
  warn() {},
  error() {},
};

// Records every emitted AgentEvent (in order) and lets a test resolve/deny
// permission requests. `allowedTools`/`autoAllowClaudeTools` feed the config view.
interface CtxHarness {
  ctx: ModeContext;
  events: AgentEvent[];
  permissionCalls: { toolName: string; input: unknown }[];
}

function makeCtx(opts: {
  cwd?: string;
  permMode?: ModeContext['permMode'];
  model?: string;
  allowedTools?: string[];
  autoAllowClaudeTools?: string[];
  permissionDecision?: PermissionDecision;
  onSessionIdReady?: (id: string) => void;
} = {}): CtxHarness {
  const events: AgentEvent[] = [];
  const permissionCalls: { toolName: string; input: unknown }[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd: opts.cwd ?? '/tmp/ws',
    ownerId: 'u1',
    ...(opts.model !== undefined ? { model: opts.model } : {}),
    permMode: opts.permMode ?? 'default',
    emit: (ev) => events.push(ev),
    requestPermission: async (req) => {
      permissionCalls.push(req);
      return opts.permissionDecision ?? { behavior: 'allow' };
    },
    config: {
      ...(opts.allowedTools !== undefined ? { allowedTools: opts.allowedTools } : {}),
      ...(opts.autoAllowClaudeTools !== undefined
        ? { autoAllowClaudeTools: opts.autoAllowClaudeTools }
        : {}),
    },
    logger: nullLogger,
    audit: () => {},
    ...(opts.onSessionIdReady !== undefined ? { onSessionIdReady: opts.onSessionIdReady } : {}),
  };
  return { ctx, events, permissionCalls };
}

// A fake Query: yields the scripted messages once, then completes. Records
// getContextUsage() calls and whether close() ran. `stallForever` makes the
// stream never end (so the consume loop is still open when stop() aborts).
function makeFakeQuery(messages: unknown[], opts: { stallForever?: boolean } = {}) {
  const state = { closed: false, contextUsageCalls: 0 };
  const query = {
    async *[Symbol.asyncIterator]() {
      for (const m of messages) yield m;
      if (opts.stallForever) {
        // Park until close()/abort ends the test; never yields a result.
        await new Promise<void>(() => {});
      }
    },
    close() {
      state.closed = true;
    },
    async getContextUsage() {
      state.contextUsageCalls++;
      return { totalTokens: 1234, maxTokens: 200000, percentage: 0.617 };
    },
  };
  return { query, state };
}

// Build an injectable queryFn that returns a fake query built from `messages`.
function fakeQueryFn(messages: unknown[], opts: { stallForever?: boolean } = {}): {
  queryFn: QueryFn;
  captured: { options?: unknown };
  state: { closed: boolean; contextUsageCalls: number };
} {
  const { query, state } = makeFakeQuery(messages, opts);
  const captured: { options?: unknown } = {};
  const queryFn: QueryFn = ({ options }) => {
    captured.options = options;
    return query as unknown as ReturnType<QueryFn>;
  };
  return { queryFn, captured, state };
}

// Poll until `pred()` is true or the budget elapses. The consume loop runs on
// microtasks, so a short poll is enough to let scripted messages flush.
async function waitFor(pred: () => boolean, budgetMs = 500): Promise<void> {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > budgetMs) throw new Error('waitFor timed out');
    await new Promise((r) => setTimeout(r, 5));
  }
}

// A scripted, ordered set of SDK messages covering every mapped kind.
function scriptedMessages() {
  return [
    { type: 'system', subtype: 'init', session_id: 'sess-abc', cwd: '/tmp/ws' },
    {
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hel' } },
    },
    {
      type: 'stream_event',
      event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'lo' } },
    },
    {
      type: 'stream_event',
      event: {
        type: 'content_block_delta',
        delta: { type: 'thinking_delta', thinking: 'hmm' },
      },
    },
    {
      type: 'assistant',
      message: {
        role: 'assistant',
        content: [{ type: 'tool_use', id: 'tu-1', name: 'Read', input: { file_path: '/tmp/ws/a.txt' } }],
      },
    },
    {
      type: 'user',
      message: {
        role: 'user',
        content: [{ type: 'tool_result', tool_use_id: 'tu-1', content: 'file body', is_error: false }],
      },
    },
    {
      type: 'result',
      subtype: 'success',
      result: 'done',
      total_cost_usd: 0.0123,
      duration_ms: 4200,
      usage: { input_tokens: 100, output_tokens: 42 },
    },
    {
      type: 'rate_limit_event',
      rate_limit_info: {
        status: 'allowed_warning',
        resetsAt: 1000,
        rateLimitType: 'five_hour',
        utilization: 87,
      },
    },
  ];
}

// ---- Message → AgentEvent mapping -------------------------------------------

describe('ClaudeSession — SDK message mapping', () => {
  it('maps each scripted SDK message to the correct AgentEvent, in order', async () => {
    const { ctx, events } = makeCtx();
    const { queryFn, state } = fakeQueryFn(scriptedMessages());
    const session = new ClaudeSession(ctx, { queryFn });

    // context_usage is emitted asynchronously after the result event.
    await waitFor(() => events.some((e) => e.kind === 'context_usage'));
    await session.stop();

    expect(events).toEqual([
      { kind: 'text', text: 'Hel', delta: true },
      { kind: 'text', text: 'lo', delta: true },
      { kind: 'thinking', text: 'hmm', delta: true },
      { kind: 'tool_use', id: 'tu-1', name: 'Read', input: { file_path: '/tmp/ws/a.txt' } },
      { kind: 'tool_result', id: 'tu-1', ok: true, content: 'file body' },
      { kind: 'result', text: 'done', costUsd: 0.0123, tokensIn: 100, tokensOut: 42, durationMs: 4200 },
      { kind: 'context_usage', totalTokens: 1234, maxTokens: 200000, percentage: 0.617 },
      {
        kind: 'error',
        message: 'Rate limit updated.',
        retryable: true,
        rateLimit: {
          resetAt: new Date(1000 * 1000).toISOString(),
          rateLimitType: 'five_hour',
          utilization: 87,
        },
      },
    ]);
    expect(state.contextUsageCalls).toBe(1);
  });

  it('captures sessionId from the init message', async () => {
    const { ctx, events } = makeCtx();
    const { queryFn } = fakeQueryFn(scriptedMessages());
    const session = new ClaudeSession(ctx, { queryFn });

    await waitFor(() => events.some((e) => e.kind === 'result'));
    expect(session.sessionId).toBe('sess-abc');
    await session.stop();
  });

  it('invokes onSessionIdReady exactly once on the first init capture', async () => {
    const captured: string[] = [];
    const { ctx, events } = makeCtx({
      onSessionIdReady: (id) => captured.push(id),
    });
    // Two init messages back-to-back — the second must NOT re-fire the hook
    // (option A: first-capture-only). Different ids in each so a re-fire would
    // be trivially observable.
    const { queryFn } = fakeQueryFn([
      { type: 'system', subtype: 'init', session_id: 'sess-first' },
      { type: 'system', subtype: 'init', session_id: 'sess-second' },
      { type: 'result', subtype: 'success', result: 'done' },
    ]);
    const session = new ClaudeSession(ctx, { queryFn });

    await waitFor(() => events.some((e) => e.kind === 'result'));
    expect(captured).toEqual(['sess-first']);
    // sessionId itself tracks the most recent (existing behavior preserved).
    expect(session.sessionId).toBe('sess-second');
    await session.stop();
  });

  it('does not throw when onSessionIdReady is absent (optional contract)', async () => {
    // The mode must tolerate a ctx that does not wire the callback (older
    // consumers, tests). This exercises the `?.()` optional-call path.
    const { ctx, events } = makeCtx();
    const { queryFn } = fakeQueryFn([
      { type: 'system', subtype: 'init', session_id: 'sess-no-cb' },
      { type: 'result', subtype: 'success', result: 'done' },
    ]);
    const session = new ClaudeSession(ctx, { queryFn });
    await waitFor(() => events.some((e) => e.kind === 'result'));
    expect(session.sessionId).toBe('sess-no-cb');
    await session.stop();
  });

  it('flags a tool_result with is_error:true as ok:false', async () => {
    const { ctx, events } = makeCtx();
    const { queryFn } = fakeQueryFn([
      {
        type: 'user',
        message: {
          role: 'user',
          content: [{ type: 'tool_result', tool_use_id: 'tu-9', content: 'boom', is_error: true }],
        },
      },
    ]);
    const session = new ClaudeSession(ctx, { queryFn });
    await waitFor(() => events.some((e) => e.kind === 'tool_result'));
    expect(events).toContainEqual({ kind: 'tool_result', id: 'tu-9', ok: false, content: 'boom' });
    await session.stop();
  });

  it('turns an SDK stream error into a single retryable error event', async () => {
    const { ctx, events } = makeCtx();
    // A query whose iterator throws mid-stream.
    const query = {
      async *[Symbol.asyncIterator]() {
        yield { type: 'system', subtype: 'init', session_id: 's' };
        throw new Error('stream exploded');
      },
      close() {},
      async getContextUsage() {
        return { totalTokens: 0, maxTokens: 0, percentage: 0 };
      },
    };
    const queryFn: QueryFn = () => query as unknown as ReturnType<QueryFn>;
    new ClaudeSession(ctx, { queryFn });

    await waitFor(() => events.some((e) => e.kind === 'error'));
    const errs = events.filter((e) => e.kind === 'error');
    expect(errs).toHaveLength(1);
    expect(errs[0]).toMatchObject({ kind: 'error', message: 'stream exploded', retryable: true });
  });

  it('stop() aborts the query and closes it', async () => {
    const { ctx } = makeCtx();
    const { queryFn, captured, state } = fakeQueryFn([], { stallForever: true });
    const session = new ClaudeSession(ctx, { queryFn });

    const options = captured.options as { abortController: AbortController };
    expect(options.abortController.signal.aborted).toBe(false);
    await session.stop();
    expect(options.abortController.signal.aborted).toBe(true);
    expect(state.closed).toBe(true);
  });

  it('feeds a sent turn into the SDK prompt stream', async () => {
    const { ctx } = makeCtx();
    const received: unknown[] = [];
    // A query that drains the prompt stream so we can observe the sent turn.
    const query = {
      async *[Symbol.asyncIterator]() {
        // yield nothing; we only need the prompt consumed
      },
      close() {},
      async getContextUsage() {
        return { totalTokens: 0, maxTokens: 0, percentage: 0 };
      },
    };
    const queryFn: QueryFn = ({ prompt }) => {
      void (async () => {
        for await (const msg of prompt) {
          received.push(msg);
          break; // one turn is enough for the assertion
        }
      })();
      return query as unknown as ReturnType<QueryFn>;
    };
    const session = new ClaudeSession(ctx, { queryFn });
    await session.send({ text: 'hello there' });
    await waitFor(() => received.length > 0);
    expect(received[0]).toMatchObject({
      type: 'user',
      message: { role: 'user', content: 'hello there' },
    });
    await session.stop();
  });
});

// ---- query() options: project-config loading --------------------------------

describe('ClaudeSession — query options', () => {
  it('loads project settings via settingSources and passes cwd/model/permissionMode', async () => {
    const { ctx } = makeCtx({ cwd: '/tmp/proj', model: 'opus', permMode: 'plan' });
    const { queryFn, captured } = fakeQueryFn([]);
    const session = new ClaudeSession(ctx, { queryFn });

    const options = captured.options as {
      cwd: string;
      model: string;
      permissionMode: string;
      includePartialMessages: boolean;
      settingSources: string[];
      canUseTool: unknown;
    };
    expect(options.cwd).toBe('/tmp/proj');
    expect(options.model).toBe('opus');
    expect(options.permissionMode).toBe('plan'); // plan passes through
    expect(options.includePartialMessages).toBe(true);
    // The critical option: load user + project + local .claude/ config so
    // subagents/hooks/skills/project-MCP work like the terminal claude.
    expect(options.settingSources).toEqual(['user', 'project', 'local']);
    expect(typeof options.canUseTool).toBe('function');
    await session.stop();
  });

  it('pins the model to the session cwd via the claude_code preset system prompt', async () => {
    // Root cause of the live bug: the SDK forwards cwd to the CLI subprocess, but with
    // an unqualified prompt the model resolves relative paths against $HOME, so files
    // landed in HOME regardless of cwd. The fix appends the working directory to the
    // claude_code preset so relative writes land in ctx.cwd. This asserts the exact
    // option shape the real SDK requires (verified empirically against the live CLI).
    const { ctx } = makeCtx({ cwd: '/tmp/selected-folder' });
    const { queryFn, captured } = fakeQueryFn([]);
    const session = new ClaudeSession(ctx, { queryFn });

    const options = captured.options as {
      systemPrompt: { type: string; preset: string; append: string };
    };
    expect(options.systemPrompt.type).toBe('preset');
    // Preserve the claude_code preset so CLAUDE.md / tools / dynamic sections stay intact.
    expect(options.systemPrompt.preset).toBe('claude_code');
    // The append must name the exact cwd so the model writes there, not to $HOME.
    expect(options.systemPrompt.append).toContain('/tmp/selected-folder');
    expect(options.systemPrompt.append).toMatch(/working directory/i);
    await session.stop();
  });

  it('passes each PermMode natively to the SDK permissionMode', async () => {
    for (const mode of ['default', 'acceptEdits', 'bypassPermissions', 'plan'] as const) {
      const { ctx } = makeCtx({ permMode: mode });
      const { queryFn, captured } = fakeQueryFn([]);
      const session = new ClaudeSession(ctx, { queryFn });
      const options = captured.options as { permissionMode: string };
      expect(options.permissionMode).toBe(mode);
      await session.stop();
    }
  });

  it('sets allowDangerouslySkipPermissions only for bypassPermissions', async () => {
    const { ctx: bypassCtx } = makeCtx({ permMode: 'bypassPermissions' });
    const bypass = fakeQueryFn([]);
    const bypassSession = new ClaudeSession(bypassCtx, { queryFn: bypass.queryFn });
    expect((bypass.captured.options as { allowDangerouslySkipPermissions?: boolean }).allowDangerouslySkipPermissions).toBe(true);
    await bypassSession.stop();

    const { ctx: defaultCtx } = makeCtx({ permMode: 'default' });
    const def = fakeQueryFn([]);
    const defaultSession = new ClaudeSession(defaultCtx, { queryFn: def.queryFn });
    expect((def.captured.options as { allowDangerouslySkipPermissions?: boolean }).allowDangerouslySkipPermissions).toBeUndefined();
    await defaultSession.stop();
  });

  it('exposes the attach_file MCP tool and allowlists it when sendFile is wired', async () => {
    const { ctx } = makeCtx();
    const { queryFn, captured } = fakeQueryFn([]);
    const session = new ClaudeSession(ctx, {
      queryFn,
      sendFile: async () => 'sent',
    });
    const options = captured.options as {
      mcpServers?: Record<string, unknown>;
      allowedTools?: string[];
    };
    expect(options.mcpServers?.discord).toBeDefined();
    expect(options.allowedTools).toContain('mcp__discord__attach_file');
    await session.stop();
  });
});

// ---- canUseTool bridging ----------------------------------------------------

describe('makeCanUseTool', () => {
  const opts = { signal: new AbortController().signal, toolUseID: 'tu-x' };

  it('auto-allows a tool in the allowlist without calling requestPermission', async () => {
    const { ctx, permissionCalls } = makeCtx({ allowedTools: ['Read', 'Grep'] });
    const canUse = makeCanUseTool(ctx);
    const result = await canUse('Read', { file_path: '/x' }, opts);
    expect(result).toEqual({ behavior: 'allow', updatedInput: { file_path: '/x' } });
    expect(permissionCalls).toHaveLength(0);
  });

  it('auto-allows a tool in autoAllowClaudeTools without prompting', async () => {
    const { ctx, permissionCalls } = makeCtx({ autoAllowClaudeTools: ['WebFetch'] });
    const canUse = makeCanUseTool(ctx);
    const result = await canUse('WebFetch', {}, opts);
    expect(result.behavior).toBe('allow');
    expect(permissionCalls).toHaveLength(0);
  });

  it('prompts via requestPermission for a tool not on the allowlist and honors allow', async () => {
    const { ctx, permissionCalls } = makeCtx({
      allowedTools: ['Read'],
      permissionDecision: { behavior: 'allow' },
    });
    const canUse = makeCanUseTool(ctx);
    const result = await canUse('Bash', { command: 'ls' }, opts);
    expect(permissionCalls).toEqual([{ toolName: 'Bash', input: { command: 'ls' } }]);
    expect(result).toEqual({ behavior: 'allow', updatedInput: { command: 'ls' } });
  });

  it('honors a deny decision and carries its message', async () => {
    const { ctx, permissionCalls } = makeCtx({
      permissionDecision: { behavior: 'deny', message: 'nope' },
    });
    const canUse = makeCanUseTool(ctx);
    const result = await canUse('Bash', { command: 'rm -rf /' }, opts);
    expect(permissionCalls).toHaveLength(1);
    expect(result).toEqual({ behavior: 'deny', message: 'nope' });
  });
});

// ---- Capabilities (§5a) -----------------------------------------------------

describe('ClaudeMode capabilities', () => {
  it('match the §5a Claude capability shape', () => {
    const mode = new ClaudeMode();
    expect(mode.name).toBe('claude');
    expect(mode.capabilities).toEqual({
      streaming: true,
      thinking: true,
      toolThreads: true,
      permissionPrompts: true,
      progress: false,
      transcript: false,
      sessionResume: true,
      fileAttach: true,
      fileDiff: true,
      usagePanel: true,
      // Full SDK-synced permission-mode set (incl. dontAsk/auto) from providerCatalog.
      permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan', 'dontAsk', 'auto'],
    });
  });
});

// ---- mcpFileTool confinement ------------------------------------------------

describe('attachFileConfined — path confinement', () => {
  let root: string;

  beforeEach(() => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-mcp-'));
  });
  afterEach(() => {
    fs.rmSync(root, { recursive: true, force: true });
  });

  it('accepts a path inside the workspace and forwards it to sendFile', async () => {
    const inside = path.join(root, 'report.txt');
    fs.writeFileSync(inside, 'hi');
    const forwarded: string[] = [];
    const res = await attachFileConfined(
      root,
      async (abs) => {
        forwarded.push(abs);
        return 'ok';
      },
      'report.txt',
    );
    expect(res.isError).toBeFalsy();
    expect(forwarded).toHaveLength(1);
    expect(fs.realpathSync(forwarded[0])).toBe(fs.realpathSync(inside));
  });

  it('rejects a path that escapes the workspace and never calls sendFile', async () => {
    let called = false;
    const res = await attachFileConfined(
      root,
      async () => {
        called = true;
        return 'ok';
      },
      '../../etc/passwd',
    );
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toMatch(/outside the session workspace/);
    expect(called).toBe(false);
  });
});
