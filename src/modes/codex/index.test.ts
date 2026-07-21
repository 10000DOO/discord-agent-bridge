import { describe, it, expect, vi } from 'vitest';
import * as os from 'node:os';
import * as path from 'node:path';
import type { AgentEvent, ModeConfigView, ModeContext, PermMode } from '../../core/contracts.js';
import { CodexMode, CodexSession, resolveCodexHome, resolveThreadPolicy } from './index.js';
import { codexCatalog } from '../../core/providerCatalog.js';
import type { CodexAppServerClientLike, CreateCodexAppServerClient } from './appSession.js';
import type { CodexDiscovery } from './discovery.js';
import type { ResumableSession } from '../../core/contracts.js';
import type { NotificationHandler } from './appServerClient.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

function makeCtx(opts: {
  cwd?: string;
  permMode?: PermMode | string;
  effort?: string;
  config?: Partial<ModeConfigView>;
  onSessionIdReady?: (id: string) => void;
  requestPermission?: ModeContext['requestPermission'];
} = {}): { ctx: ModeContext; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd: opts.cwd ?? '/tmp/ws',
    ownerId: 'u1',
    ...(opts.effort !== undefined ? { effort: opts.effort } : {}),
    permMode: (opts.permMode ?? 'default') as PermMode,
    emit: (ev) => events.push(ev),
    requestPermission: opts.requestPermission ?? (async () => ({ behavior: 'deny' })),
    config: { codexTimeoutMs: 5_000, ...opts.config },
    logger: nullLogger,
    audit: () => {},
    ...(opts.onSessionIdReady !== undefined ? { onSessionIdReady: opts.onSessionIdReady } : {}),
  };
  return { ctx, events };
}

// Scriptable fake app-server client for session tests.
class FakeClient implements CodexAppServerClientLike {
  readonly notifications: NotificationHandler[] = [];
  readonly calls: Array<{ method: string; params?: unknown }> = [];
  threadIdToReturn = 'thread-xyz';
  turnIdToReturn = 'turn-1';
  autoCompleteTurn = true;
  closed = false;
  failInitialize: Error | null = null;
  lastTurnParams: unknown;
  lastCreateOptions: import('./appServerClient.js').CodexAppServerClientOptions | undefined;

  // Optional delay gate for interrupt tests.
  turnStartGate: Promise<void> | null = null;
  interruptCalls = 0;

  async initialize(): Promise<unknown> {
    this.calls.push({ method: 'initialize' });
    if (this.failInitialize) throw this.failInitialize;
    return {};
  }

  async threadStart(params: {
    cwd: string;
    approvalPolicy: string;
    sandbox: string;
    model?: string;
    dynamicTools?: unknown[];
  }): Promise<string> {
    this.calls.push({ method: 'thread/start', params });
    return this.threadIdToReturn;
  }

  async threadResume(params: { threadId: string }): Promise<unknown> {
    this.calls.push({ method: 'thread/resume', params });
    return {};
  }

  async turnStart(params: {
    threadId: string;
    input: Array<{ type: string; text?: string }>;
    effort?: string;
    model?: string;
  }): Promise<string> {
    this.calls.push({ method: 'turn/start', params });
    this.lastTurnParams = params;
    if (this.turnStartGate) await this.turnStartGate;
    const turnId = this.turnIdToReturn;
    if (this.autoCompleteTurn) {
      setImmediate(() => {
        for (const h of this.notifications) {
          h('item/agentMessage/delta', {
            threadId: params.threadId,
            turnId,
            delta: 'ok',
          });
          h('turn/completed', {
            threadId: params.threadId,
            turnId,
            usage: { inputTokens: 1, outputTokens: 2 },
          });
        }
      });
    }
    return turnId;
  }

  async turnInterrupt(params: { threadId: string; turnId: string }): Promise<unknown> {
    this.interruptCalls += 1;
    this.calls.push({ method: 'turn/interrupt', params });
    return {};
  }

  onNotification(handler: NotificationHandler): () => void {
    this.notifications.push(handler);
    return () => {
      const i = this.notifications.indexOf(handler);
      if (i >= 0) this.notifications.splice(i, 1);
    };
  }

  async close(): Promise<void> {
    this.closed = true;
    this.calls.push({ method: 'close' });
  }

  get isClosed(): boolean {
    return this.closed;
  }

