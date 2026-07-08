import { describe, it, expect, vi } from 'vitest';
import * as os from 'node:os';
import * as path from 'node:path';
import type { AgentEvent, ModeConfigView, ModeContext, PermMode } from '../../core/contracts.js';
import { CodexMode, CodexSession, resolveCodexHome } from './index.js';
import type { RunCodexTurnOptions, RunCodexTurnResult } from './runner.js';
import type { CodexDiscovery } from './discovery.js';
import type { ResumableSession } from '../../core/contracts.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

// Build a ModeContext whose config is a ModeConfigView; captures emitted events.
function makeCtx(opts: {
  cwd?: string;
  permMode?: PermMode;
  config?: Partial<ModeConfigView>;
  onSessionIdReady?: (id: string) => void;
} = {}): { ctx: ModeContext; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd: opts.cwd ?? '/tmp/ws',
    ownerId: 'u1',
    permMode: opts.permMode ?? 'default',
    emit: (ev) => events.push(ev),
    requestPermission: async () => ({ behavior: 'deny' }),
    config: { codexTimeoutMs: 5_000, ...opts.config },
    logger: nullLogger,
    audit: () => {},
    ...(opts.onSessionIdReady !== undefined ? { onSessionIdReady: opts.onSessionIdReady } : {}),
  };
  return { ctx, events };
}

// A runTurn double: records each call's options and returns a scripted result.
function makeRunTurn(results: RunCodexTurnResult[]): {
  runTurn: (opts: RunCodexTurnOptions) => Promise<RunCodexTurnResult>;
  calls: RunCodexTurnOptions[];
} {
  const calls: RunCodexTurnOptions[] = [];
  let i = 0;
  const runTurn = async (o: RunCodexTurnOptions): Promise<RunCodexTurnResult> => {
    calls.push(o);
    return results[Math.min(i++, results.length - 1)];
  };
  return { runTurn, calls };
}

const okResult = (sessionId: string | null): RunCodexTurnResult => ({
  status: 'completed',
  sessionId,
  finalMessage: 'done',
  exitCode: 0,
});

describe('CodexMode.capabilities (§5b)', () => {
  it('declares the Codex capability shape: no streaming/thinking/threads/prompts/usage; transcript+progress+resume', () => {
    const caps = new CodexMode().capabilities;
    expect(caps).toEqual({
      streaming: false,
      thinking: false,
      toolThreads: false,
      permissionPrompts: false,
      progress: true,
      transcript: true,
      sessionResume: true,
      fileAttach: false,
      fileDiff: false,
      usagePanel: false,
      permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
    });
    // The two Codex-defining flags, called out explicitly.
    expect(caps.permissionPrompts).toBe(false);
    expect(caps.usagePanel).toBe(false);
    expect(caps.transcript).toBe(true);
  });
});

