import { describe, it, expect, vi } from 'vitest';
import { SessionWiring } from './wiring.js';
import { EventBus } from '../core/eventBus.js';
import { ModeRegistry } from '../core/modeRegistry.js';
import { createLogger } from '../core/logger.js';
import { parseCustomId } from './renderers/permissionButtons.js';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  PermissionDecision,
} from '../core/contracts.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { AuditLog } from '../core/auditLog.js';
import type { AuditEntry } from '../core/contracts.js';
import type { UsageResult, UsageService } from '../core/usageService.js';
import type { ConfigStore } from '../core/config.js';
import type { ServerConfig } from '../core/configSchema.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from './ports.js';

const logger = createLogger('test', { level: 'error', sink: { write() {} } });

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

class StubMode implements AgentMode {
  constructor(readonly name: string, readonly capabilities: Capabilities) {}
  async start(_ctx: ModeContext): Promise<ModeSession> {
    return { sessionId: 's', async send() {}, async stop() {} };
  }
  async resume(_ctx: ModeContext, id: string): Promise<ModeSession> {
    return { sessionId: id, async send() {}, async stop() {} };
  }
}

// A fake MessageChannel port that records every sent message and hands back an
// editable handle. The permission handler posts its buttons through this.
function fakeChannel(): { channel: MessageChannel; sent: OutgoingMessage[] } {
  const sent: OutgoingMessage[] = [];
  const channel: MessageChannel = {
    send: async (message: OutgoingMessage): Promise<EditableMessage> => {
      sent.push(message);
      return { id: `m${sent.length}`, async edit() {} };
    },
    startThread: async () => {
      throw new Error('not used');
    },
  };
  return { channel, sent };
}

function makeWiring(opts: {
  channel: MessageChannel;
  permissionTimeoutSec?: number;
  usage?: UsageResult;
  ownerId?: string;
  auditLog?: AuditLog;
  onAlwaysAllow?: (tool: string, ctx: { actorId: string; guildId: string; channelId: string }) => void;
  // A server config the wiring reads at attach() to resolve notifications. When set,
  // configStore is injected so the notifier is wired.
  server?: ServerConfig | null;
  // Per-channelId resolver override (default: everything resolves to opts.channel),
  // so a test can hand the status channel a distinct sink from the session channel.
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
}) {
  const eventBus = new EventBus();
  const modeRegistry = new ModeRegistry();
  modeRegistry.register(new StubMode('claude', CLAUDE_CAPS));
  modeRegistry.register(new StubMode('codex', { ...CLAUDE_CAPS, usagePanel: false }));
  const channelRegistry = {
    get: () => ({ ownerId: opts.ownerId ?? 'owner' }),
  } as unknown as ChannelRegistry;
  const usageService = {
    isAvailable: () => opts.usage !== undefined,
    getUsage: async () => opts.usage ?? { available: false as const, reason: 'no-credentials' as const },
  } as unknown as UsageService;
  const configStore =
    opts.server !== undefined
      ? ({ loadServerConfig: () => opts.server } as unknown as ConfigStore)
      : undefined;
  const wiring = new SessionWiring({
    eventBus,
    modeRegistry,
    channelRegistry,
    usageService,
    logger,
    resolveChannel: opts.resolveChannel ?? (async () => opts.channel),
    permissionTimeoutSec: opts.permissionTimeoutSec ?? 60,
    ...(opts.auditLog ? { auditLog: opts.auditLog } : {}),
    ...(opts.onAlwaysAllow ? { onAlwaysAllow: opts.onAlwaysAllow } : {}),
    ...(configStore ? { configStore } : {}),
  });
  return { wiring, eventBus };
}

// A fake AuditLog that captures recorded entries in memory (no fs). Only record()
// is exercised by the wiring, so the rest is left unimplemented.
function fakeAuditLog(): { auditLog: AuditLog; records: (AuditEntry & { timestamp: string })[] } {
  const records: (AuditEntry & { timestamp: string })[] = [];
  const auditLog = {
    record: (entry: AuditEntry) => {
      const rec = { ...entry, timestamp: 't0' };
      records.push(rec);
      return rec;
    },
  } as unknown as AuditLog;
  return { auditLog, records };
}

// Extract the perm request id from the buttons the handler posted (customId
// perm:<reqId>:allow). Returns the reqId or null.
function reqIdFromSent(sent: OutgoingMessage[]): string | null {
  for (const m of sent) {
    for (const row of m.components ?? []) {
      for (const c of row.components) {
        if (c.type === 'button') {
          const parsed = parseCustomId(c.customId);
          if (parsed) return parsed.reqId;
        }
      }
    }
  }
  return null;
}

const binding = { guildId: 'g1', channelId: 'c1', ownerId: 'owner' };

