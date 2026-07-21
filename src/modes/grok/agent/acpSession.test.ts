import { describe, it, expect, vi, afterEach } from 'vitest';
import type { AgentEvent, ModeContext, PermMode, PermissionDecision } from '../../../core/contracts.js';
import type { AcpPermissionRequest, AcpPromptResult, AcpSessionMeta, AcpUpdate, GrokAcpClientOptions } from './acpClient.js';
import { GrokAcpSession, type CreateGrokAcpClient } from './acpSession.js';
import { grokConfigSource } from '../configSource.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

// Let queued microtasks/immediates run (parked prompt, async chains).
const flush = (): Promise<void> => new Promise<void>((resolve) => setImmediate(resolve));

function makeCtx(opts: {
  cwd?: string;
  model?: string;
  effort?: string;
  permMode?: PermMode;
  onSessionIdReady?: (id: string) => void;
  requestPermission?: ModeContext['requestPermission'];
} = {}): { ctx: ModeContext; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd: opts.cwd ?? '/tmp/ws',
    ownerId: 'u1',
    ...(opts.model !== undefined ? { model: opts.model } : {}),
    ...(opts.effort !== undefined ? { effort: opts.effort } : {}),
    permMode: opts.permMode ?? 'default',
    emit: (ev) => events.push(ev),
    requestPermission: opts.requestPermission ?? (async () => ({ behavior: 'deny' })),
    config: {},
    logger: nullLogger,
    audit: () => {},
    ...(opts.onSessionIdReady !== undefined ? { onSessionIdReady: opts.onSessionIdReady } : {}),
  };
  return { ctx, events };
}

// A fake GrokAcpClient (no real `grok agent stdio` process). Scriptable updates / prompt error /
// prompt result, and a gate so a test can hold the prompt "in flight" while it interrupts.
class FakeAcpClient {
  initializeCalls = 0;
  sessionNewCalls: { cwd: string; meta?: AcpSessionMeta }[] = [];
  sessionLoadCalls: { sessionId: string; cwd: string }[] = [];
  promptTexts: string[] = [];
  closeCalls = 0;

  updates: AcpUpdate[] = [];
  promptError: Error | null = null;
  gate: Promise<void> | null = null; // when set, the prompt parks here before finishing/throwing
  result: AcpPromptResult | null = {};
  sessionIdToReturn = 'sess-new';
  permissionHandler: ((req: AcpPermissionRequest) => Promise<PermissionDecision>) | null = null;

  async initialize(): Promise<void> {
    this.initializeCalls++;
  }

  async sessionNew(cwd: string, meta?: AcpSessionMeta): Promise<string> {
    this.sessionNewCalls.push({ cwd, ...(meta ? { meta } : {}) });
    return this.sessionIdToReturn;
  }

  async sessionLoad(sessionId: string, cwd: string): Promise<void> {
    this.sessionLoadCalls.push({ sessionId, cwd });
  }

  prompt(input: string | import('./acpClient.js').AcpPromptBlock[]): AsyncIterableIterator<AcpUpdate> {
    if (typeof input === 'string') this.promptTexts.push(input);
    else {
      const text = input.find((b) => b.type === 'text');
      this.promptTexts.push(text && text.type === 'text' ? text.text : JSON.stringify(input));
    }
    const updates = this.updates;
    const gate = this.gate;
    const errOf = (): Error | null => this.promptError;
    async function* gen(): AsyncGenerator<AcpUpdate> {
      for (const u of updates) yield u;
      if (gate) await gate;
      const err = errOf();
      if (err) throw err;
    }
    return gen();
  }

  onPermissionRequest(cb: (req: AcpPermissionRequest) => Promise<PermissionDecision>): void {
    this.permissionHandler = cb;
  }

  async close(): Promise<void> {
    this.closeCalls++;
  }

  get lastPromptResult(): AcpPromptResult | null {
    return this.result;
  }