  // Fire a custom notification to active listeners.
  emit(method: string, params: unknown): void {
    for (const h of this.notifications) h(method, params);
  }
}

function makeCreateClient(fake: FakeClient): CreateCodexAppServerClient {
  return (options) => {
    fake.lastCreateOptions = options;
    return fake;
  };
}

describe('CodexMode.capabilities (app-server phase 2)', () => {
  it('declares thinking + usagePanel + fileDiff; fileAttach only when sendFileFor is wired', () => {
    const caps = new CodexMode().capabilities;
    expect(caps).toEqual({
      streaming: true,
      thinking: true,
      toolThreads: true,
      permissionPrompts: true,
      progress: true,
      transcript: false,
      sessionResume: true,
      fileAttach: false,
      fileDiff: true,
      usagePanel: true,
      permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
    });
    const withAttach = new CodexMode({ sendFileFor: () => async () => 'ok' });
    expect(withAttach.capabilities.fileAttach).toBe(true);
  });

  it('exposes the Codex catalog', () => {
    expect(new CodexMode().catalog).toBe(codexCatalog);
  });
});

describe('resolveThreadPolicy', () => {
  it('maps Claude and Codex sandbox modes onto app-server params', () => {
    expect(resolveThreadPolicy('default')).toEqual({
      approvalPolicy: 'on-request',
      sandbox: 'workspace-write',
    });
    expect(resolveThreadPolicy('acceptEdits')).toEqual({
      approvalPolicy: 'never',
      sandbox: 'workspace-write',
    });
    expect(resolveThreadPolicy('bypassPermissions')).toEqual({
      approvalPolicy: 'never',
      sandbox: 'danger-full-access',
    });
    expect(resolveThreadPolicy('plan')).toEqual({
      approvalPolicy: 'on-request',
      sandbox: 'read-only',
    });
    expect(resolveThreadPolicy('read-only')).toEqual({
      approvalPolicy: 'on-request',
      sandbox: 'read-only',
    });
    expect(resolveThreadPolicy('danger-full-access')).toEqual({
      approvalPolicy: 'never',
      sandbox: 'danger-full-access',
    });
  });
});