describe('CodexMode.start / CodexSession.send', () => {
  it('start() returns a session whose send() calls runCodexTurn with the permMode + cwd', async () => {
    const { runTurn, calls } = makeRunTurn([okResult('thread-1')]);
    const mode = new CodexMode({ runTurn });
    const { ctx } = makeCtx({ cwd: '/work/proj', permMode: 'acceptEdits' });

    const session = await mode.start(ctx);
    await session.send({ text: 'hello' });

    expect(calls.length).toBe(1);
    expect(calls[0]?.prompt).toBe('hello');
    expect(calls[0]?.cwd).toBe('/work/proj');
    expect(calls[0]?.permMode).toBe('acceptEdits');
    expect(calls[0]?.resumeId).toBeUndefined(); // fresh turn
    expect(calls[0]?.timeoutMs).toBe(5_000);
  });

  it('captures the sessionId from the first turn and passes it as resumeId on the second', async () => {
    const { runTurn, calls } = makeRunTurn([okResult('thread-xyz'), okResult('thread-xyz')]);
    const mode = new CodexMode({ runTurn });
    const { ctx } = makeCtx();
    const session = await mode.start(ctx);

    expect(session.sessionId).toBeNull();
    await session.send({ text: 'first' });
    expect(session.sessionId).toBe('thread-xyz');
    expect(calls[0]?.resumeId).toBeUndefined();

    await session.send({ text: 'second' });
    expect(calls[1]?.resumeId).toBe('thread-xyz'); // resumes the captured id
  });

  it('passes the Codex model (config.codexModel), NOT ctx.model, and omits -m when codexModel is empty', async () => {
    // With a codexModel set → forwarded.
    const set = makeRunTurn([okResult('t')]);
    const modeSet = new CodexMode({ runTurn: set.runTurn });
    const withModel = makeCtx({ config: { model: 'opus', codexModel: 'gpt-5.1-codex', codexTimeoutMs: 5_000 } });
    await (await modeSet.start(withModel.ctx)).send({ text: 'x' });
    expect(set.calls[0]?.model).toBe('gpt-5.1-codex'); // Codex model, not the Claude 'opus'

    // With codexModel empty → model omitted (codex uses its own config default).
    const empty = makeRunTurn([okResult('t')]);
    const modeEmpty = new CodexMode({ runTurn: empty.runTurn });
    const noModel = makeCtx({ config: { model: 'opus', codexModel: '', codexTimeoutMs: 5_000 } });
    await (await modeEmpty.start(noModel.ctx)).send({ text: 'x' });
    expect(empty.calls[0]?.model).toBeUndefined();
  });

  it('exposes sessionId as readonly on the ModeSession', async () => {
    const { runTurn } = makeRunTurn([okResult('thread-9')]);
    const session = await new CodexMode({ runTurn }).start(makeCtx().ctx);
    await session.send({ text: 'hi' });
    expect(session.sessionId).toBe('thread-9');
  });

  it('invokes onSessionIdReady exactly once on the first fresh turn', async () => {
    const captured: string[] = [];
    const { runTurn, calls } = makeRunTurn([okResult('thread-first'), okResult('thread-first')]);
    const { ctx } = makeCtx({ onSessionIdReady: (id) => captured.push(id) });
    const session = await new CodexMode({ runTurn }).start(ctx);

    // First turn: sessionId flips null → thread-first and the hook fires ONCE.
    await session.send({ text: 'one' });
    expect(captured).toEqual(['thread-first']);
    expect(calls[0]?.resumeId).toBeUndefined();

    // Second turn: session already carries the id, so the hook must NOT fire again.
    await session.send({ text: 'two' });
    expect(captured).toEqual(['thread-first']);
    expect(calls[1]?.resumeId).toBe('thread-first');
  });

  it('does not fire onSessionIdReady on a resumed session (id already set at construction)', async () => {
    // Codex resume(ctx, id) sets sessionId in the constructor; runCodexTurn on
    // the next turn returns the SAME id, so the "first capture" guard suppresses
    // the callback. This matches the option A intent (only fires when the id
    // transitions from null on THIS session).
    const captured: string[] = [];
    const { runTurn } = makeRunTurn([okResult('thread-r')]);
    const { ctx } = makeCtx({ onSessionIdReady: (id) => captured.push(id) });
    const session = await new CodexMode({ runTurn }).resume(ctx, 'thread-r');
    await session.send({ text: 'continue' });
    expect(captured).toEqual([]);
    expect(session.sessionId).toBe('thread-r');
  });
});

describe('CodexMode.resume', () => {
  it('resume() starts a session already bound to the given id and resumes it on the first turn', async () => {
    const { runTurn, calls } = makeRunTurn([okResult('thread-r')]);
    const mode = new CodexMode({ runTurn });
    const { ctx } = makeCtx({ cwd: '' }); // resumed session cwd may be '' (Q4)

    const session = await mode.resume(ctx, 'thread-r');
    expect(session.sessionId).toBe('thread-r');
    await session.send({ text: 'continue' });
    expect(calls[0]?.resumeId).toBe('thread-r');
  });
});