  // Test helper: simulate the agent's server→client permission ask. Mirrors the real client's
  // handlePermission wrapper (safe 'deny' when no handler is wired or the handler throws) so a test
  // drives the session's wiring through the same contract without a real `grok agent stdio`.
  async triggerPermission(req: AcpPermissionRequest): Promise<PermissionDecision> {
    if (!this.permissionHandler) return { behavior: 'deny' };
    try {
      return await this.permissionHandler(req);
    } catch {
      return { behavior: 'deny' };
    }
  }
}

// A factory that hands out fake clients and records the options each was created with. `configure`
// tweaks each fake before it is returned (e.g. script updates / an error).
function makeFactory(configure?: (c: FakeAcpClient) => void): {
  createClient: CreateGrokAcpClient;
  clients: FakeAcpClient[];
  options: GrokAcpClientOptions[];
} {
  const clients: FakeAcpClient[] = [];
  const options: GrokAcpClientOptions[] = [];
  const createClient: CreateGrokAcpClient = (opts) => {
    options.push(opts);
    const c = new FakeAcpClient();
    if (configure) configure(c);
    clients.push(c);
    return c;
  };
  return { createClient, clients, options };
}

const nonResultEvents = (events: AgentEvent[]): AgentEvent[] => events.filter((e) => e.kind !== 'result');

describe('GrokAcpSession lifecycle', () => {
  it('lazily inits on the first send: initialize → session/new, and fires onSessionIdReady once', async () => {
    const captured: string[] = [];
    const { createClient, clients } = makeFactory();
    const { ctx } = makeCtx({ onSessionIdReady: (id) => captured.push(id) });
    const session = new GrokAcpSession(ctx, { createClient });

    expect(session.sessionId).toBeNull();
    expect(clients).toHaveLength(0); // not spawned until send()

    await session.send({ text: 'one' });
    expect(clients).toHaveLength(1);
    expect(clients[0]?.initializeCalls).toBe(1);
    expect(clients[0]?.sessionNewCalls).toHaveLength(1);
    expect(session.sessionId).toBe('sess-new');
    expect(captured).toEqual(['sess-new']);

    // Second turn reuses the live client (no new session/new) and does NOT refire onSessionIdReady.
    await session.send({ text: 'two' });
    expect(clients).toHaveLength(1);
    expect(clients[0]?.sessionNewCalls).toHaveLength(1);
    expect(clients[0]?.promptTexts).toEqual(['one', 'two']);
    expect(captured).toEqual(['sess-new']);
  });

  it('maps the resume path onto session/load (not session/new) without firing onSessionIdReady', async () => {
    const captured: string[] = [];
    const { createClient, clients } = makeFactory();
    const { ctx } = makeCtx({ cwd: '/work/proj', onSessionIdReady: (id) => captured.push(id) });
    const session = new GrokAcpSession(ctx, { createClient, resumeId: 'sess-r' });

    expect(session.sessionId).toBe('sess-r'); // known upfront
    await session.send({ text: 'continue' });
    expect(clients[0]?.sessionLoadCalls).toEqual([{ sessionId: 'sess-r', cwd: '/work/proj' }]);
    expect(clients[0]?.sessionNewCalls).toHaveLength(0);
    expect(captured).toEqual([]); // resume never refires
  });

  it('passes cwd/model/effort and maps permMode → bypassPermissions on client creation', async () => {
    const bypass = makeFactory();
    await new GrokAcpSession(makeCtx({ cwd: '/w', model: 'grok-4.5', effort: 'high', permMode: 'bypassPermissions' }).ctx, {
      createClient: bypass.createClient,
    }).send({ text: 'x' });
    expect(bypass.options[0]?.cwd).toBe('/w');
    expect(bypass.options[0]?.model).toBe('grok-4.5');
    expect(bypass.options[0]?.effort).toBe('high');
    expect(bypass.options[0]?.bypassPermissions).toBe(true);

    const def = makeFactory();
    await new GrokAcpSession(makeCtx({ permMode: 'default' }).ctx, { createClient: def.createClient }).send({ text: 'x' });
    expect(def.options[0]?.bypassPermissions).toBe(false);
    expect(def.options[0]?.model).toBeUndefined(); // no ctx.model → flag omitted
  });
});