describe('SessionWiring.requestPermission', () => {
  it('resolves via a simulated Allow button', async () => {
    const { channel, sent } = fakeChannel();
    const { wiring } = makeWiring({ channel });
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(binding, { toolName: 'Bash', input: { command: 'ls' } });
    // Let the buttons post (request() posts asynchronously).
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent);
    expect(reqId).not.toBeNull();

    // Simulate the user clicking Allow.
    const resolved = await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:allow`);
    expect(resolved).toEqual({ behavior: 'allow' });

    const decision = await decisionP;
    expect(decision.behavior).toBe('allow');
  });

  it('a resolve from a NON-owner actor is ignored; the owner resolves it', async () => {
    const { channel, sent } = fakeChannel();
    // The prompt is bound to the session owner via binding.ownerId.
    const { wiring } = makeWiring({ channel, ownerId: 'owner' });
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(binding, { toolName: 'Bash', input: { command: 'rm' } });
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent)!;

    // A bystander (different execute-tier user) clicks Allow → ignored, stays pending.
    const bystander = await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:allow`, 'bystander');
    expect(bystander).toBeNull();

    // The owner clicks Allow → now it resolves.
    const owner = await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:allow`, 'owner');
    expect(owner).toEqual({ behavior: 'allow' });
    const decision = await decisionP;
    expect(decision.behavior).toBe('allow');
  });

  it('always-allow records an audit entry with the actor id before persisting', async () => {
    const { channel, sent } = fakeChannel();
    const { auditLog, records } = fakeAuditLog();
    const persisted: { tool: string; actorId: string }[] = [];
    const { wiring } = makeWiring({
      channel,
      ownerId: 'owner',
      auditLog,
      onAlwaysAllow: (tool, ctx) => persisted.push({ tool, actorId: ctx.actorId }),
    });
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(binding, { toolName: 'Bash', input: {} });
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent)!;

    await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:always`, 'owner');
    await decisionP;

    // The GLOBAL always-allow write is audited with the actor + tool + channel.
    const entry = records.find((r) => r.action === 'always-allow');
    expect(entry).toBeDefined();
    expect(entry).toMatchObject({
      actorId: 'owner',
      action: 'always-allow',
      tool: 'Bash',
      guildId: 'g1',
      channelId: 'c1',
    });
    // And the persistence still ran with the same actor.
    expect(persisted).toEqual([{ tool: 'Bash', actorId: 'owner' }]);
  });

  it('a simulated Deny button resolves to deny', async () => {
    const { channel, sent } = fakeChannel();
    const { wiring } = makeWiring({ channel });
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(binding, { toolName: 'Bash', input: {} });
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent)!;
    await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:deny`);
    const decision = await decisionP;
    expect(decision.behavior).toBe('deny');
  });

  it('times out → deny (no button click)', async () => {
    vi.useFakeTimers();
    try {
      const { channel } = fakeChannel();
      const { wiring } = makeWiring({ channel, permissionTimeoutSec: 1 });
      await wiring.attach('g1', 'c1', 'claude');

      const decisionP = wiring.requestPermission(binding, { toolName: 'Bash', input: {} });
      await vi.advanceTimersByTimeAsync(1100);
      const decision = await decisionP;
      expect(decision.behavior).toBe('deny');
      expect(decision.message).toContain('timed out');
    } finally {
      vi.useRealTimers();
    }
  });

  it('permissionTimeoutSec=0 waits indefinitely; no timer-driven auto-deny', async () => {
    vi.useFakeTimers();
    try {
      const { channel, sent } = fakeChannel();
      // 0 = "no timer, infinite wait" — a slow responder must not be auto-denied.
      const { wiring } = makeWiring({ channel, permissionTimeoutSec: 0 });
      await wiring.attach('g1', 'c1', 'claude');

      const decisionP = wiring.requestPermission(binding, { toolName: 'Bash', input: {} });
      // Let the buttons post so a reqId is available.
      await Promise.resolve();
      await Promise.resolve();
      const reqId = reqIdFromSent(sent)!;

      // Advance far beyond any reasonable timeout: no timer, decision still pending.
      await vi.advanceTimersByTimeAsync(60 * 60 * 1000);
      let settled: PermissionDecision | null = null;
      void decisionP.then((d) => {
        settled = d;
      });
      await Promise.resolve();
      expect(settled).toBeNull();

      // The owner eventually clicks Allow — that value is what flows back.
      await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:allow`, 'owner');
      const decision = await decisionP;
      expect(decision).toEqual({ behavior: 'allow' });
    } finally {
      vi.useRealTimers();
    }
  });

  it('denies when the channel is not wired (no live prompt possible)', async () => {
    const { channel } = fakeChannel();
    const { wiring } = makeWiring({ channel });
    // No attach() → not wired.
    const decision = await wiring.requestPermission(binding, { toolName: 'Bash', input: {} });
    expect(decision.behavior).toBe('deny');
  });
});

