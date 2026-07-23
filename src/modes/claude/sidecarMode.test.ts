import { describe, it, expect } from 'vitest';
import { PassThrough } from 'node:stream';
import type { AgentEvent, ModeContext, ModeSession, TurnInput } from '../../core/contracts.js';
import type { ClaudeSessionDeps } from './session.js';
import { ClaudeMode } from './index.js';
import { ClaudeSidecarClient, isClaudeSidecarEnabled, resolveClaudeSidecarSpawn } from './sidecarClient.js';
import { SidecarServer } from '../../sidecar/claude/server.js';

function makeFakeFactory(script: {
  onSend?: (turn: TurnInput, ctx: ModeContext) => void | Promise<void>;
  sessionId?: string | null;
  resumeIdEcho?: boolean;
}) {
  return (ctx: ModeContext, deps: ClaudeSessionDeps): ModeSession => {
    let closed = false;
    if (script.sessionId) {
      void Promise.resolve().then(() => ctx.onSessionIdReady?.(script.sessionId!));
    }
    return {
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
      async interrupt() {},
      async setModel() {},
      async setEffort() {},
    };
  };
}

async function openPairedClient(createSession: ReturnType<typeof makeFakeFactory>): Promise<{
  client: ClaudeSidecarClient;
  close: () => Promise<void>;
}> {
  const hostOut = new PassThrough();
  const serverOut = new PassThrough();
  const server = new SidecarServer({
    input: hostOut,
    output: serverOut,
    createSession,
    listSessionsFn: async () => [
      {
        sessionId: 'listed-sidecar',
        summary: 'From sidecar',
        lastModified: Date.UTC(2026, 2, 1),
        cwd: '/work',
      },
    ],
    logger: { debug() {}, info() {}, warn() {}, error() {} },
  });
  const runPromise = server.run();
  const client = new ClaudeSidecarClient({
    transport: { input: hostOut, output: serverOut },
    requestTimeoutMs: 3000,
  });
  await client.connect();
  return {
    client,
    async close() {
      await client.close();
      hostOut.end();
      await runPromise.catch(() => {});
    },
  };
}

function makeCtx(): { ctx: ModeContext; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd: '/work',
    ownerId: 'u1',
    permMode: 'default',
    emit: (ev) => events.push(ev),
    requestPermission: async () => ({ behavior: 'allow' }),
    config: {},
    logger: { debug() {}, info() {}, warn() {}, error() {} },
    audit: () => {},
  };
  return { ctx, events };
}

async function waitFor(pred: () => boolean, ms = 1000): Promise<void> {
  const start = Date.now();
  while (!pred()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await new Promise((r) => setTimeout(r, 5));
  }
}

describe('isClaudeSidecarEnabled / resolveClaudeSidecarSpawn', () => {
  it('isClaudeSidecarEnabled reads 1/true only', () => {
    expect(isClaudeSidecarEnabled({})).toBe(false);
    expect(isClaudeSidecarEnabled({ DAB_CLAUDE_SIDECAR: '0' })).toBe(false);
    expect(isClaudeSidecarEnabled({ DAB_CLAUDE_SIDECAR: '1' })).toBe(true);
    expect(isClaudeSidecarEnabled({ DAB_CLAUDE_SIDECAR: 'true' })).toBe(true);
  });

  it('resolveClaudeSidecarSpawn honors DAB_CLAUDE_SIDECAR_CMD override', () => {
    const r = resolveClaudeSidecarSpawn({
      DAB_CLAUDE_SIDECAR_CMD: 'node /tmp/custom-cli.js --flag',
    });
    expect(r).toEqual({ command: 'node', args: ['/tmp/custom-cli.js', '--flag'] });
  });
});

describe('ClaudeMode useSidecar + injected client', () => {
  it('start/send/stop go through sidecar (not in-process ClaudeSession)', async () => {
    const pair = await openPairedClient(
      makeFakeFactory({
        sessionId: 'be-sidecar',
        onSend: async (turn, ctx) => {
          ctx.emit({ kind: 'text', text: `via-sidecar:${turn.text}`, delta: false });
          ctx.emit({ kind: 'result', text: 'ok' });
        },
      }),
    );

    const mode = new ClaudeMode({
      useSidecar: true,
      sidecarClient: pair.client,
    });
    const { ctx, events } = makeCtx();
    const session = await mode.start(ctx);
    expect(session.sessionId).toBe('be-sidecar');

    await session.send({ text: 'ping' });
    await waitFor(() => events.some((e) => e.kind === 'text'));
    expect(events.find((e) => e.kind === 'text')).toEqual({
      kind: 'text',
      text: 'via-sidecar:ping',
      delta: false,
    });

    await session.stop();
    await pair.close();
  });

  it('resume passes backendSessionId; listResumable uses sessions.list', async () => {
    const pair = await openPairedClient(
      makeFakeFactory({
        // resume path: sessionId comes from resumeId on the fake when no sessionId script
      }),
    );

    const mode = new ClaudeMode({
      useSidecar: true,
      sidecarClient: pair.client,
    });
    const { ctx } = makeCtx();
    const session = await mode.resume(ctx, 'resume-me');
    expect(session.sessionId).toBe('resume-me');

    const listed = await mode.listResumable(ctx);
    expect(listed).toEqual([
      {
        sessionId: 'listed-sidecar',
        cwd: '/work',
        label: 'From sidecar',
        updatedAt: new Date(Date.UTC(2026, 2, 1)).toISOString(),
      },
    ]);

    await session.stop();
    await pair.close();
  });

  it('without useSidecar, listSessionsFn still works (default path unchanged)', async () => {
    const mode = new ClaudeMode({
      listSessionsFn: async () => [
        {
          sessionId: 'inproc',
          summary: 'In process',
          lastModified: Date.UTC(2026, 0, 1),
          cwd: '/work',
        },
      ],
    });
    const listed = await mode.listResumable(makeCtx().ctx);
    expect(listed[0]?.sessionId).toBe('inproc');
  });
});
