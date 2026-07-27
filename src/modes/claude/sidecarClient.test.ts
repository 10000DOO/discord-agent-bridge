import { describe, it, expect } from 'vitest';
import { PassThrough } from 'node:stream';
import type { AgentEvent, ModeContext, ModeSession, TurnInput } from '../../core/contracts.js';
import type { ClaudeSessionDeps } from './session.js';
import { ClaudeSidecarClient } from './sidecarClient.js';
import { SidecarServer } from '../../sidecar/claude/server.js';

// ---- shared fake session + duplex plumbing ----------------------------------

function makeFakeFactory(script: {
  onSend?: (turn: TurnInput, ctx: ModeContext, deps: ClaudeSessionDeps) => void | Promise<void>;
  sessionId?: string | null;
}) {
  return (ctx: ModeContext, deps: ClaudeSessionDeps): ModeSession => {
    let closed = false;
    if (script.sessionId) {
      queueMicrotask(() => ctx.onSessionIdReady?.(script.sessionId!));
    }
    return {
      get sessionId() {
        return script.sessionId ?? deps.resumeId ?? null;
      },
      async send(turn) {
        if (closed) throw new Error('closed');
        await script.onSend?.(turn, ctx, deps);
      },
      async stop() {
        closed = true;
      },
      async interrupt() {},
      async setModel() {},
      async setEffort() {},
    };
  };
}

async function openPairedClient(createSession: ReturnType<typeof makeFakeFactory>): Promise<{
  client: ClaudeSidecarClient;
  server: SidecarServer;
  runPromise: Promise<void>;
  close: () => Promise<void>;
}> {
  // Host writes to hostOut → server input; server writes to serverOut → host input.
  const hostOut = new PassThrough();
  const serverOut = new PassThrough();

  const server = new SidecarServer({
    input: hostOut,
    output: serverOut,
    createSession,
    listSessionsFn: async () => [
      {
        sessionId: 'listed-1',
        summary: 'Listed',
        lastModified: Date.UTC(2026, 5, 1),
        cwd: '/tmp/ws',
      },
    ],
    logger: { debug() {}, info() {}, warn() {}, error() {} },
  });
  const runPromise = server.run();

  const client = new ClaudeSidecarClient({
    transport: {
      input: hostOut,
      output: serverOut,
    },
    requestTimeoutMs: 3000,
  });
  await client.connect();

  return {
    client,
    server,
    runPromise,
    async close() {
      await client.close();
      hostOut.end();
      await runPromise.catch(() => {});
    },
  };
}

function makeCtx(): { ctx: ModeContext; events: AgentEvent[]; permissions: Array<{ toolName: string; input: unknown }> } {
  const events: AgentEvent[] = [];
  const permissions: Array<{ toolName: string; input: unknown }> = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd: '/tmp/ws',
    ownerId: 'u1',
    permMode: 'default',
    emit: (ev) => events.push(ev),
    requestPermission: async (req) => {
      permissions.push(req);
      return { behavior: 'allow' };
    },
    config: {},
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    audit: () => {},
  };
  return { ctx, events, permissions };
}

async function waitFor(pred: () => boolean, ms = 1000): Promise<void> {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await new Promise((r) => setTimeout(r, 5));
  }
}

// ---- tests ------------------------------------------------------------------