describe('GrokAcpSession update → AgentEvent mapping (D5)', () => {
  it('maps agent_message_chunk/agent_thought_chunk/tool_call/tool_call_update to the right kinds', async () => {
    const { createClient, clients } = makeFactory((c) => {
      c.updates = [
        { sessionUpdate: 'agent_message_chunk', content: { text: 'hello' } },
        { sessionUpdate: 'agent_thought_chunk', content: { text: 'pondering' } },
        { sessionUpdate: 'tool_call', toolCallId: 'tc1', title: 'Edit', kind: 'edit', rawInput: { path: 'a.txt' } },
        { sessionUpdate: 'tool_call_update', toolCallId: 'tc1', status: 'completed', content: 'done' },
      ];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });
    expect(clients[0]?.promptTexts).toEqual(['go']);

    expect(nonResultEvents(events)).toEqual([
      { kind: 'text', text: 'hello', delta: true },
      { kind: 'thinking', text: 'pondering', delta: true },
      // path → file_path for DiffView FILE_EDIT_TOOLS
      { kind: 'tool_use', id: 'tc1', name: 'Edit', input: { path: 'a.txt', file_path: 'a.txt' } },
      { kind: 'tool_result', id: 'tc1', ok: true, content: 'done' },
    ]);
    // A result event is always emitted on a clean turn end.
    expect(events.at(-1)).toEqual({ kind: 'result' });
  });

  it('skips empty text/thought chunks, falls back on a missing tool id, and stringifies object content', async () => {
    const { createClient } = makeFactory((c) => {
      c.updates = [
        { sessionUpdate: 'agent_message_chunk', content: { text: '' } },
        { sessionUpdate: 'agent_thought_chunk' },
        { sessionUpdate: 'tool_call', title: 'Read' },
        { sessionUpdate: 'tool_call_update', status: 'failed', rawOutput: { code: 2 } },
      ];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });

    expect(nonResultEvents(events)).toEqual([
      { kind: 'tool_use', id: 'grok-tool-1', name: 'Read', input: {} },
      { kind: 'tool_result', id: '', ok: false, content: JSON.stringify({ code: 2 }) },
    ]);
  });

  it('forwards parentToolId as parentToolUseId on tool_call / tool_call_update', async () => {
    const { createClient } = makeFactory((c) => {
      c.updates = [
        {
          sessionUpdate: 'tool_call',
          toolCallId: 'spawn1',
          title: 'spawn_subagent',
          rawInput: { subagent_type: 'developer' },
        },
        {
          sessionUpdate: 'tool_call',
          toolCallId: 'nested1',
          title: 'Read',
          rawInput: { path: 'a' },
          parentToolId: 'spawn1',
        },
        {
          sessionUpdate: 'tool_call_update',
          toolCallId: 'nested1',
          status: 'completed',
          content: 'ok',
          parentToolId: 'spawn1',
        },
      ];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });

    expect(nonResultEvents(events)).toEqual([
      {
        kind: 'tool_use',
        id: 'spawn1',
        name: 'spawn_subagent',
        input: { subagent_type: 'developer' },
      },
      {
        kind: 'tool_use',
        id: 'nested1',
        name: 'Read',
        input: { path: 'a', file_path: 'a' },
        parentToolUseId: 'spawn1',
      },
      {
        kind: 'tool_result',
        id: 'nested1',
        ok: true,
        content: 'ok',
        parentToolUseId: 'spawn1',
      },
    ]);
  });

  it('surfaces a plan update as one progress event whose detail carries status-marked entries (WO-11)', async () => {
    const { createClient } = makeFactory((c) => {
      c.updates = [
        {
          sessionUpdate: 'plan',
          entries: [
            { content: 'read the file', status: 'completed' },
            { content: 'write the fix', status: 'in_progress' },
            { content: 'run tests', status: 'pending' },
            { status: 'pending' }, // no content → skipped
          ],
        },
      ];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });

    expect(nonResultEvents(events)).toEqual([
      { kind: 'progress', label: 'Plan', detail: '✓ read the file\n▶ write the fix\n• run tests' },
    ]);
  });

  it('emits result tokens best-effort and honors the cost partial guard', async () => {
    const withTokens = makeFactory((c) => {
      c.result = { usage: { input_tokens: 10, output_tokens: 20, total_cost_usd: 0.5 } };
    });
    const a = makeCtx();
    await new GrokAcpSession(a.ctx, { createClient: withTokens.createClient }).send({ text: 'x' });
    expect(a.events.at(-1)).toEqual({ kind: 'result', tokensIn: 10, tokensOut: 20, costUsd: 0.5 });

    const partial = makeFactory((c) => {
      c.result = { usage: { total_cost_usd: 9.9, cost_is_partial: true } };
    });
    const b = makeCtx();
    await new GrokAcpSession(b.ctx, { createClient: partial.createClient }).send({ text: 'x' });
    expect(b.events.at(-1)).toEqual({ kind: 'result' }); // cost dropped, no tokens
  });
});

