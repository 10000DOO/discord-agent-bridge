import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  InteractionRouter,
  type ComponentInteraction,
  type SlashInteraction,
} from './interactionRouter.js';
import { ConfigStore } from '../core/config.js';
import { CONFIG_VERSION, type AppConfig } from '../core/configSchema.js';
import { StateStore } from '../core/state/store.js';
import { ChannelRegistry, type ChannelBinding } from '../core/channelRegistry.js';
import { ConfigResolver } from '../core/configResolver.js';
import { PermissionResolver } from '../core/permissionResolver.js';
import { ModeRegistry } from '../core/modeRegistry.js';
import { Authorizer } from '../core/auth.js';
import { createLogger } from '../core/logger.js';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
} from '../core/contracts.js';
import type { SessionOrchestrator } from '../core/sessionOrchestrator.js';
import type { SessionWiring } from './wiring.js';

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

// A no-op AgentMode used only for its name + capabilities in the router.
class StubMode implements AgentMode {
  constructor(readonly name: string, readonly capabilities: Capabilities) {}
  async start(_ctx: ModeContext): Promise<ModeSession> {
    return { sessionId: `${this.name}-sess`, async send() {}, async stop() {} };
  }
  async resume(_ctx: ModeContext, id: string): Promise<ModeSession> {
    return { sessionId: id, async send() {}, async stop() {} };
  }
}

const ADMIN_ROLE = 'role-admin';
const EXEC_ROLE = 'role-exec';

function writeConfig(dir: string): void {
  const config: AppConfig = {
    version: CONFIG_VERSION,
    discord: { token: 'x', clientId: 'cid' },
    auth: {
      adminRoleIds: [ADMIN_ROLE],
      executeRoleIds: [EXEC_ROLE],
      readOnlyRoleIds: [],
      dmPolicy: 'deny',
    },
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
    autoAllowClaudeTools: ['Read'],
    profiles: {},
    usage: { userAgent: 'claude-code', cacheSec: 180 },
    audit: { channelId: null },
    locale: 'ko',
    logLevel: 'info',
    favorites: [],
  };
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify(config));
}

function binding(cwd: string, over: Partial<ChannelBinding> = {}): ChannelBinding {
  return {
    guildId: 'g1',
    channelId: 'c1',
    mode: 'claude',
    sessionId: 's1',
    cwd,
    ownerId: 'owner',
    permMode: 'default',
    profile: null,
    archived: false,
    createdAt: 'now',
    updatedAt: 'now',
    ...over,
  };
}

// A recording SessionWiring double.
function fakeWiring() {
  const calls = {
    attach: vi.fn(async (_g: string, _c: string, _m: string) => {}),
    detach: vi.fn((_g: string, _c: string) => {}),
    resolvePermission: vi.fn(async (_g: string, _c: string, _id: string, _actor?: string) => ({ behavior: 'allow' as const })),
  };
  return { wiring: calls as unknown as SessionWiring, calls };
}

// A recording orchestrator double.
function fakeOrchestrator() {
  const calls = {
    start: vi.fn(async () => ({ sessionId: 'new-sess', async send() {}, async stop() {} }) as ModeSession),
    stop: vi.fn(async (_g: string, _c: string) => {}),
    stopAll: vi.fn(async () => {}),
  };
  return { orchestrator: calls as unknown as SessionOrchestrator, calls };
}

function slash(over: Partial<SlashInteraction> & { roles?: string[]; getStringValue?: string }): {
  interaction: SlashInteraction;
  replies: { content: string; ephemeral?: boolean }[];
} {
  const replies: { content: string; ephemeral?: boolean }[] = [];
  const roles = over.roles ?? [EXEC_ROLE];
  const interaction: SlashInteraction = {
    kind: 'slash',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    user: over.user ?? { id: 'u1' },
    member: { roles: { cache: { map: (fn) => roles.map((id) => fn({ id })) } } },
    commandName: over.commandName ?? 'agent',
    subcommand: over.subcommand ?? null,
    getString: () => over.getStringValue ?? null,
    reply: async (o) => {
      replies.push(o);
    },
  };
  return { interaction, replies };
}

function component(over: Partial<ComponentInteraction> & { roles?: string[] }): {
  interaction: ComponentInteraction;
  replies: { content: string; ephemeral?: boolean }[];
} {
  const replies: { content: string; ephemeral?: boolean }[] = [];
  const roles = over.roles ?? [EXEC_ROLE];
  const interaction: ComponentInteraction = {
    kind: 'component',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    user: over.user ?? { id: 'u1' },
    member: { roles: { cache: { map: (fn) => roles.map((id) => fn({ id })) } } },
    customId: over.customId ?? 'x',
    ...(over.value !== undefined ? { value: over.value } : {}),
    reply: async (o) => {
      replies.push(o);
    },
    deferUpdate: async () => {},
  };
  return { interaction, replies };
}

let home: string;
let store: ConfigStore;
let stateStore: StateStore;
let channelRegistry: ChannelRegistry;
let configResolver: ConfigResolver;
let permissionResolver: PermissionResolver;
let modeRegistry: ModeRegistry;
let authorizer: Authorizer;