describe('SessionWiring rendering + sendFile', () => {
  it('subscribing renders an emitted AgentEvent to the channel; detach stops it', async () => {
    const { channel, sent } = fakeChannel();
    const { wiring, eventBus } = makeWiring({ channel });
    await wiring.attach('g1', 'c1', 'claude');

    eventBus.emit('g1', 'c1', { kind: 'error', message: 'boom', retryable: false });
    await Promise.resolve();
    expect(sent.some((m) => (m.content ?? '').includes('boom'))).toBe(true);

    const before = sent.length;
    wiring.detach('g1', 'c1');
    eventBus.emit('g1', 'c1', { kind: 'error', message: 'again', retryable: false });
    await Promise.resolve();
    expect(sent.length).toBe(before); // no new render after detach
  });

  it('detach cancels an armed stream timer: no late channel.send after stop', async () => {
    vi.useFakeTimers();
    try {
      const { channel, sent } = fakeChannel();
      const { wiring, eventBus } = makeWiring({ channel });
      await wiring.attach('g1', 'c1', 'claude');

      // A streaming text delta arms the debounce timer (default 1s) but does not
      // send yet. This is a turn in flight.
      eventBus.emit('g1', 'c1', { kind: 'text', text: 'partial…', delta: true });
      const before = sent.length;

      // /stop mid-stream: detach must cancel the armed timer.
      wiring.detach('g1', 'c1');

      // Fire everything the debounce could have scheduled.
      await vi.advanceTimersByTimeAsync(5000);

      // No streaming embed was ever posted — the timer was cancelled on detach.
      expect(sent.length).toBe(before);
    } finally {
      vi.useRealTimers();
    }
  });

  it('sendFileFor posts the confined file to the bound channel', async () => {
    const { channel, sent } = fakeChannel();
    const { wiring } = makeWiring({ channel });
    await wiring.attach('g1', 'c1', 'claude');
    const send = wiring.sendFileFor('g1', 'c1');
    const msg = await send('/ws/out.txt', 'out.txt');
    expect(msg).toContain('out.txt');
    const fileMsg = sent.find((m) => m.files && m.files.length > 0);
    expect(fileMsg?.files?.[0]).toEqual({ path: '/ws/out.txt', name: 'out.txt' });
  });
});

describe('SessionWiring notifications forwarding', () => {
  const serverWithStatus = (over: Partial<NonNullable<ServerConfig['notifications']>> = {}): ServerConfig =>
    ({
      version: 1,
      guildId: 'g1',
      channels: { categoryId: 'a', controlChannelId: 'b', sessionsCategoryId: 'c', statusChannelId: 'status-1' },
      notifications: { ...over },
    }) as ServerConfig;

  // Resolve the session channel to `session` and the status channel to `status`.
  function splitResolver(session: MessageChannel, status: MessageChannel) {
    return async (channelId: string): Promise<MessageChannel | null> =>
      channelId === 'status-1' ? status : session;
  }

  it('forwards a session result to the resolved status channel', async () => {
    const session = fakeChannel();
    const status = fakeChannel();
    const { wiring, eventBus } = makeWiring({
      channel: session.channel,
      server: serverWithStatus(),
      resolveChannel: splitResolver(session.channel, status.channel),
    });
    await wiring.attach('g1', 'c1', 'claude');

    eventBus.emit('g1', 'c1', { kind: 'result', tokensIn: 1, tokensOut: 2 });
    await Promise.resolve();

    expect(status.sent.some((m) => (m.content ?? '').includes('완료'))).toBe(true);
  });

  it('does not forward when notifications are disabled', async () => {
    const session = fakeChannel();
    const status = fakeChannel();
    const { wiring, eventBus } = makeWiring({
      channel: session.channel,
      server: serverWithStatus({ enabled: false }),
      resolveChannel: splitResolver(session.channel, status.channel),
    });
    await wiring.attach('g1', 'c1', 'claude');

    eventBus.emit('g1', 'c1', { kind: 'result' });
    await Promise.resolve();
    expect(status.sent.length).toBe(0);
  });

  it('skips self-echo when the session channel IS the status channel', async () => {
    const session = fakeChannel();
    // The status channel id equals the session channel id → self-echo, no notifier.
    const server = {
      version: 1,
      guildId: 'g1',
      notifications: { channelId: 'c1' },
    } as ServerConfig;
    const { wiring, eventBus } = makeWiring({ channel: session.channel, server });
    await wiring.attach('g1', 'c1', 'claude');

    eventBus.emit('g1', 'c1', { kind: 'result' });
    await Promise.resolve();
    // The notifier never subscribed (self-echo guard), so no compact "✅ … 완료" summary
    // line was echoed back into the session channel (the renderer's own result/mention
    // output is unrelated and does not carry the notifier's ✅-완료 format).
    expect(session.sent.some((m) => (m.content ?? '').startsWith('✅'))).toBe(false);
  });

  it('detach stops forwarding to the status channel', async () => {
    const session = fakeChannel();
    const status = fakeChannel();
    const { wiring, eventBus } = makeWiring({
      channel: session.channel,
      server: serverWithStatus(),
      resolveChannel: splitResolver(session.channel, status.channel),
    });
    await wiring.attach('g1', 'c1', 'claude');
    wiring.detach('g1', 'c1');

    eventBus.emit('g1', 'c1', { kind: 'result' });
    await Promise.resolve();
    expect(status.sent.length).toBe(0);
  });
});