describe('CodexSession.stop', () => {
  it('aborts the IN-FLIGHT turn via the signal the runner is given', async () => {
    // The turn-based controller is cleared once a turn completes, so stop() only kills a
    // turn that is actually running. Hold the turn in flight with a gate, abort, release.
    let capturedSignal: AbortSignal | undefined;
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    const runTurn = vi.fn(async (o: RunCodexTurnOptions) => {
      capturedSignal = o.signal;
      await gate;
      return okResult('t');
    });
    const session = await new CodexMode({ runTurn }).start(makeCtx().ctx);
    const sending = session.send({ text: 'hi' }); // in flight — awaits the gate
    await Promise.resolve();
    await Promise.resolve();

    expect(capturedSignal).toBeInstanceOf(AbortSignal);
    expect(capturedSignal?.aborted).toBe(false);
    await session.stop();
    expect(capturedSignal?.aborted).toBe(true);
    release();
    await sending;
  });

  it('a send() after stop() throws (closed session)', async () => {
    const { runTurn } = makeRunTurn([okResult('t')]);
    const session = await new CodexMode({ runTurn }).start(makeCtx().ctx);
    await session.stop();
    await expect(session.send({ text: 'late' })).rejects.toThrow(/closed/);
  });
});

describe('CodexSession.interrupt', () => {
  it('kills the in-flight turn WITHOUT closing the session; a later send() still runs', async () => {
    // Same gate trick: interrupt() aborts the running turn's child but, unlike stop(),
    // leaves the session open so the NEXT send() runs a fresh/resume turn.
    const signals: (AbortSignal | undefined)[] = [];
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    let turnCount = 0;
    const runTurn = vi.fn(async (o: RunCodexTurnOptions) => {
      signals.push(o.signal);
      // Only the FIRST turn parks on the gate so it is interruptible; later turns resolve
      // at once (so a fresh signal for turn 2 is observed as non-aborted).
      if (turnCount++ === 0) await gate;
      return okResult('thread-i');
    });
    // Cast to the concrete CodexSession: interrupt() is optional on the ModeSession
    // contract but a declared method here.
    const session = (await new CodexMode({ runTurn }).start(makeCtx().ctx)) as CodexSession;
    const first = session.send({ text: 'one' });
    await Promise.resolve();
    await Promise.resolve();

    expect(signals[0]?.aborted).toBe(false);
    await session.interrupt();
    expect(signals[0]?.aborted).toBe(true);
    release();
    await first;

    // Session is NOT closed → a subsequent turn runs with a fresh (non-aborted) signal.
    await session.send({ text: 'two' });
    expect(signals).toHaveLength(2);
    expect(signals[1]?.aborted).toBe(false);
  });

  it('is a no-op when no turn is in flight (idempotent / harmless)', async () => {
    const { runTurn } = makeRunTurn([okResult('t')]);
    const session = (await new CodexMode({ runTurn }).start(makeCtx().ctx)) as CodexSession;
    // Nothing running yet → interrupt() must not throw.
    await expect(session.interrupt()).resolves.toBeUndefined();
    // The session is still usable afterwards.
    await session.send({ text: 'hi' });
    expect(session.sessionId).toBe('t');
  });
});

describe('CodexMode.listResumable', () => {
  it('calls discovery with the resolved codexHome (from config, ~ expanded)', async () => {
    const listResumable =
      vi.fn<(codexHome: string, opts?: { includeSubAgents?: boolean }) => Promise<ResumableSession[]>>(
        async () => [{ sessionId: 's1', cwd: '/work' }],
      );
    const fakeDiscovery = { listResumable } as unknown as CodexDiscovery;
    const mode = new CodexMode({ discovery: fakeDiscovery });
    const { ctx } = makeCtx({ config: { codexHome: '~/.codex', codexTimeoutMs: 5_000 } });

    const sessions = await mode.listResumable(ctx);
    expect(sessions).toEqual([{ sessionId: 's1', cwd: '/work' }]);
    expect(listResumable).toHaveBeenCalledTimes(1);
    expect(listResumable.mock.calls[0]?.[0]).toBe(path.join(os.homedir(), '.codex'));
    expect(listResumable.mock.calls[0]?.[1]).toEqual({}); // includeSubAgents internal/false
  });

  it('defaults codexHome to <home>/.codex when config.codexHome is unset', async () => {
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