describe('CodexMode.start / CodexAppSession.send', () => {
  it('start() + send() initialize, thread/start, turn/start and emits mapped events', async () => {
    const fake = new FakeClient();
    const mode = new CodexMode({ createClient: makeCreateClient(fake) });
    const { ctx, events } = makeCtx({ cwd: '/work/proj', permMode: 'acceptEdits' });

    const session = await mode.start(ctx);
    await session.send({ text: 'hello' });

    expect(fake.calls.map((c) => c.method)).toEqual([
      'initialize',
      'thread/start',
      'turn/start',
    ]);
    const startParams = fake.calls.find((c) => c.method === 'thread/start')?.params as {
      cwd: string;
      approvalPolicy: string;
      sandbox: string;
    };
    expect(startParams.cwd).toBe('/work/proj');
    expect(startParams.approvalPolicy).toBe('never'); // acceptEdits
    expect(startParams.sandbox).toBe('workspace-write');

    const turnParams = fake.calls.find((c) => c.method === 'turn/start')?.params as {
      input: Array<{ text?: string }>;
    };
    expect(turnParams.input[0]?.text).toBe('hello');

    expect(session.sessionId).toBe('thread-xyz');
    expect(events.some((e) => e.kind === 'text' && e.delta === true)).toBe(true);
    expect(events.some((e) => e.kind === 'result')).toBe(true);
  });

  it('captures sessionId on first turn and resumes the same thread on second', async () => {
    const fake = new FakeClient();
    const mode = new CodexMode({ createClient: makeCreateClient(fake) });
    const { ctx } = makeCtx();
    const session = await mode.start(ctx);

    expect(session.sessionId).toBeNull();
    await session.send({ text: 'first' });
    expect(session.sessionId).toBe('thread-xyz');

    await session.send({ text: 'second' });
    // Second turn: no new thread/start; same client, another turn/start.
    const threadStarts = fake.calls.filter((c) => c.method === 'thread/start');
    const turnStarts = fake.calls.filter((c) => c.method === 'turn/start');
    expect(threadStarts).toHaveLength(1);
    expect(turnStarts).toHaveLength(2);
  });

  it('passes codexModel on thread/start when set', async () => {
    const fake = new FakeClient();
    const mode = new CodexMode({ createClient: makeCreateClient(fake) });
    const { ctx } = makeCtx({
      config: { model: 'opus', codexModel: 'gpt-5.1-codex', codexTimeoutMs: 5_000 },
    });
    await (await mode.start(ctx)).send({ text: 'x' });
    const params = fake.calls.find((c) => c.method === 'thread/start')?.params as { model?: string };
    expect(params.model).toBe('gpt-5.1-codex');
  });

  it('seeds effort from ctx.effort and setEffort swaps it for the next turn', async () => {
    const fake = new FakeClient();
    const { ctx } = makeCtx({ effort: 'low' });
    const session = await new CodexMode({ createClient: makeCreateClient(fake) }).start(ctx);

    await session.send({ text: 'first' });
    expect((fake.lastTurnParams as { effort?: string }).effort).toBe('low');

    await session.setEffort?.('high');
    await session.send({ text: 'second' });
    expect((fake.lastTurnParams as { effort?: string }).effort).toBe('high');
  });

  it('setEffort empty omits effort on the next turn', async () => {
    const fake = new FakeClient();
    const { ctx } = makeCtx({ effort: 'high' });
    const session = await new CodexMode({ createClient: makeCreateClient(fake) }).start(ctx);
    await session.setEffort?.('');
    await session.send({ text: 'x' });
    expect((fake.lastTurnParams as { effort?: string }).effort).toBeUndefined();
  });

  it('setEffort rejects unsupported values', async () => {
    const fake = new FakeClient();
    const { ctx } = makeCtx({ effort: 'low' });
    const session = await new CodexMode({ createClient: makeCreateClient(fake) }).start(ctx);
    await expect(session.setEffort!('bogus')).rejects.toThrow(/Unsupported reasoning effort/);
  });

  it('invokes onSessionIdReady exactly once on fresh thread/start', async () => {
    const captured: string[] = [];
    const fake = new FakeClient();
    const { ctx } = makeCtx({ onSessionIdReady: (id) => captured.push(id) });
    const session = await new CodexMode({ createClient: makeCreateClient(fake) }).start(ctx);
    await session.send({ text: 'one' });
    await session.send({ text: 'two' });
    expect(captured).toEqual(['thread-xyz']);
  });

  it('does not fire onSessionIdReady on resume (id set at construction)', async () => {
    const captured: string[] = [];
    const fake = new FakeClient();
    const { ctx } = makeCtx({ onSessionIdReady: (id) => captured.push(id) });
    const session = await new CodexMode({ createClient: makeCreateClient(fake) }).resume(ctx, 'thread-r');
    expect(session.sessionId).toBe('thread-r');
    await session.send({ text: 'continue' });
    expect(captured).toEqual([]);
    expect(fake.calls.map((c) => c.method)).toEqual(['initialize', 'thread/resume', 'turn/start']);
  });

  it('emits a single context_usage after result when tokenUsage updates fire mid-turn', async () => {
    const fake = new FakeClient();
    fake.autoCompleteTurn = false;
    const mode = new CodexMode({ createClient: makeCreateClient(fake) });
    const { ctx, events } = makeCtx();
    const session = await mode.start(ctx);

    const sendP = session.send({ text: 'work' });
    // Wait until the notification handler is registered (after turnStart).
    await vi.waitFor(() => expect(fake.notifications.length).toBeGreaterThan(0));

    const usageParams = (totalTokens: number) => ({
      threadId: 'thread-xyz',
      turnId: 'turn-1',
      tokenUsage: {
        total: {
          totalTokens,
          inputTokens: totalTokens,
          outputTokens: 0,
          cachedInputTokens: 0,
          reasoningOutputTokens: 0,
        },
        last: {
          totalTokens: 10,
          inputTokens: 10,
          outputTokens: 0,
          cachedInputTokens: 0,
          reasoningOutputTokens: 0,
        },
        modelContextWindow: 10000,
      },
    });

    // Multiple mid-turn updates must not emit context_usage yet.
    fake.emit('thread/tokenUsage/updated', usageParams(100));
    fake.emit('thread/tokenUsage/updated', usageParams(500));
    fake.emit('thread/tokenUsage/updated', usageParams(2500));
    expect(events.filter((e) => e.kind === 'context_usage')).toHaveLength(0);

    fake.emit('turn/completed', {
      threadId: 'thread-xyz',
      turnId: 'turn-1',
      usage: { inputTokens: 2000, outputTokens: 500 },
    });
    await sendP;

    const usageEvents = events.filter((e) => e.kind === 'context_usage');
    expect(usageEvents).toHaveLength(1);
    expect(usageEvents[0]).toEqual({
      kind: 'context_usage',
      totalTokens: 2500,
      maxTokens: 10000,
      percentage: 25,
    });

    // Order: result first, then context_usage (matches Claude).
    const resultIdx = events.findIndex((e) => e.kind === 'result');
    const usageIdx = events.findIndex((e) => e.kind === 'context_usage');
    expect(resultIdx).toBeGreaterThanOrEqual(0);
    expect(usageIdx).toBeGreaterThan(resultIdx);
  });
});

