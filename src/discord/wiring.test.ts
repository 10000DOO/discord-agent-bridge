import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
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
import type { UsageResult, UsageService } from '../core/usageService.js';
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
}) {
  const eventBus = new EventBus();
  const modeRegistry = new ModeRegistry();
  modeRegistry.register(new StubMode('claude', CLAUDE_CAPS));
  modeRegistry.register(new StubMode('codex', { ...CLAUDE_CAPS, usagePanel: false }));
  const channelRegistry = {
    get: () => ({ ownerId: 'owner' }),
  } as unknown as ChannelRegistry;
  const usageService = {
    isAvailable: () => opts.usage !== undefined,
    getUsage: async () => opts.usage ?? { available: false as const, reason: 'no-credentials' as const },
  } as unknown as UsageService;
  const wiring = new SessionWiring({
    eventBus,
    modeRegistry,
    channelRegistry,
    usageService,
    logger,
    resolveChannel: async () => opts.channel,
    permissionTimeoutSec: opts.permissionTimeoutSec ?? 60,
  });
  return { wiring, eventBus };
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
