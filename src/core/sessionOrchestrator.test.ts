import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { ConfigStore } from './config.js';
import { CONFIG_VERSION, type AppConfig } from './configSchema.js';
import { StateStore } from './state/store.js';
import { ChannelRegistry } from './channelRegistry.js';
import { ConfigResolver } from './configResolver.js';
import { PermissionResolver } from './permissionResolver.js';
import { AuditLog } from './auditLog.js';
import { EventBus } from './eventBus.js';
import { ModeRegistry } from './modeRegistry.js';
import { createLogger } from './logger.js';
import { SessionOrchestrator } from './sessionOrchestrator.js';
import type {
  AgentEvent,
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  TurnInput,
} from './contracts.js';

const CLAUDE_CAPS: Capabilities = {
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
  permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
};

// A mock ModeSession that records the turns it received (in order) and emits a
// scripted event on each send/stop. A `gate` lets a test hold the FIRST send
// "running" so a second send() must queue behind it — exercising the A4 queue.
class MockSession implements ModeSession {
  sessionId: string | null;
  readonly turns: TurnInput[] = [];
  stopped = false;
  private readonly ctx: ModeContext;
  private readonly gate?: Promise<void>;
  private gateUsed = false;

  constructor(ctx: ModeContext, sessionId: string | null, gate?: Promise<void>) {
    this.ctx = ctx;
    this.sessionId = sessionId;
    this.gate = gate;
  }

  async send(turn: TurnInput): Promise<void> {
    // The first send awaits the gate (if any) while later turns proceed at once,
    // so a test can assert a mid-turn send() is queued, not dropped.
    if (this.gate && !this.gateUsed) {
      this.gateUsed = true;
      await this.gate;
    }
    this.turns.push(turn);
    this.ctx.emit({ kind: 'text', text: turn.text, delta: false });
  }

  async stop(): Promise<void> {
    this.stopped = true;
  }
}

// A mock AgentMode that records ctx it was started/resumed with, and hands back
// a MockSession. `resumeThrows` makes resume() fail so resumeAll() tolerance is
// testable. `gate` is threaded to the session created by start(). `resumables`
// (optional) scripts what listResumable returns so boot recovery paths can be
// exercised.
class MockMode implements AgentMode {
  readonly capabilities: Capabilities = CLAUDE_CAPS;
  readonly startedCtx: ModeContext[] = [];
  readonly resumedCtx: ModeContext[] = [];
  readonly resumedIds: string[] = [];
  lastSession: MockSession | null = null;

  constructor(
    readonly name: string,
    private readonly opts: {
      gate?: Promise<void>;
      resumeThrows?: boolean;
      resumables?: { sessionId: string; cwd: string }[];
    } = {},
  ) {}

  async start(ctx: ModeContext): Promise<ModeSession> {
    this.startedCtx.push(ctx);
    const session = new MockSession(ctx, `sess-${ctx.channelId}`, this.opts.gate);
    this.lastSession = session;
    // Simulate a real backend that emits an init sessionId asynchronously so the
    // orchestrator's onSessionIdReady callback gets exercised end-to-end.
    setImmediate(() => ctx.onSessionIdReady?.(`sess-${ctx.channelId}`));
    return session;
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    if (this.opts.resumeThrows) throw new Error('resume boom');
    this.resumedCtx.push(ctx);
    this.resumedIds.push(sessionId);
    const session = new MockSession(ctx, sessionId);
    this.lastSession = session;
    return session;
  }

  async listResumable(): Promise<{ sessionId: string; cwd: string }[]> {
    return this.opts.resumables ?? [];
  }
}

function makeConfig(): AppConfig {
  return {
    version: CONFIG_VERSION,
    discord: { token: 'placeholder-token', clientId: '000000000' },
    auth: { adminRoleIds: [], executeRoleIds: [], readOnlyRoleIds: [], dmPolicy: 'deny' },
    defaults: {
      mode: 'claude',
      claudeModel: 'opus',
      codexModel: '',
      permissionMode: 'default',
      permissionProfile: null,
      codexHome: '~/.codex',
      codexCliCommand: 'codex',
      codexCliVersion: null,
    },
    limits: { maxSessionsPerUser: 0, permissionTimeoutSec: 60, codexTimeoutMs: 1_800_000 },
    policy: { unknownCommand: 'confirm', allowExtraCommands: [] },
    autoAllowClaudeTools: ['Read', 'Glob', 'Grep'],
    profiles: {},
    usage: { userAgent: 'claude-code', cacheSec: 180 },
    audit: { channelId: null },
    locale: 'ko',
    logLevel: 'error',
    favorites: [],
  };
}