describe('CodexMode.resume', () => {
  it('resume() binds sessionId immediately and thread/resume on first send', async () => {
    const fake = new FakeClient();
    const mode = new CodexMode({ createClient: makeCreateClient(fake) });
    const { ctx } = makeCtx({ cwd: '' });
    const session = await mode.resume(ctx, 'thread-r');
    expect(session.sessionId).toBe('thread-r');
    await session.send({ text: 'continue' });
    const resume = fake.calls.find((c) => c.method === 'thread/resume');
    expect(resume?.params).toEqual({ threadId: 'thread-r' });
  });
});

describe('CodexSession.stop / interrupt', () => {
  it('stop() closes the client and rejects later send', async () => {
    const fake = new FakeClient();
    const session = await new CodexMode({ createClient: makeCreateClient(fake) }).start(makeCtx().ctx);
    await session.send({ text: 'hi' });
    await session.stop();
    expect(fake.closed).toBe(true);
    await expect(session.send({ text: 'late' })).rejects.toThrow(/closed/);
  });

  it('interrupt() cancels the in-flight turn without closing the session', async () => {
    const fake = new FakeClient();
    fake.autoCompleteTurn = false;
    let release!: () => void;
    fake.turnStartGate = new Promise<void>((r) => {
      release = r;
    });

    const session = (await new CodexMode({ createClient: makeCreateClient(fake) }).start(
      makeCtx().ctx,
    )) as CodexSession;

    const first = session.send({ text: 'one' });

    // Wait until turnStart is parked on the gate (turn/start call recorded).
    for (let i = 0; i < 50 && !fake.calls.some((c) => c.method === 'turn/start'); i++) {
      await new Promise<void>((r) => setImmediate(r));
    }
    expect(fake.calls.some((c) => c.method === 'turn/start')).toBe(true);

    // Release gate so turnStart resolves and the notification wait is armed.
    release();
    for (let i = 0; i < 50 && fake.notifications.length === 0; i++) {
      await new Promise<void>((r) => setImmediate(r));
    }
    expect(fake.notifications.length).toBeGreaterThan(0);

    await session.interrupt();
    await first;

    expect(fake.interruptCalls).toBeGreaterThanOrEqual(1);
    expect(fake.closed).toBe(false);

    // Session remains usable for the next turn.
    fake.autoCompleteTurn = true;
    fake.turnStartGate = null;
    await session.send({ text: 'two' });
    const turns = fake.calls.filter((c) => c.method === 'turn/start');
    expect(turns.length).toBeGreaterThanOrEqual(2);
  });

  it('interrupt() is a no-op when idle', async () => {
    const fake = new FakeClient();
    const session = (await new CodexMode({ createClient: makeCreateClient(fake) }).start(
      makeCtx().ctx,
    )) as CodexSession;
    await expect(session.interrupt()).resolves.toBeUndefined();
    await session.send({ text: 'hi' });
    expect(session.sessionId).toBe('thread-xyz');
  });
});