describe('GrokAcpSession tool_call_update terminal-status only (FIX-1)', () => {
  it('emits exactly ONE tool_result (ok:true) across the intermediate (no status) + terminal (completed) pair', async () => {
    const { createClient } = makeFactory((c) => {
      c.updates = [
        { sessionUpdate: 'tool_call', toolCallId: 'call-1', title: 'write', rawInput: { file_path: 'a.txt', content: 'hi' } },
        // INTERMEDIATE: no status, carries the diff content — must NOT emit a (spurious ok:false) result.
        {
          sessionUpdate: 'tool_call_update',
          toolCallId: 'call-1',
          title: 'Write `a.txt`',
          content: [{ type: 'diff', path: 'a.txt', oldText: '', newText: 'hi' }],
        },
        // TERMINAL: status completed — the one real result.
        { sessionUpdate: 'tool_call_update', toolCallId: 'call-1', status: 'completed', content: [{ type: 'diff', oldText: '', newText: 'hi' }] },
      ];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });

    const results = events.filter((e) => e.kind === 'tool_result');
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject({ id: 'call-1', ok: true });
    expect(results.some((r) => r.kind === 'tool_result' && r.ok === false)).toBe(false);
  });

  it('emits ONE tool_result (ok:false) for a terminal failed update, skipping the intermediate', async () => {
    const { createClient } = makeFactory((c) => {
      c.updates = [
        { sessionUpdate: 'tool_call_update', toolCallId: 'call-2', content: [{ type: 'diff' }] }, // intermediate → skipped
        { sessionUpdate: 'tool_call_update', toolCallId: 'call-2', status: 'failed', content: 'boom' },
      ];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });

    const results = events.filter((e) => e.kind === 'tool_result');
    expect(results).toHaveLength(1);
    expect(results[0]).toEqual({ kind: 'tool_result', id: 'call-2', ok: false, content: 'boom' });
  });
});