// Wire the chunk-1..3 collaborators against a temp DAB home + a temp workspace,
// so nothing touches ~/.discord-agent-bridge/. Returns the orchestrator and its
// deps so a test can inspect state/audit/registry directly.
function harness(opts: { mode?: MockMode } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-orch-'));
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-ws-'));
  const configStore = new ConfigStore(dir);
  configStore.save(makeConfig());
  const stateStore = new StateStore(dir);
  const channelRegistry = new ChannelRegistry(stateStore);
  const configResolver = new ConfigResolver(configStore, channelRegistry);
  const permissionResolver = new PermissionResolver(configStore, configResolver);
  const auditLog = new AuditLog({ baseDir: dir, now: () => '2026-01-01T00:00:00.000Z' });
  const eventBus = new EventBus();
  const modeRegistry = new ModeRegistry();
  const mode = opts.mode ?? new MockMode('claude');
  modeRegistry.register(mode);
  const logger = createLogger('test', { level: 'error' });
  const orchestrator = new SessionOrchestrator({
    channelRegistry,
    modeRegistry,
    eventBus,
    configResolver,
    permissionResolver,
    auditLog,
    logger,
  });
  return { dir, workspace, orchestrator, channelRegistry, stateStore, auditLog, eventBus, mode };
}

function readAudit(dir: string): Array<Record<string, unknown>> {
  const file = path.join(dir, 'audit', 'audit.jsonl');
  if (!fs.existsSync(file)) return [];
  return fs
    .readFileSync(file, 'utf-8')
    .split('\n')
    .filter((l) => l.length > 0)
    .map((l) => JSON.parse(l) as Record<string, unknown>);
}