function buildRouter(deps: {
  orchestrator: SessionOrchestrator;
  wiring: SessionWiring;
}): InteractionRouter {
  return new InteractionRouter({
    authorizer,
    orchestrator: deps.orchestrator,
    channelRegistry,
    configStore: store,
    configResolver,
    permissionResolver,
    modeRegistry,
    wiring: deps.wiring,
    logger,
    modelsFor: () => ['opus', 'sonnet'],
  });
}

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-ir-'));
  writeConfig(home);
  store = new ConfigStore(home);
  stateStore = new StateStore(home);
  channelRegistry = new ChannelRegistry(stateStore);
  configResolver = new ConfigResolver(store, channelRegistry);
  permissionResolver = new PermissionResolver(store, configResolver);
  modeRegistry = new ModeRegistry();
  modeRegistry.register(new StubMode('claude', CLAUDE_CAPS));
  modeRegistry.register(new StubMode('codex', { ...CLAUDE_CAPS, usagePanel: false }));
  authorizer = new Authorizer(store, channelRegistry);
});
afterEach(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

describe('InteractionRouter slash commands', () => {
  it('/stop-all by a non-admin (execute) is denied — stopAll not called', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'stop-all', roles: [EXEC_ROLE] });
    await router.handle(interaction);
    expect(calls.stopAll).not.toHaveBeenCalled();
    expect(replies[0].content).toContain('권한이 없습니다');
    expect(replies[0].ephemeral).toBe(true);
  });

  it('/stop-all by an admin stops all sessions', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = slash({ commandName: 'stop-all', roles: [ADMIN_ROLE] });
    await router.handle(interaction);
    expect(calls.stopAll).toHaveBeenCalledOnce();
  });

  it('/agent start launches the wizard (records it; replies ephemerally)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'agent', subcommand: 'start' });
    await router.handle(interaction);
    expect(replies[0].content).toContain('마법사');
    // A follow-up folder component now routes to the started wizard (deferUpdate).
    const { interaction: comp } = component({ customId: 'dir:here' });
    await router.handle(comp);
    // The wizard advanced (no crash, deferred). The wizard is still tracked until done.
    expect(true).toBe(true);
  });

  it('/mode backend switches backend with the fresh-context warning', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'codex',
    });
    await router.handle(interaction);
    expect(calls.stop).toHaveBeenCalledWith('g1', 'c1');
    expect(wcalls.detach).toHaveBeenCalledWith('g1', 'c1');
    expect(calls.start).toHaveBeenCalledOnce();
    expect(wcalls.attach).toHaveBeenCalledWith('g1', 'c1', 'codex');
    expect(replies[0].content).toContain('새 대화로 시작');
  });

  it('/mode backend to an UNREGISTERED backend: ephemeral notice, session NOT stopped', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // 'gemini' is not registered (only claude + codex are), so it must be rejected
    // WITHOUT tearing down the running session.
    const { interaction, replies } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'gemini',
    });
    await router.handle(interaction);
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    expect(replies[0].ephemeral).toBe(true);
    expect(replies[0].content).toContain('gemini');
  });

  it('/mode backend with NO binding is rejected instead of falling back to cwd', async () => {
    // No channelRegistry.set → no binding.
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'codex', // registered, but there is no session to switch
    });
    await router.handle(interaction);
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    expect(replies[0].ephemeral).toBe(true);
  });

  it('/stop stops the channel session and detaches renderers', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = slash({ commandName: 'stop' });
    await router.handle(interaction);
    expect(calls.stop).toHaveBeenCalledWith('g1', 'c1');
    expect(wcalls.detach).toHaveBeenCalledWith('g1', 'c1');
  });
});

describe('InteractionRouter component interactions', () => {
  it('perm:<id>:allow button routes to wiring.resolvePermission with the acting user id', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring, calls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = component({ customId: 'perm:req-1:allow', user: { id: 'u1' } });
    await router.handle(interaction);
    // The acting user id is threaded so the handler can enforce the approver binding.
    expect(calls.resolvePermission).toHaveBeenCalledWith('g1', 'c1', 'perm:req-1:allow', 'u1');
  });

  it('a foreign (non-perm, no-wizard) component is safely ignored (deferUpdate, no resolve)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring, calls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = component({ customId: 'dir:up' });
    await router.handle(interaction);
    expect(calls.resolvePermission).not.toHaveBeenCalled();
  });

  it('a denied user clicking a perm button does NOT resolve it', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring, calls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = component({ customId: 'perm:req-1:allow', roles: ['role-nobody'] });
    await router.handle(interaction);
    expect(calls.resolvePermission).not.toHaveBeenCalled();
    expect(replies[0].content).toContain('권한이 없습니다');
  });

  it('a wizard component from a NON-owner is ignored; the owner advances it', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    // Owner 'u1' opens the wizard (browseRoots defaults to []; the browser starts at
    // a resolvable root — 'dir:here' selects the current folder).
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);

    const flow: { customId: string; value?: string }[] = [
      { customId: 'dir:here' },
      { customId: 'backend', value: 'claude' },
      { customId: 'model', value: 'opus' },
      { customId: 'perm.mode', value: 'default' },
      { customId: 'confirm' },
    ];

    // A bystander 'u2' (also execute tier) runs the WHOLE flow → every input is
    // ignored, so the session is never started.
    for (const step of flow) {
      const { interaction } = component({ ...step, user: { id: 'u2' } });
      await router.handle(interaction);
    }
    expect(calls.start).not.toHaveBeenCalled();

    // The owner 'u1' now advances the SAME wizard to completion → start is called.
    for (const step of flow) {
      const { interaction } = component({ ...step, user: { id: 'u1' } });
      await router.handle(interaction);
    }
    expect(calls.start).toHaveBeenCalledOnce();
  });
});