describe('ClaudeSidecarClient ↔ SidecarServer (duplex streams)', () => {
  it('openModeSession → send streams text+result events → stop', async () => {
    const pair = await openPairedClient(
      makeFakeFactory({
        sessionId: 'be-99',
        onSend: async (turn, ctx) => {
          ctx.emit({ kind: 'text', text: `got:${turn.text}`, delta: true });
          ctx.emit({ kind: 'result', text: 'ok' });
        },
      }),
    );

    const { ctx, events } = makeCtx();
    const sessionIds: string[] = [];
    ctx.onSessionIdReady = (id) => sessionIds.push(id);

    const session = await pair.client.openModeSession(ctx);
    expect(session.sessionId).toBe('be-99');

    await waitFor(() => sessionIds.includes('be-99'));

    await session.send({ text: 'hi' });
    await waitFor(() => events.some((e) => e.kind === 'text'));
    await waitFor(() => events.some((e) => e.kind === 'result'));

    expect(events.filter((e) => e.kind === 'text')).toEqual([
      { kind: 'text', text: 'got:hi', delta: true },
    ]);
    expect(events.some((e) => e.kind === 'result')).toBe(true);

    await session.stop();
    await pair.close();
  });

  it('permission_request event → host requestPermission → session.permission', async () => {
    const pair = await openPairedClient(
      makeFakeFactory({
        // Like ClaudeSession: send returns; permission is async on the tool path.
        onSend: async (_turn, ctx) => {
          void (async () => {
            const decision = await ctx.requestPermission({
              toolName: 'Edit',
              input: { path: 'a.ts' },
            });
            ctx.emit({
              kind: 'text',
              text: `decided:${decision.behavior}`,
              delta: false,
            });
          })();
        },
      }),
    );

    const { ctx, events, permissions } = makeCtx();
    const session = await pair.client.openModeSession(ctx);
    await session.send({ text: 'edit' });

    await waitFor(() => permissions.length === 1);
    expect(permissions[0]).toEqual({ toolName: 'Edit', input: { path: 'a.ts' } });

    await waitFor(() =>
      events.some((e) => e.kind === 'text' && (e as { text: string }).text === 'decided:allow'),
    );
    // permission_request must NOT be re-emitted on host emit path
    expect(events.every((e) => e.kind !== 'permission_request')).toBe(true);

    await session.stop();
    await pair.close();
  });

  it('sessions.list over the client', async () => {
    const pair = await openPairedClient(makeFakeFactory({}));
    const sessions = await pair.client.sessionsList('/tmp/ws', 5);
    expect(sessions).toEqual([
      {
        sessionId: 'listed-1',
        cwd: '/tmp/ws',
        label: 'Listed',
        updatedAt: new Date(Date.UTC(2026, 5, 1)).toISOString(),
      },
    ]);
    await pair.close();
  });

  it('host.file.attach reverse RPC: fake session sendFile → onFileAttach', async () => {
    let attachMsg: string | undefined;
    const pair = await openPairedClient(
      makeFakeFactory({
        onSend: async (_turn, _ctx, deps) => {
          // Sidecar SessionBridge always wires sendFile via requestHost.
          expect(deps.sendFile).toBeTypeOf('function');
          attachMsg = await deps.sendFile!('/tmp/ws/out.txt', 'out.txt');
        },
      }),
    );

    const { ctx } = makeCtx();
    const session = await pair.client.openModeSession(ctx, {
      sendFile: async (path, name) => {
        expect(path).toBe('/tmp/ws/out.txt');
        expect(name).toBe('out.txt');
        return 'ok sent';
      },
    });

    await session.send({ text: 'attach please' });
    await waitFor(() => attachMsg === 'ok sent');
    expect(attachMsg).toBe('ok sent');

    await session.stop();
    await pair.close();
  });

  it('host.file.share reverse RPC: fake session shareDocument → onFileShare', async () => {
    let shareOk: boolean | undefined;
    const pair = await openPairedClient(
      makeFakeFactory({
        onSend: async (_turn, _ctx, deps) => {
          expect(deps.shareDocument).toBeTypeOf('function');
          const res = await deps.shareDocument!('docs/note.md');
          shareOk = res.ok;
        },
      }),
    );

    const { ctx } = makeCtx();
    const session = await pair.client.openModeSession(ctx, {
      shareDocument: async (path) => {
        expect(path).toBe('docs/note.md');
        return { ok: true, threadName: '📄 note.md', path: 'docs/note.md' };
      },
    });

    await session.send({ text: 'share please' });
    await waitFor(() => shareOk === true);
    expect(shareOk).toBe(true);

    await session.stop();
    await pair.close();
  });
});