describe('SessionOrchestrator', () => {
  const cleanup: string[] = [];
  afterEach(() => {
    for (const d of cleanup.splice(0)) fs.rmSync(d, { recursive: true, force: true });
  });
  beforeEach(() => {
    cleanup.length = 0;
  });

  it('start creates a session and persists the binding', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    const session = await h.orchestrator.start({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      cwd: h.workspace,
      ownerId: 'u1',
    });

    expect(session.sessionId).toBe('sess-c1');
    expect(h.mode.startedCtx).toHaveLength(1);
    expect(h.mode.startedCtx[0]).toMatchObject({ guildId: 'g1', channelId: 'c1', cwd: h.workspace });

    // Binding persisted to the store (source of truth for resume-on-boot).
    const onDisk = new StateStore(h.dir).load();
    expect(onDisk.channels['g1:c1']).toMatchObject({
      mode: 'claude',
      sessionId: 'sess-c1',
      cwd: h.workspace,
      ownerId: 'u1',
      archived: false,
    });
    expect(readAudit(h.dir).some((r) => r.action === 'start')).toBe(true);
  });

  it('threads the resolved tool allowlist onto the started ctx.config (prevents A8)', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      cwd: h.workspace,
      ownerId: 'u1',
    });

    // The mode captured the ctx it was started with; the layered allowlist (the
    // config's autoAllowClaudeTools, since no profile narrows it) must be present
    // on config.allowedTools so the mode reads it instead of re-hardcoding one.
    const ctx = h.mode.startedCtx[0];
    expect(ctx.config.allowedTools).toEqual(['Read', 'Glob', 'Grep']);
    expect(ctx.config.autoAllowClaudeTools).toEqual(['Read', 'Glob', 'Grep']);
  });

  it('threads the resolved tool allowlist onto a resumed ctx.config too', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: 'sess-c1', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });

    await h.orchestrator.resumeAll();

    // resume() built its ctx via the same buildContext path; the resumed mode
    // gets the layered allowlist even though there is no live session override.
    expect(h.mode.resumedCtx).toHaveLength(1);
    expect(h.mode.resumedCtx[0].config.allowedTools).toEqual(['Read', 'Glob', 'Grep']);
  });

  it('start with a wizard model routes it to ctx.model (claude) and persists it on the binding', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({ guildId: 'g1', channelId: 'c1', mode: 'claude', cwd: h.workspace, ownerId: 'u1', model: 'claude-fable-5' });

    // Claude routing: the pick overrides modeConfig.model (default 'opus'), which
    // flows into ctx.model — the field the Claude mode actually reads.
    expect(h.mode.startedCtx[0].model).toBe('claude-fable-5');
    // The binding carries the model (source of truth for reactivation/resume).
    expect(h.channelRegistry.get('g1', 'c1')?.model).toBe('claude-fable-5');
  });

  it('start with mode codex routes the model to ctx.config.codexModel, not ctx.model', async () => {
    const mode = new MockMode('codex');
    const h = harness({ mode });
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({ guildId: 'g1', channelId: 'c1', mode: 'codex', cwd: h.workspace, ownerId: 'u1', model: 'gpt-5.4' });

    // Codex reads its OWN model field (config.codexModel); ctx.model must keep
    // carrying the resolved Claude default, untouched by the codex pick.
    const ctx = mode.startedCtx[0];
    expect(ctx.config.codexModel).toBe('gpt-5.4');
    expect(ctx.model).toBe('opus');
  });

  it('processes queued turns sequentially, in order, dropping none (fixes A4)', async () => {
    // Gate the first send so it stays "running" while a second send arrives.
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    const mode = new MockMode('claude', { gate });
    const h = harness({ mode });
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      cwd: h.workspace,
      ownerId: 'u1',
    });

    const first = await h.orchestrator.send('g1', 'c1', { text: 'first' });
    const second = await h.orchestrator.send('g1', 'c1', { text: 'second' });

    // First started; second queued behind it — neither dropped.
    expect(first.status).toBe('started');
    expect(second.status).toBe('queued');
    // While the first is gated, nothing has been delivered to the mode yet.
    expect(mode.lastSession?.turns.map((t) => t.text)).toEqual([]);

    release();
    // Let the drain loop flush both turns.
    await new Promise((r) => setTimeout(r, 0));
    await new Promise((r) => setTimeout(r, 0));

    expect(mode.lastSession?.turns.map((t) => t.text)).toEqual(['first', 'second']);
  });

  it('rejects a turn file that escapes the workspace and emits an error event', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    const events: AgentEvent[] = [];
    h.eventBus.on('g1', 'c1', (ev) => events.push(ev));

    await h.orchestrator.start({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      cwd: h.workspace,
      ownerId: 'u1',
    });

    // An in-workspace path is accepted (a real file so realpath resolves).
    const insidePath = path.join(h.workspace, 'inside.txt');
    fs.writeFileSync(insidePath, 'x');
    const ok = await h.orchestrator.send('g1', 'c1', {
      text: 'inside',
      files: [{ path: insidePath }],
    });
    expect(ok.status).toBe('started');

    // A traversal path escaping the workspace is rejected before the mode sees it.
    await expect(
      h.orchestrator.send('g1', 'c1', {
        text: 'escape',
        files: [{ path: path.join(h.workspace, '..', 'etc', 'passwd') }],
      }),
    ).rejects.toThrow(/escapes the workspace/);

    await new Promise((r) => setTimeout(r, 0));

    // The escaping turn never reached the mock mode; only the inside turn did.
    expect(h.mode.lastSession?.turns.map((t) => t.text)).toEqual(['inside']);
    // An error event was emitted for the rejected turn.
    expect(events.some((e) => e.kind === 'error' && /escapes the workspace/.test(e.message))).toBe(true);
    // The rejection was audited as denied.
    expect(readAudit(h.dir).some((r) => r.action === 'turn' && r.status === 'denied')).toBe(true);
  });

  it('stop aborts the running session and clears the queue', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      cwd: h.workspace,
      ownerId: 'u1',
    });
    const session = h.mode.lastSession!;

    await h.orchestrator.stop('g1', 'c1');

    expect(session.stopped).toBe(true);
    // After stop, the channel is no longer active (a send throws).
    await expect(h.orchestrator.send('g1', 'c1', { text: 'late' })).rejects.toThrow(/No active session/);
    // The persisted binding is hard-deleted — a subsequent /agent start is required.
    expect(h.channelRegistry.get('g1', 'c1')).toBeUndefined();
    expect(readAudit(h.dir).some((r) => r.action === 'stop')).toBe(true);
  });

  it('stopAll stops sessions across multiple guilds', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({ guildId: 'g1', channelId: 'c1', mode: 'claude', cwd: h.workspace, ownerId: 'u1' });
    const s1 = h.mode.lastSession!;
    await h.orchestrator.start({ guildId: 'g2', channelId: 'c9', mode: 'claude', cwd: h.workspace, ownerId: 'u2' });
    const s2 = h.mode.lastSession!;

    await h.orchestrator.stopAll();

    expect(s1.stopped).toBe(true);
    expect(s2.stopped).toBe(true);
    await expect(h.orchestrator.send('g1', 'c1', { text: 'x' })).rejects.toThrow(/No active session/);
    await expect(h.orchestrator.send('g2', 'c9', { text: 'x' })).rejects.toThrow(/No active session/);
  });

  it('resumeAll rebinds sessions from persisted state via mode.resume', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    // Persist two active bindings and one archived one that must be skipped. c1
    // carries a wizard-chosen model to guard the boot-recovery threading.
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: 'sess-c1', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null, model: 'claude-fable-5' });
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c2', mode: 'claude', sessionId: 'sess-c2', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });
    h.channelRegistry.set({ guildId: 'g2', channelId: 'c3', mode: 'claude', sessionId: 'sess-c3', cwd: h.workspace, ownerId: 'u2', permMode: 'default', profile: null, archived: true });

    await h.orchestrator.resumeAll();

    // Only the two non-archived bindings were resumed.
    expect(h.mode.resumedIds.sort()).toEqual(['sess-c1', 'sess-c2']);
    // Boot recovery threads the persisted model onto the resumed ctx (c1); a binding
    // without one keeps the resolved config default (c2 → 'opus').
    expect(h.mode.resumedCtx[0].model).toBe('claude-fable-5');
    expect(h.mode.resumedCtx[1].model).toBe('opus');
    // A resumed channel is live: a send() is accepted (does not throw "no session").
    await expect(h.orchestrator.send('g1', 'c1', { text: 'after-resume' })).resolves.toMatchObject({ status: 'started' });
  });

  it('resumeAll skips a channel whose resume throws, without failing the others', async () => {
    const mode = new MockMode('claude', { resumeThrows: true });
    const h = harness({ mode });
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: 'sess-c1', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c2', mode: 'claude', sessionId: 'sess-c2', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });

    // Every resume throws, but resumeAll tolerates it and does not reject.
    await expect(h.orchestrator.resumeAll()).resolves.toBeUndefined();

    // No channel became active because each resume failed and was skipped.
    await expect(h.orchestrator.send('g1', 'c1', { text: 'x' })).rejects.toThrow(/No active session/);
  });

  it('skips resume for a null-sessionId binding; on-demand start fires on next send', async () => {
    // A null-sessionId binding is always skipped by resumeAll (no cwd-based
    // catalog auto-recovery); the next send() reactivates the channel via
    // start(). The other (id-carrying) binding still resumes normally.
    const mode = new MockMode('claude');
    const h = harness({ mode });
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: null, cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c2', mode: 'claude', sessionId: 'sess-c2', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });

    await h.orchestrator.resumeAll();

    // The null-sessionId binding is skipped by resumeAll; the other resumes.
    expect(h.mode.resumedIds).toEqual(['sess-c2']);
    // The persisted (non-archived) binding for c1 still exists, so a send on c1
    // triggers on-demand reactivation via start() (fresh session).
    const result = await h.orchestrator.send('g1', 'c1', { text: 'x' });
    expect(result.status).toBe('started');
    expect(h.mode.startedCtx).toHaveLength(1);
    expect(h.mode.startedCtx[0].channelId).toBe('c1');
    // And c2 (already resumed) still accepts turns.
    await expect(h.orchestrator.send('g1', 'c2', { text: 'x' })).resolves.toMatchObject({ status: 'started' });
  });

  it('onSessionIdReady persists the real backend sessionId; a repeat call is a no-op', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      cwd: h.workspace,
      ownerId: 'u1',
    });

    // start() persisted the binding with the MockSession's sessionId already
    // set ("sess-c1"), and the MockMode also fires onSessionIdReady on the same
    // id via setImmediate. Both writes must agree — the persisted id equals
    // the session's id, and the idempotent guard makes the second call a no-op.
    await new Promise((r) => setImmediate(r));
    expect(h.channelRegistry.get('g1', 'c1')?.sessionId).toBe('sess-c1');

    // Simulate a mode surfacing the SAME id again → no-op (idempotent).
    const before = h.channelRegistry.get('g1', 'c1')?.updatedAt;
    h.mode.startedCtx[0].onSessionIdReady?.('sess-c1');
    // updatedAt should not change on a no-op path.
    expect(h.channelRegistry.get('g1', 'c1')?.updatedAt).toBe(before);
  });

  it('onSessionIdReady on an archived binding is a no-op', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    // Start c1 to capture its ctx (the callback is closed over c1's ids).
    await h.orchestrator.start({ guildId: 'g1', channelId: 'c1', mode: 'claude', cwd: h.workspace, ownerId: 'u1' });
    await new Promise((r) => setImmediate(r));
    const cb = h.mode.startedCtx.at(-1)?.onSessionIdReady;
    expect(cb).toBeTypeOf('function');

    // Flip archived directly on the registry (stop() now hard-deletes; this
    // case still guards the archived-flag path for legacy state.json entries).
    h.channelRegistry.markArchived('g1', 'c1');
    expect(h.channelRegistry.get('g1', 'c1')?.archived).toBe(true);
    const beforeUpdatedAt = h.channelRegistry.get('g1', 'c1')?.updatedAt;
    cb?.('late-arrival-id');
    // No mutation on archived binding.
    expect(h.channelRegistry.get('g1', 'c1')?.updatedAt).toBe(beforeUpdatedAt);
    expect(h.channelRegistry.get('g1', 'c1')?.sessionId).toBe('sess-c1');
  });

  it('onSessionIdReady re-persists the sessionId WITHOUT dropping the binding model', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await h.orchestrator.start({ guildId: 'g1', channelId: 'c1', mode: 'claude', cwd: h.workspace, ownerId: 'u1', model: 'claude-fable-5' });
    await new Promise((r) => setImmediate(r));

    // A late backend id (differing from the start-persisted one) triggers a
    // re-persist; the replacing set() must carry the model forward, not drop it.
    h.mode.startedCtx[0].onSessionIdReady?.('real-backend-id');
    const binding = h.channelRegistry.get('g1', 'c1');
    expect(binding?.sessionId).toBe('real-backend-id');
    expect(binding?.model).toBe('claude-fable-5');
  });

  it('send: active absent + binding present with sessionId → auto-resume', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: 'saved-sess', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null, model: 'claude-fable-5' });

    // The channel is persisted but NOT active (resumeAll() was never called).
    const result = await h.orchestrator.send('g1', 'c1', { text: 'hi' });
    expect(result.status).toBe('started');
    expect(h.mode.resumedIds).toEqual(['saved-sess']);
    // The reactivation's RESUME branch threads the persisted model too.
    expect(h.mode.resumedCtx[0].model).toBe('claude-fable-5');
    // Give the queued drain a chance to run so the mock records the turn.
    await new Promise((r) => setTimeout(r, 0));
    expect(h.mode.lastSession?.turns.map((t) => t.text)).toEqual(['hi']);
  });

  it('send: active absent + binding present with sessionId=null → auto-start', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: null, cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });

    const result = await h.orchestrator.send('g1', 'c1', { text: 'hi' });
    expect(result.status).toBe('started');
    // start() was chosen, not resume().
    expect(h.mode.startedCtx).toHaveLength(1);
    expect(h.mode.resumedIds).toEqual([]);
    await new Promise((r) => setTimeout(r, 0));
    expect(h.mode.lastSession?.turns.map((t) => t.text)).toEqual(['hi']);
  });

  it('send: on-demand reactivation threads the persisted binding model onto the ctx', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: null, cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null, model: 'claude-fable-5' });

    // No live session → reactivation rebuilds StartParams from the binding; the
    // persisted model must ride along into the rebuilt ctx and survive re-persist.
    await h.orchestrator.send('g1', 'c1', { text: 'hi' });
    expect(h.mode.startedCtx[0].model).toBe('claude-fable-5');
    expect(h.channelRegistry.get('g1', 'c1')?.model).toBe('claude-fable-5');
  });

  it('send: no binding → throws (unchanged behavior)', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);

    await expect(h.orchestrator.send('g1', 'unknown', { text: 'x' })).rejects.toThrow(/No active session/);
  });

  it('send: archived binding → throws (unchanged behavior)', async () => {
    const h = harness();
    cleanup.push(h.dir, h.workspace);
    h.channelRegistry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: 'sess', cwd: h.workspace, ownerId: 'u1', permMode: 'default', profile: null });
    h.channelRegistry.markArchived('g1', 'c1');

    await expect(h.orchestrator.send('g1', 'c1', { text: 'x' })).rejects.toThrow(/No active session/);
  });
});
