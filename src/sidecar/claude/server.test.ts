import { describe, it, expect, vi } from 'vitest';
import { PassThrough } from 'node:stream';
import type { ModeContext, ModeSession, TurnInput } from '../../core/contracts.js';
import type { ClaudeSessionDeps } from '../../modes/claude/session.js';
import { SidecarServer } from './server.js';
import {
  parseEnvelope,
  serializeEnvelope,
  req,
  res,
  type Envelope,
} from './protocol.js';

// ---- helpers ----------------------------------------------------------------

function collectLines(stream: PassThrough): { lines: string[]; waitFor: (pred: (lines: string[]) => boolean, ms?: number) => Promise<void> } {
  const lines: string[] = [];
  let buf = '';
  stream.on('data', (chunk: Buffer | string) => {
    buf += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    let idx: number;
    while ((idx = buf.indexOf('\n')) >= 0) {
      lines.push(buf.slice(0, idx));
      buf = buf.slice(idx + 1);
    }
  });
  async function waitFor(pred: (lines: string[]) => boolean, ms = 1000): Promise<void> {
    const start = Date.now();
    while (!pred(lines)) {
      if (Date.now() - start > ms) throw new Error(`waitFor timed out; lines=${JSON.stringify(lines)}`);
      await new Promise((r) => setTimeout(r, 5));
    }
  }
  return { lines, waitFor };
}

function envs(lines: string[]): Envelope[] {
  return lines.filter((l) => l.trim().length > 0).map((l) => parseEnvelope(l));
}

/** Fake ModeSession that records sends and can emit events / request permissions. */
function makeFakeSessionFactory(script: {
  onSend?: (turn: TurnInput, ctx: ModeContext) => void | Promise<void>;
  sessionId?: string | null;
  supportInterrupt?: boolean;
  supportSetModel?: boolean;
  supportSetEffort?: boolean;
} = {}) {
  const created: Array<{ ctx: ModeContext; deps: ClaudeSessionDeps; session: ModeSession }> = [];

  const createSession = (ctx: ModeContext, deps: ClaudeSessionDeps): ModeSession => {
    let closed = false;
    const session: ModeSession = {
      get sessionId() {
        return script.sessionId ?? deps.resumeId ?? null;
      },
      async send(turn) {
        if (closed) throw new Error('closed');
        await script.onSend?.(turn, ctx);
      },
      async stop() {
        closed = true;
      },
      ...(script.supportInterrupt !== false
        ? {
            async interrupt() {
              /* ok */
            },
          }
        : {}),
      ...(script.supportSetModel !== false
        ? {
            async setModel(_model?: string) {
              /* ok */
            },
          }
        : {}),
      ...(script.supportSetEffort !== false
        ? {
            async setEffort(_effort?: string) {
              /* ok */
            },
          }
        : {}),
    };
    created.push({ ctx, deps, session });
    // Fire backend id async if provided
    if (script.sessionId) {
      queueMicrotask(() => ctx.onSessionIdReady?.(script.sessionId!));
    }
    return session;
  };

  return { createSession, created };
}

async function startServer(opts: {
  createSession?: ReturnType<typeof makeFakeSessionFactory>['createSession'];
  listSessionsFn?: (o: { dir?: string; limit?: number }) => Promise<
    Array<{
      sessionId: string;
      summary?: string;
      lastModified?: number;
      cwd?: string;
      firstPrompt?: string;
    }>
  >;
}) {
  const hostToSidecar = new PassThrough();
  const sidecarToHost = new PassThrough();
  const out = collectLines(sidecarToHost);

  const server = new SidecarServer({
    input: hostToSidecar,
    output: sidecarToHost,
    ...(opts.createSession ? { createSession: opts.createSession } : {}),
    ...(opts.listSessionsFn
      ? { listSessionsFn: opts.listSessionsFn as never }
      : { listSessionsFn: async () => [] }),
    logger: { debug() {}, info() {}, warn() {}, error() {} },
  });

  const runPromise = server.run();

  await out.waitFor((ls) => envs(ls).some((e) => e.type === 'notify' && e.method === 'sidecar.ready'));

  function send(env: Envelope): void {
    hostToSidecar.write(serializeEnvelope(env) + '\n');
  }

  async function rpc(method: string, params?: Record<string, unknown>, session?: string): Promise<Envelope> {
    const id = `t-${method}-${Math.random().toString(36).slice(2, 8)}`;
    send(req(id, method, params, session));
    await out.waitFor((ls) =>
      envs(ls).some((e) => e.type === 'res' && e.id === id),
    );
    return envs(out.lines).find((e) => e.type === 'res' && e.id === id)!;
  }

  return {
    hostToSidecar,
    out,
    server,
    runPromise,
    send,
    rpc,
    async endInput() {
      hostToSidecar.end();
      await runPromise;
    },
  };
}