describe('CodexMode.listResumable', () => {
  it('calls discovery with the resolved codexHome', async () => {
    const listResumable =
      vi.fn<(codexHome: string, opts?: { includeSubAgents?: boolean }) => Promise<ResumableSession[]>>(
        async () => [{ sessionId: 's1', cwd: '/work' }],
      );
    const fakeDiscovery = { listResumable } as unknown as CodexDiscovery;
    const mode = new CodexMode({ discovery: fakeDiscovery });
    const { ctx } = makeCtx({ config: { codexHome: '~/.codex', codexTimeoutMs: 5_000 } });

    const sessions = await mode.listResumable(ctx);
    expect(sessions).toEqual([{ sessionId: 's1', cwd: '/work' }]);
    expect(listResumable.mock.calls[0]?.[0]).toBe(path.join(os.homedir(), '.codex'));
  });

  it('defaults codexHome to <home>/.codex when unset', async () => {
    const listResumable =
      vi.fn<(codexHome: string, opts?: { includeSubAgents?: boolean }) => Promise<ResumableSession[]>>(
        async () => [],
      );
    const fakeDiscovery = { listResumable } as unknown as CodexDiscovery;
    const mode = new CodexMode({ discovery: fakeDiscovery });
    const { ctx } = makeCtx({ config: { codexTimeoutMs: 5_000 } });
    await mode.listResumable(ctx);
    expect(listResumable.mock.calls[0]?.[0]).toBe(path.join(os.homedir(), '.codex'));
  });
});

describe('resolveCodexHome', () => {
  it('expands ~, defaults when empty, and passes absolute paths through', () => {
    expect(resolveCodexHome(undefined)).toBe(path.join(os.homedir(), '.codex'));
    expect(resolveCodexHome('')).toBe(path.join(os.homedir(), '.codex'));
    expect(resolveCodexHome('~')).toBe(os.homedir());
    expect(resolveCodexHome('~/.codex')).toBe(path.join(os.homedir(), '.codex'));
    expect(resolveCodexHome('/abs/codex')).toBe('/abs/codex');
  });
});

describe('CodexAppSession dynamic tool attach_file', () => {
  it('registers dynamicTools on thread/start and handles attach_file via onDynamicToolCall', async () => {
    const fake = new FakeClient();
    const sent: Array<{ path: string; filename?: string }> = [];
    const sendFile = async (absPath: string, filename?: string): Promise<string> => {
      sent.push({ path: absPath, ...(filename !== undefined ? { filename } : {}) });
      return `sent ${path.basename(absPath)}`;
    };
    const mode = new CodexMode({
      createClient: makeCreateClient(fake),
      sendFileFor: () => sendFile,
    });
    const { ctx, events } = makeCtx({ cwd: os.tmpdir() });
    const session = await mode.start(ctx);
    await session.send({ text: 'hi' });

    const startParams = fake.calls.find((c) => c.method === 'thread/start')?.params as {
      dynamicTools?: Array<{ name: string }>;
    };
    expect(startParams.dynamicTools?.[0]?.name).toBe('attach_file');
    expect(fake.lastCreateOptions?.onDynamicToolCall).toBeTypeOf('function');

    // Invoke the handler as app-server would for item/tool/call.
    const handler = fake.lastCreateOptions!.onDynamicToolCall!;
    const filePath = path.join(os.tmpdir(), `dab-attach-${Date.now()}.txt`);
    const fs = await import('node:fs/promises');
    await fs.writeFile(filePath, 'payload', 'utf8');
    try {
      const result = await handler({
        tool: 'attach_file',
        arguments: { path: filePath, filename: 'note.txt' },
        callId: 'dyn-1',
        threadId: 'thread-xyz',
        turnId: 'turn-1',
      });
      expect(result.success).toBe(true);
      expect(result.contentItems[0]).toMatchObject({ type: 'inputText' });
      expect(sent.some((s) => s.filename === 'note.txt')).toBe(true);
      expect(events.some((e) => e.kind === 'tool_use' && e.name === 'attach_file')).toBe(true);
      expect(events.some((e) => e.kind === 'tool_result' && e.ok === true)).toBe(true);
    } finally {
      await fs.unlink(filePath).catch(() => {});
    }
  });

  it('omits dynamicTools when sendFileFor is not wired', async () => {
    const fake = new FakeClient();
    const mode = new CodexMode({ createClient: makeCreateClient(fake) });
    await (await mode.start(makeCtx().ctx)).send({ text: 'x' });
    const startParams = fake.calls.find((c) => c.method === 'thread/start')?.params as {
      dynamicTools?: unknown;
    };
    expect(startParams.dynamicTools).toBeUndefined();
    expect(fake.lastCreateOptions?.onDynamicToolCall).toBeUndefined();
  });
});