describe('GrokAcpSession cost + context_usage from _meta (FIX-2)', () => {
  afterEach(() => vi.restoreAllMocks());

  it('surfaces costUsd on the result and a context_usage panel (model resolved from _meta modelId)', async () => {
    // Stub the model→context-window lookup deterministically (mirrors the path-A runner test's
    // lookupContextWindow seam) so this passes regardless of the machine's ~/.grok.
    vi.spyOn(grokConfigSource, 'contextWindow').mockImplementation((m) => (m === 'grok-4.5' ? 500000 : undefined));
    const { createClient } = makeFactory((c) => {
      c.result = { costUsd: 547336000 / 1e10, totalTokens: 17742, modelId: 'grok-4.5' };
    });
    const { ctx, events } = makeCtx(); // no ctx.model → model resolves from the response modelId
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'x' });

    expect(events.find((e) => e.kind === 'result')).toEqual({ kind: 'result', costUsd: 547336000 / 1e10 });
    expect(events.find((e) => e.kind === 'context_usage')).toEqual({
      kind: 'context_usage',
      totalTokens: 17742,
      maxTokens: 500000,
      percentage: 4, // round(17742 / 500000 * 100)
      model: 'grok-4.5',
    });
  });

  it('skips context_usage when no context window is known for the resolved model (still emits costUsd)', async () => {
    vi.spyOn(grokConfigSource, 'contextWindow').mockReturnValue(undefined);
    const { createClient } = makeFactory((c) => {
      c.result = { costUsd: 0.01, totalTokens: 1000, modelId: 'grok-4.5' };
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'x' });

    expect(events.find((e) => e.kind === 'context_usage')).toBeUndefined();
    expect(events.find((e) => e.kind === 'result')).toEqual({ kind: 'result', costUsd: 0.01 });
  });
});

describe('GrokAcpSession explicit skips (FIX-5)', () => {
  it('does NOT re-render user_message_chunk (grok echo) or available_commands_update (slash-command list)', async () => {
    const { createClient } = makeFactory((c) => {
      c.updates = [{ sessionUpdate: 'user_message_chunk' }, { sessionUpdate: 'available_commands_update' }];
    });
    const { ctx, events } = makeCtx();
    await new GrokAcpSession(ctx, { createClient }).send({ text: 'go' });
    expect(nonResultEvents(events)).toEqual([]);
  });
});

describe('GrokAcpSession error / stop / interrupt', () => {
  it('a prompt error surfaces one error event and drops the client so the next send re-inits (session/load)', async () => {
    let first = true;
    const { createClient, clients } = makeFactory((c) => {
      if (first) {
        c.promptError = new Error('grok agent stdio exited unexpectedly (code 1).');
        first = false;
      }
    });
    const { ctx, events } = makeCtx();
    const session = new GrokAcpSession(ctx, { createClient });

    await session.send({ text: 'boom' });
    expect(events.filter((e) => e.kind === 'error')).toEqual([
      { kind: 'error', message: 'grok agent stdio exited unexpectedly (code 1).', retryable: false },
    ]);
    expect(clients[0]?.closeCalls).toBe(1); // dead client dropped
    expect(session.sessionId).toBe('sess-new'); // id retained from the successful session/new

    // Next send re-inits a NEW client and resumes the same session via session/load.
    await session.send({ text: 'again' });
    expect(clients).toHaveLength(2);
    expect(clients[1]?.sessionLoadCalls).toEqual([{ sessionId: 'sess-new', cwd: '/tmp/ws' }]);
  });

  it('stop() closes the client and a later send() throws', async () => {
    const { createClient, clients } = makeFactory();
    const session = new GrokAcpSession(makeCtx().ctx, { createClient });
    await session.send({ text: 'hi' });
    await session.stop();
    expect(clients[0]?.closeCalls).toBe(1);
    await expect(session.send({ text: 'late' })).rejects.toThrow(/closed/);
  });

  it('interrupt() closes the client mid-turn WITHOUT an error event; the next send resumes the session', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    let first = true;
    const { createClient, clients } = makeFactory((c) => {
      if (first) {
        c.gate = gate;
        c.promptError = new Error('Grok ACP client was closed.'); // what close() induces in the real client
        first = false;
      }
    });
    const { ctx, events } = makeCtx();
    const session = new GrokAcpSession(ctx, { createClient });

    const sending = session.send({ text: 'long' });
    await flush(); // reach the parked prompt (after session/new)
    expect(session.sessionId).toBe('sess-new');

    await session.interrupt();
    expect(clients[0]?.closeCalls).toBe(1);
    release(); // prompt now throws the closed-error → must be swallowed as an intentional cancel
    await sending;

    expect(events.filter((e) => e.kind === 'error')).toHaveLength(0);
    expect(session.sessionId).toBe('sess-new'); // context kept

    await session.send({ text: 'resume-after-interrupt' });
    expect(clients).toHaveLength(2);
    expect(clients[1]?.sessionLoadCalls).toEqual([{ sessionId: 'sess-new', cwd: '/tmp/ws' }]);
  });

  it('interrupt() is harmless when nothing is in flight (idempotent, no throw)', async () => {
    const { createClient, clients } = makeFactory();
    const session = new GrokAcpSession(makeCtx().ctx, { createClient });
    await expect(session.interrupt()).resolves.toBeUndefined(); // never spawned
    expect(clients).toHaveLength(0);
    await session.send({ text: 'hi' });
    expect(session.sessionId).toBe('sess-new');
  });

  it('does NOT implement setModel/setEffort (orchestrator duck-types them as unsupported)', () => {
    const session = new GrokAcpSession(makeCtx().ctx, { createClient: makeFactory().createClient });
    expect((session as { setModel?: unknown }).setModel).toBeUndefined();
    expect((session as { setEffort?: unknown }).setEffort).toBeUndefined();
  });
});