// ---- tests ------------------------------------------------------------------

describe('SidecarServer with fake session factory', () => {
  it('start → text event on send → stop', async () => {
    const { createSession, created } = makeFakeSessionFactory({
      onSend: async (turn, ctx) => {
        ctx.emit({ kind: 'text', text: `echo:${turn.text}`, delta: false });
        ctx.emit({ kind: 'result', text: 'done' });
      },
      sessionId: 'backend-1',
    });

    const h = await startServer({ createSession });

    const startRes = await h.rpc('session.start', {
      cwd: '/tmp/ws',
      guildId: 'g1',
      channelId: 'c1',
      permMode: 'default',
    });
    expect(startRes.error).toBeUndefined();
    expect(startRes.result).toMatchObject({
      session: expect.stringMatching(/^s-/),
      backendSessionId: 'backend-1',
    });
    const handle = (startRes.result as { session: string }).session;
    expect(created).toHaveLength(1);
    expect(created[0]!.ctx.cwd).toBe('/tmp/ws');

    // backend_id notify from onSessionIdReady
    await h.out.waitFor((ls) =>
      envs(ls).some(
        (e) =>
          e.type === 'notify' &&
          e.method === 'session.backend_id' &&
          e.session === handle,
      ),
    );

    const sendRes = await h.rpc('session.send', { session: handle, text: 'hello' });
    expect(sendRes.result).toEqual({ ok: true });

    await h.out.waitFor((ls) =>
      envs(ls).some(
        (e) =>
          e.type === 'event' &&
          e.session === handle &&
          e.event?.kind === 'text' &&
          (e.event as { text: string }).text === 'echo:hello',
      ),
    );
    await h.out.waitFor((ls) =>
      envs(ls).some((e) => e.type === 'event' && e.event?.kind === 'result'),
    );

    const stopRes = await h.rpc('session.stop', { session: handle });
    expect(stopRes.result).toEqual({ ok: true });

    // unknown session after stop
    const bad = await h.rpc('session.send', { session: handle, text: 'x' });
    expect(bad.error?.code).toBe('unknown_session');

    await h.endInput();
  });

  it('session.permission round-trip via requestPermission', async () => {
    // Mirror real ClaudeSession: send() returns after queueing; permission is async.
    const { createSession } = makeFakeSessionFactory({
      onSend: async (_turn, ctx) => {
        void (async () => {
          const decision = await ctx.requestPermission({
            toolName: 'Bash',
            input: { command: 'ls' },
          });
          ctx.emit({
            kind: 'text',
            text: `perm:${decision.behavior}`,
            delta: false,
          });
        })();
      },
    });

    const h = await startServer({ createSession });
    const startRes = await h.rpc('session.start', {
      cwd: '/w',
      guildId: 'g',
      channelId: 'c',
      permMode: 'default',
    });
    const handle = (startRes.result as { session: string }).session;

    const sendRes = await h.rpc('session.send', { session: handle, text: 'use tool' });
    expect(sendRes.result).toEqual({ ok: true });

    await h.out.waitFor((ls) =>
      envs(ls).some(
        (e) =>
          e.type === 'event' &&
          e.event?.kind === 'permission_request' &&
          (e.event as { toolName: string }).toolName === 'Bash',
      ),
    );
    const permEv = envs(h.out.lines).find(
      (e) => e.type === 'event' && e.event?.kind === 'permission_request',
    )!;
    const requestId = (permEv.event as { id: string }).id;

    const permRes = await h.rpc('session.permission', {
      session: handle,
      requestId,
      behavior: 'allow',
    });
    expect(permRes.result).toEqual({ ok: true });

    await h.out.waitFor((ls) =>
      envs(ls).some(
        (e) =>
          e.type === 'event' &&
          e.event?.kind === 'text' &&
          (e.event as { text: string }).text === 'perm:allow',
      ),
    );

    await h.endInput();
  });

  it('sessions.list maps injected listSessionsFn', async () => {
    const listSessionsFn = vi.fn(async ({ dir, limit }: { dir?: string; limit?: number }) => {
      expect(dir).toBe('/proj');
      expect(limit).toBe(10);
      return [
        {
          sessionId: 'sid-a',
          summary: 'Work',
          lastModified: Date.UTC(2026, 0, 1),
          cwd: '/proj',
        },
      ];
    });

    const h = await startServer({
      createSession: makeFakeSessionFactory().createSession,
      listSessionsFn,
    });

    const listRes = await h.rpc('sessions.list', { cwd: '/proj', limit: 10 });
    expect(listRes.error).toBeUndefined();
    expect(listRes.result).toEqual({
      sessions: [
        {
          sessionId: 'sid-a',
          cwd: '/proj',
          label: 'Work',
          updatedAt: new Date(Date.UTC(2026, 0, 1)).toISOString(),
        },
      ],
    });
    expect(listSessionsFn).toHaveBeenCalledTimes(1);

    await h.endInput();
  });

  it('returns unsupported for unknown methods', async () => {
    const h = await startServer({
      createSession: makeFakeSessionFactory().createSession,
    });
    const r = await h.rpc('session.frobnicate', {});
    expect(r.error?.code).toBe('unsupported');
    await h.endInput();
  });

  it('invalid_request when session.start missing cwd', async () => {
    const h = await startServer({
      createSession: makeFakeSessionFactory().createSession,
    });
    const r = await h.rpc('session.start', {
      guildId: 'g',
      channelId: 'c',
      permMode: 'default',
    });
    expect(r.error?.code).toBe('invalid_request');
    await h.endInput();
  });

  it('host.file.attach reverse RPC: sendFile deps → host res', async () => {
    let captured: string | undefined;
    const { createSession, created } = makeFakeSessionFactory({
      onSend: async (_turn, _ctx) => {
        // Call the reverse-RPC-backed sendFile wired by SessionBridge.
        const deps = created[0]!.deps;
        expect(deps.sendFile).toBeTypeOf('function');
        captured = await deps.sendFile!('/abs/report.pdf', 'report.pdf');
      },
    });

    const h = await startServer({ createSession });
    const startRes = await h.rpc('session.start', {
      cwd: '/tmp/ws',
      guildId: 'g1',
      channelId: 'c1',
      permMode: 'default',
    });
    const handle = (startRes.result as { session: string }).session;

    // When send runs, sidecar will emit host.file.attach req; answer it.
    const sendPromise = h.rpc('session.send', { session: handle, text: 'go' });

    await h.out.waitFor((ls) =>
      envs(ls).some(
        (e) => e.type === 'req' && e.method === 'host.file.attach' && e.session === handle,
      ),
    );
    const attachReq = envs(h.out.lines).find(
      (e) => e.type === 'req' && e.method === 'host.file.attach',
    )!;
    expect(attachReq.params).toEqual({ path: '/abs/report.pdf', name: 'report.pdf' });

    h.send(
      res(
        attachReq.id!,
        'host.file.attach',
        { ok: true, message: 'ok sent' },
        handle,
      ),
    );

    const sendRes = await sendPromise;
    expect(sendRes.result).toEqual({ ok: true });
    expect(captured).toBe('ok sent');

    await h.endInput();
  });

  it('host.file.share reverse RPC: shareDocument deps → host res', async () => {
    let shareResult: { ok: boolean; path?: string } | undefined;
    const { createSession, created } = makeFakeSessionFactory({
      onSend: async () => {
        const deps = created[0]!.deps;
        expect(deps.shareDocument).toBeTypeOf('function');
        shareResult = await deps.shareDocument!('notes.md');
      },
    });

    const h = await startServer({ createSession });
    const startRes = await h.rpc('session.start', {
      cwd: '/w',
      guildId: 'g',
      channelId: 'c',
      permMode: 'default',
    });
    const handle = (startRes.result as { session: string }).session;

    const sendPromise = h.rpc('session.send', { session: handle, text: 'share' });

    await h.out.waitFor((ls) =>
      envs(ls).some((e) => e.type === 'req' && e.method === 'host.file.share'),
    );
    const shareReq = envs(h.out.lines).find(
      (e) => e.type === 'req' && e.method === 'host.file.share',
    )!;
    expect(shareReq.params).toEqual({ path: 'notes.md' });

    h.send(
      res(
        shareReq.id!,
        'host.file.share',
        { ok: true, threadName: '📄 notes.md', path: 'notes.md' },
        handle,
      ),
    );

    await sendPromise;
    expect(shareResult).toEqual({
      ok: true,
      threadName: '📄 notes.md',
      path: 'notes.md',
    });

    await h.endInput();
  });
});
