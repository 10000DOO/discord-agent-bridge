import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { SessionWiring } from './wiring.js';
import { EventBus } from '../core/eventBus.js';
import { ModeRegistry } from '../core/modeRegistry.js';
import { createLogger } from '../core/logger.js';
import { ConfigStore } from '../core/config.js';
import { CONFIG_DEFAULTS, CONFIG_VERSION, type AppConfig } from '../core/configSchema.js';
import { parseCustomId } from './renderers/permissionButtons.js';
import { makeCanUseTool } from '../modes/claude/permissions.js';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  PermissionDecision,
} from '../core/contracts.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { UsageService } from '../core/usageService.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from './ports.js';

// Always-allow persistence (§7A): when a permission button resolves as "always",
// the wiring persists the tool into the GLOBAL autoAllowClaudeTools set via the
// ConfigStore, so a subsequent turn's canUseTool auto-allows it without prompting.

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
  readonly name = 'claude';
  readonly capabilities = CLAUDE_CAPS;
  async start(_ctx: ModeContext): Promise<ModeSession> {
    return { sessionId: 's', async send() {}, async stop() {} };
  }
  async resume(_ctx: ModeContext, id: string): Promise<ModeSession> {
    return { sessionId: id, async send() {}, async stop() {} };
  }
}

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

function makeConfig(): AppConfig {
  return {
    ...CONFIG_DEFAULTS,
    version: CONFIG_VERSION,
    discord: { token: 'fake-token', clientId: 'client-000' },
  } as AppConfig;
}

// A minimal ModeContext whose config.autoAllowClaudeTools comes from the persisted
// config — mirroring how the orchestrator threads the resolved allowlist onto ctx.
function ctxWithAllowlist(tools: string[]): ModeContext {
  return {
    guildId: 'g1',
    channelId: 'c1',
    cwd: '/tmp/ws',
    ownerId: 'owner',
    permMode: 'default',
    emit: () => {},
    requestPermission: async () => ({ behavior: 'deny' }) as PermissionDecision,
    config: { autoAllowClaudeTools: tools },
    logger,
    audit: () => {},
  };
}

describe('always-allow persistence', () => {
  let dir: string;
  let store: ConfigStore;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-allow-'));
    store = new ConfigStore(dir);
    store.save(makeConfig());
  });
  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  function makeWiring(channel: MessageChannel): SessionWiring {
    const modeRegistry = new ModeRegistry();
    modeRegistry.register(new StubMode());
    const channelRegistry = { get: () => ({ ownerId: 'owner' }) } as unknown as ChannelRegistry;
    const usageService = {
      isAvailable: () => false,
      getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }),
    } as unknown as UsageService;
    return new SessionWiring({
      eventBus: new EventBus(),
      modeRegistry,
      channelRegistry,
      usageService,
      logger,
      resolveChannel: async () => channel,
      permissionTimeoutSec: 60,
      onAlwaysAllow: (tool) => {
        store.addAutoAllowClaudeTool(tool);
      },
    });
  }

  it('persists the tool into the config auto-allow set on an Always button', async () => {
    const { channel, sent } = fakeChannel();
    const wiring = makeWiring(channel);
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(
      { guildId: 'g1', channelId: 'c1', ownerId: 'owner' },
      { toolName: 'Bash', input: { command: 'ls' } },
    );
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent)!;

    // Bash is NOT in the default auto-allow set yet.
    expect(store.load().autoAllowClaudeTools).not.toContain('Bash');

    await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:always`);
    const decision = await decisionP;
    expect(decision.behavior).toBe('allow');

    // The always-allow was persisted globally.
    expect(store.load().autoAllowClaudeTools).toContain('Bash');
  });

  it('a subsequent turn auto-allows the persisted tool without prompting', async () => {
    const { channel, sent } = fakeChannel();
    const wiring = makeWiring(channel);
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(
      { guildId: 'g1', channelId: 'c1', ownerId: 'owner' },
      { toolName: 'Bash', input: {} },
    );
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent)!;
    await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:always`);
    await decisionP;

    // Rebuild the resolved allowlist the way the orchestrator would on the NEXT turn
    // (PermissionResolver seeds allowedTools from config.autoAllowClaudeTools).
    const persisted = store.load().autoAllowClaudeTools;
    const canUse = makeCanUseTool(ctxWithAllowlist(persisted));
    let prompted = false;
    const ctxProbe = ctxWithAllowlist(persisted);
    ctxProbe.requestPermission = async () => {
      prompted = true;
      return { behavior: 'deny' };
    };
    const result = await makeCanUseTool(ctxProbe)('Bash', { command: 'ls' }, {
      signal: new AbortController().signal,
      toolUseID: 'tu-1',
      requestId: 'req-1',
    });
    expect(result?.behavior).toBe('allow');
    expect(prompted).toBe(false);
    // sanity: canUse built from the same allowlist also allows.
    const r2 = await canUse('Bash', {}, { signal: new AbortController().signal, toolUseID: 'tu-2', requestId: 'req-2' });
    expect(r2?.behavior).toBe('allow');
  });

  it('a plain Allow (not Always) does NOT persist the tool', async () => {
    const { channel, sent } = fakeChannel();
    const wiring = makeWiring(channel);
    await wiring.attach('g1', 'c1', 'claude');

    const decisionP = wiring.requestPermission(
      { guildId: 'g1', channelId: 'c1', ownerId: 'owner' },
      { toolName: 'Bash', input: {} },
    );
    await Promise.resolve();
    await Promise.resolve();
    const reqId = reqIdFromSent(sent)!;
    await wiring.resolvePermission('g1', 'c1', `perm:${reqId}:allow`);
    await decisionP;

    expect(store.load().autoAllowClaudeTools).not.toContain('Bash');
  });
});