describe('GrokAcpSession permission round-trip (WO-10)', () => {
  it('routes a permission ask through ctx.requestPermission (derives toolName/input) and an ALLOW flows back', async () => {
    const calls: { toolName: string; input: unknown }[] = [];
    const { createClient, clients } = makeFactory();
    const { ctx } = makeCtx({
      requestPermission: async (req) => {
        calls.push(req);
        return { behavior: 'allow' };
      },
    });
    const session = new GrokAcpSession(ctx, { createClient });
    await session.send({ text: 'go' }); // ensureClient wires onPermissionRequest

    const decision = await clients[0]!.triggerPermission({
      requestId: 1,
      toolName: 'Edit',
      input: { path: 'a.txt' },
      toolCall: { title: 'Edit' },
      options: [],
    });

    expect(calls).toEqual([{ toolName: 'Edit', input: { path: 'a.txt' } }]);
    expect(decision).toEqual({ behavior: 'allow' });
  });

  it('falls back to toolName "tool" and input=toolCall, and a DENY flows back', async () => {
    const calls: { toolName: string; input: unknown }[] = [];
    const { createClient, clients } = makeFactory();
    const { ctx } = makeCtx({
      requestPermission: async (req) => {
        calls.push(req);
        return { behavior: 'deny', message: 'nope' };
      },
    });
    const session = new GrokAcpSession(ctx, { createClient });
    await session.send({ text: 'go' });

    const decision = await clients[0]!.triggerPermission({
      requestId: 2,
      toolCall: { some: 'call' },
      options: [],
    });

    expect(calls).toEqual([{ toolName: 'tool', input: { some: 'call' } }]);
    expect(decision).toEqual({ behavior: 'deny', message: 'nope' });
  });

  it('a throwing ctx.requestPermission does not crash the session (client wrapper denies)', async () => {
    const { createClient, clients } = makeFactory();
    const { ctx, events } = makeCtx({
      requestPermission: async () => {
        throw new Error('discord unreachable');
      },
    });
    const session = new GrokAcpSession(ctx, { createClient });
    await session.send({ text: 'go' });

    const decision = await clients[0]!.triggerPermission({ requestId: 3, options: [] });
    expect(decision).toEqual({ behavior: 'deny' });

    // The session is still usable after a failed permission ask (same live client, no error event).
    await session.send({ text: 'again' });
    expect(clients[0]!.promptTexts).toEqual(['go', 'again']);
    expect(events.filter((e) => e.kind === 'error')).toHaveLength(0);
  });
});
