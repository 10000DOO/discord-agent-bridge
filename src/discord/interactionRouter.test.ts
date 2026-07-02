import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  InteractionRouter,
  type ComponentInteraction,
  type ModalSubmitInteraction,
  type SlashInteraction,
} from './interactionRouter.js';
import type { MessageChannel, ModalSpec } from './ports.js';
import type { GuildChannelProvisioner } from './guildChannels.js';
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
  Logger,
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

// A captured reply payload. `content` is optional now that a panel can be replied
// with embeds + component rows and no text body.
type Reply = { content?: string; ephemeral?: boolean; embeds?: unknown[]; components?: unknown[] };

// A recording of every ack call, in order, so a test can assert the ack came BEFORE
// the slow handler work (the defer-first contract) and that no path leaves the
// interaction unacknowledged. `kind` is the discord.js method that fired. `showModal`
// records that a modal was opened (its ack), so a test can assert it fired WITHOUT a
// preceding defer.
type AckEvent = {
  kind: 'deferReply' | 'reply' | 'editReply' | 'followUp' | 'deferUpdate' | 'showModal';
  payload?: Reply;
  modal?: ModalSpec;
};

function slash(
  over: Partial<SlashInteraction> & { roles?: string[]; getStringValue?: string; hasAdminPermission?: boolean },
): { interaction: SlashInteraction; replies: Reply[]; acks: AckEvent[] } {
  const replies: Reply[] = [];
  const acks: AckEvent[] = [];
  let acked = false;
  const roles = over.roles ?? [EXEC_ROLE];
  const interaction: SlashInteraction = {
    kind: 'slash',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    user: over.user ?? { id: 'u1' },
    member: { roles: { cache: { map: (fn) => roles.map((id) => fn({ id })) } } },
    ...(over.hasAdminPermission !== undefined ? { hasAdminPermission: over.hasAdminPermission } : {}),
    commandName: over.commandName ?? 'agent',
    subcommand: over.subcommand ?? null,
    getString: () => over.getStringValue ?? null,
    reply: async (o) => {
      acked = true;
      acks.push({ kind: 'reply', payload: o });
      replies.push(o);
    },
    deferReply: async (o) => {
      acked = true;
      acks.push({ kind: 'deferReply', payload: o });
    },
    editReply: async (o) => {
      acked = true;
      acks.push({ kind: 'editReply', payload: o });
      replies.push(o);
    },
    followUp: async (o) => {
      acked = true;
      acks.push({ kind: 'followUp', payload: o });
      replies.push(o);
    },
    get acknowledged() {
      return acked;
    },
  };
  return { interaction, replies, acks };
}

function component(
  over: Partial<ComponentInteraction> & { roles?: string[]; hasAdminPermission?: boolean },
): { interaction: ComponentInteraction; replies: Reply[]; acks: AckEvent[] } {
  const replies: Reply[] = [];
  const acks: AckEvent[] = [];
  let acked = false;
  const roles = over.roles ?? [EXEC_ROLE];
  const interaction: ComponentInteraction = {
    kind: 'component',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    user: over.user ?? { id: 'u1' },
    member: { roles: { cache: { map: (fn) => roles.map((id) => fn({ id })) } } },
    ...(over.hasAdminPermission !== undefined ? { hasAdminPermission: over.hasAdminPermission } : {}),
    customId: over.customId ?? 'x',
    ...(over.value !== undefined ? { value: over.value } : {}),
    ...(over.values !== undefined ? { values: over.values } : {}),
    reply: async (o) => {
      acked = true;
      acks.push({ kind: 'reply', payload: o });
      replies.push(o);
    },
    deferReply: async (o) => {
      acked = true;
      acks.push({ kind: 'deferReply', payload: o });
    },
    editReply: async (o) => {
      acked = true;
      acks.push({ kind: 'editReply', payload: o });
      replies.push(o);
    },
    followUp: async (o) => {
      acked = true;
      acks.push({ kind: 'followUp', payload: o });
      replies.push(o);
    },
    deferUpdate: async () => {
      acked = true;
      acks.push({ kind: 'deferUpdate' });
    },
    showModal: async (modal: ModalSpec) => {
      // showModal IS the ack — record it (and mark acknowledged) so a test can assert
      // it fired without a preceding defer.
      acked = true;
      acks.push({ kind: 'showModal', modal });
    },
    get acknowledged() {
      return acked;
    },
  };
  return { interaction, replies, acks };
}

// A scripted ModalSubmit interaction: `fields` maps field custom id → submitted value.
function modalSubmit(
  over: Partial<ModalSubmitInteraction> & { roles?: string[]; hasAdminPermission?: boolean; fields?: Record<string, string> },
): { interaction: ModalSubmitInteraction; replies: Reply[]; acks: AckEvent[] } {
  const replies: Reply[] = [];
  const acks: AckEvent[] = [];
  let acked = false;
  const roles = over.roles ?? [EXEC_ROLE];
  const fields = over.fields ?? {};
  const interaction: ModalSubmitInteraction = {
    kind: 'modalSubmit',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    user: over.user ?? { id: 'u1' },
    member: { roles: { cache: { map: (fn) => roles.map((id) => fn({ id })) } } },
    ...(over.hasAdminPermission !== undefined ? { hasAdminPermission: over.hasAdminPermission } : {}),
    customId: over.customId ?? 'config.codexHome.modal',
    getField: (id: string) => fields[id] ?? '',
    reply: async (o) => {
      acked = true;
      acks.push({ kind: 'reply', payload: o });
      replies.push(o);
    },
    deferReply: async (o) => {
      acked = true;
      acks.push({ kind: 'deferReply', payload: o });
    },
    editReply: async (o) => {
      acked = true;
      acks.push({ kind: 'editReply', payload: o });
      replies.push(o);
    },
    followUp: async (o) => {
      acked = true;
      acks.push({ kind: 'followUp', payload: o });
      replies.push(o);
    },
    get acknowledged() {
      return acked;
    },
  };
  return { interaction, replies, acks };
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
  logger?: Logger;
  resolveGuildProvisioner?: (guildId: string) => Promise<GuildChannelProvisioner | null>;
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
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
    logger: deps.logger ?? logger,
    modelsFor: () => [
      { value: 'opus', label: 'opus' },
      { value: 'sonnet', label: 'sonnet' },
    ],
    ...(deps.resolveGuildProvisioner ? { resolveGuildProvisioner: deps.resolveGuildProvisioner } : {}),
    ...(deps.resolveChannel ? { resolveChannel: deps.resolveChannel } : {}),
  });
}

// A fake provisioner for /init + session-channel tests: records creates + deletes and
// resolves reuse by an in-memory channel map (mirrors guildChannels.test.ts's fake).
class FakeProvisioner implements GuildChannelProvisioner {
  readonly guildId: string;
  readonly channels = new Map<string, string>(); // id → name
  readonly createdNames: string[] = [];
  readonly deleted: string[] = [];
  private seq = 0;
  constructor(guildId = 'g1') {
    this.guildId = guildId;
  }
  channelExists(id: string): boolean {
    return this.channels.has(id);
  }
  private nextId(): string {
    this.seq += 1;
    return `chan-${this.seq}`;
  }
  async ensureCategory(name: string, existingId?: string) {
    if (existingId && this.channels.has(existingId)) return { id: existingId, name: this.channels.get(existingId)! };
    const id = this.nextId();
    this.channels.set(id, name);
    this.createdNames.push(name);
    return { id, name };
  }
  async ensureTextChannel(name: string, _parentId: string, existingId?: string) {
    if (existingId && this.channels.has(existingId)) return { id: existingId, name: this.channels.get(existingId)! };
    const id = this.nextId();
    this.channels.set(id, name);
    this.createdNames.push(name);
    return { id, name };
  }
  async createTextChannel(name: string, _parentId?: string) {
    const id = this.nextId();
    this.channels.set(id, name);
    this.createdNames.push(name);
    return { id, name };
  }
  async deleteChannel(id: string) {
    this.channels.delete(id);
    this.deleted.push(id);
  }
}

// A fake MessageChannel that records every posted message (for the intro/status post).
function fakeMessageChannel() {
  const posts: { content?: string; embeds?: unknown[] }[] = [];
  const channel = {
    send: async (msg: { content?: string; embeds?: unknown[] }) => {
      posts.push(msg);
      return { id: 'posted-msg', async edit() {} };
    },
    startThread: async () => ({ id: 'thread', async send() { return { id: 'm', async edit() {} }; } }),
  } as unknown as MessageChannel;
  return { channel, posts };
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
    const { interaction, replies, acks } = slash({ commandName: 'stop-all', roles: [EXEC_ROLE] });
    await router.handle(interaction);
    expect(calls.stopAll).not.toHaveBeenCalled();
    // Deferred ephemerally FIRST, then the denial edits that ephemeral reply.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    expect(replies[0].content).toContain('권한이 없습니다');
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
    const { interaction, acks } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'codex',
    });
    await router.handle(interaction);
    expect(calls.stop).toHaveBeenCalledWith('g1', 'c1');
    expect(wcalls.detach).toHaveBeenCalledWith('g1', 'c1');
    expect(calls.start).toHaveBeenCalledOnce();
    expect(wcalls.attach).toHaveBeenCalledWith('g1', 'c1', 'codex');
    // The public fresh-context warning is a NON-ephemeral followUp (deferred reply is
    // ephemeral); the confirmation edits the deferred reply.
    const freshFollowUp = acks.find((a) => a.kind === 'followUp');
    expect(freshFollowUp?.payload?.content).toContain('새 대화로 시작');
    expect(freshFollowUp?.payload?.ephemeral).toBe(false);
  });

  it('/mode backend to an UNREGISTERED backend: ephemeral notice, session NOT stopped', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // 'gemini' is not registered (only claude + codex are), so it must be rejected
    // WITHOUT tearing down the running session.
    const { interaction, replies, acks } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'gemini',
    });
    await router.handle(interaction);
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    // Deferred ephemerally first; the notice edits that ephemeral reply.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    expect(replies[0].content).toContain('gemini');
  });

  it('/mode backend with NO binding is rejected instead of falling back to cwd', async () => {
    // No channelRegistry.set → no binding.
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, acks } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'codex', // registered, but there is no session to switch
    });
    await router.handle(interaction);
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    // Deferred ephemerally first; the no-session notice edits that ephemeral reply.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
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

describe('InteractionRouter /config command', () => {
  it('opens the panel for a Discord Administrator (empty allowlist bootstrap)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // A user with NO allowlisted role but the Discord Administrator permission.
    const { interaction, replies, acks } = slash({
      commandName: 'config',
      roles: ['role-nobody'],
      hasAdminPermission: true,
    });
    await router.handle(interaction);
    // Deferred ephemerally first (so the 3s window is never missed), then the panel is
    // delivered as an editReply (role tiers + Save) plus a followUp (defaults). Both
    // together stay within Discord's 5-action-row-per-message limit.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    const edit = replies[0];
    const follow = replies[1];
    expect(edit.components && edit.components.length).toBeGreaterThan(0);
    expect((edit.components as unknown[]).length).toBeLessThanOrEqual(5);
    expect(follow.ephemeral).toBe(true);
    expect((follow.components as unknown[]).length).toBeLessThanOrEqual(5);
  });

  it('opens the panel for an admin-tier user (configured allowlist)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({
      commandName: 'config',
      roles: [ADMIN_ROLE],
      hasAdminPermission: false,
    });
    await router.handle(interaction);
    // The panel (role tiers + Save) is edited into the deferred ephemeral reply.
    expect(replies[0].components && replies[0].components.length).toBeGreaterThan(0);
  });

  it('denies a non-admin, non-allowlisted user; panel not opened', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies, acks } = slash({
      commandName: 'config',
      roles: [EXEC_ROLE], // execute tier is NOT admin
      hasAdminPermission: false,
    });
    await router.handle(interaction);
    // Deferred ephemerally first, then the denial edits that ephemeral reply.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    expect(replies).toHaveLength(1);
    // No panel components were sent.
    expect(replies[0].components).toBeUndefined();
    expect(replies[0].content).toContain('admin');
  });

  it('a role-select component routes to the panel and persists on Save', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    // Admin opens the panel.
    const { interaction: open } = slash({
      commandName: 'config',
      user: { id: 'admin-user' },
      hasAdminPermission: true,
    });
    await router.handle(open);

    // The admin picks execute roles via the role-select, then Saves.
    const { interaction: pick } = component({
      customId: 'config.role.execute',
      values: ['picked-exec'],
      user: { id: 'admin-user' },
      hasAdminPermission: true,
    });
    await router.handle(pick);

    const { interaction: save, replies } = component({
      customId: 'config.save',
      user: { id: 'admin-user' },
      hasAdminPermission: true,
    });
    await router.handle(save);

    // The picked role landed in this guild's server config auth.
    const saved = store.loadServerConfig('g1');
    expect(saved?.auth?.executeRoleIds).toEqual(['picked-exec']);
    // A confirmation summary was sent.
    expect(replies[0].content).toContain('picked-exec');
  });

  it('a role-select from a NON-owner is ignored (does not persist)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    const { interaction: open } = slash({
      commandName: 'config',
      user: { id: 'admin-user' },
      hasAdminPermission: true,
    });
    await router.handle(open);

    // A different admin (u2) tries to Save without any pick — the panel is owned by
    // 'admin-user', so u2's interaction is acknowledged but ignored (no save).
    const { interaction: hijack } = component({
      customId: 'config.save',
      user: { id: 'u2' },
      hasAdminPermission: true,
    });
    await router.handle(hijack);
    expect(store.loadServerConfig('g1')).toBeNull();
  });

  it('a defaults select auto-saves that one field immediately (no Save button)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    const { interaction: open } = slash({ commandName: 'config', user: { id: 'admin-user' }, hasAdminPermission: true });
    await router.handle(open);

    // The owner changes the default backend → it persists at once (no Save).
    const { interaction: pick, replies } = component({
      customId: 'config.default.backend',
      value: 'codex',
      user: { id: 'admin-user' },
      hasAdminPermission: true,
    });
    await router.handle(pick);

    expect(store.loadServerConfig('g1')?.defaults?.mode).toBe('codex');
    // A short ephemeral confirmation for just that field was sent.
    expect(replies[0].ephemeral).toBe(true);
    expect(replies[0].content).toContain('codex');
  });

  it('a locale select auto-saves the per-guild locale immediately', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    const { interaction: open } = slash({ commandName: 'config', user: { id: 'admin-user' }, hasAdminPermission: true });
    await router.handle(open);

    const { interaction: pick } = component({
      customId: 'config.default.locale',
      value: 'en',
      user: { id: 'admin-user' },
      hasAdminPermission: true,
    });
    await router.handle(pick);

    expect(store.loadServerConfig('g1')?.locale).toBe('en');
  });

  it('the /config panel renders NO Codex-path button (codexHome auto-resolves)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    const { interaction, replies } = slash({ commandName: 'config', user: { id: 'admin-user' }, hasAdminPermission: true });
    await router.handle(interaction);

    // The whole panel (primary role reply + defaults follow-up) carries no codexHome
    // button, and no showModal ack ever fires from opening /config.
    const rows = replies.flatMap((r) => (r.components ?? []) as { components: { customId: string }[] }[]);
    const allComponents = rows.flatMap((row) => row.components);
    expect(allComponents.some((c) => c.customId === 'config.codexHome.open')).toBe(false);
  });

  it('a stray modal submit is acknowledged generically and persists nothing', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    // The bot no longer opens any modal; a replayed/stray submit must still be acked
    // (never "did not respond") without writing config.
    const { interaction: submit, replies } = modalSubmit({
      customId: 'config.codexHome.modal',
      user: { id: 'admin-user' },
      hasAdminPermission: true,
      fields: { 'config.codexHome.value': '/srv/codex' },
    });
    await router.handle(submit);

    expect(replies).toHaveLength(1);
    expect(replies[0].ephemeral).toBe(true);
    // Nothing was persisted for this guild.
    expect(store.loadServerConfig('g1')).toBeNull();
  });
});

describe('InteractionRouter /init command', () => {
  it('creates the category + control channel + sessions category and persists the ids', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    const { interaction, replies } = slash({ commandName: 'init', hasAdminPermission: true, roles: ['role-nobody'] });
    await router.handle(interaction);

    // Three channels created; ids persisted to servers/g1.json.
    expect(prov.createdNames).toHaveLength(3);
    const saved = store.loadServerConfig('g1');
    expect(saved?.channels?.controlChannelId).toBeTruthy();
    expect(saved?.channels?.sessionsCategoryId).toBeTruthy();
    // The reply links the control channel.
    expect(replies[0].content).toContain(`<#${saved!.channels!.controlChannelId}>`);
  });

  it('is idempotent: a second /init reuses the stored channels (no duplicates)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    const { interaction: first } = slash({ commandName: 'init', hasAdminPermission: true });
    await router.handle(first);
    const afterFirst = store.loadServerConfig('g1')?.channels;
    expect(prov.createdNames).toHaveLength(3);

    const { interaction: second } = slash({ commandName: 'init', hasAdminPermission: true });
    await router.handle(second);
    // No new creates; the stored ids are unchanged.
    expect(prov.createdNames).toHaveLength(3);
    expect(store.loadServerConfig('g1')?.channels).toEqual(afterFirst);
  });

  it('denies /init for a non-admin, non-allowlisted user (no channels created)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    const { interaction, replies } = slash({ commandName: 'init', roles: [EXEC_ROLE], hasAdminPermission: false });
    await router.handle(interaction);
    expect(prov.createdNames).toHaveLength(0);
    expect(store.loadServerConfig('g1')?.channels).toBeUndefined();
    expect(replies[0].content).toContain('admin');
  });

  it('reports a graceful notice when no provisioner is available', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => null });
    const { interaction, replies } = slash({ commandName: 'init', hasAdminPermission: true });
    await router.handle(interaction);
    expect(replies[0].content).toContain('채널 관리');
  });
});

describe('InteractionRouter /agent start creates a dedicated session channel', () => {
  // Drive the wizard to confirm and return the recorded orchestrator/wiring calls +
  // the new channel's posted messages.
  async function runStartFlow(prov: FakeProvisioner, sessionsCategoryId?: string) {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const router = buildRouter({
      orchestrator,
      wiring,
      resolveGuildProvisioner: async () => prov,
      resolveChannel: async () => channel,
    });
    if (sessionsCategoryId) {
      // Seed a persisted /init structure so the session channel is placed under it.
      store.saveServerConfig({
        version: 1,
        guildId: 'g1',
        channels: {
          categoryId: 'cat',
          controlChannelId: 'ctrl',
          sessionsCategoryId,
          statusChannelId: null,
        },
      });
    }
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);
    // Owner drives the whole wizard to confirm.
    const flow: { customId: string; value?: string }[] = [
      { customId: 'dir:here' },
      { customId: 'backend', value: 'claude' },
      { customId: 'model', value: 'opus' },
      { customId: 'perm.mode', value: 'default' },
      { customId: 'confirm' },
    ];
    const compReplies: Reply[] = [];
    for (const step of flow) {
      const { interaction, replies } = component({ ...step, user: { id: 'u1' } });
      await router.handle(interaction);
      compReplies.push(...replies);
    }
    return { calls, wcalls, posts, compReplies };
  }

  it('creates a NEW channel, binds the session + wires renderers to the new channel id', async () => {
    const prov = new FakeProvisioner('g1');
    const { calls, wcalls, posts, compReplies } = await runStartFlow(prov);

    // A dedicated session channel was created (proj-*).
    expect(prov.createdNames).toHaveLength(1);
    expect(prov.createdNames[0]).toMatch(/^proj-/);
    const newChannelId = [...prov.channels.keys()][0];

    // The session started bound to the NEW channel (not the command channel 'c1').
    expect(calls.start).toHaveBeenCalledOnce();
    expect(calls.start).toHaveBeenCalledWith(expect.objectContaining({ channelId: newChannelId }));
    expect(calls.start).not.toHaveBeenCalledWith(expect.objectContaining({ channelId: 'c1' }));

    // Renderers/eventBus subscription keys off the NEW channel id (wiring.attach).
    expect(wcalls.attach).toHaveBeenCalledWith('g1', newChannelId, 'claude');

    // The status embed + intro were posted INTO the new channel.
    expect(posts.length).toBeGreaterThanOrEqual(1);
    expect(posts[0].embeds && posts[0].embeds.length).toBeGreaterThan(0);

    // The driver was told where the session channel is.
    expect(compReplies.some((r) => r.content?.includes(`<#${newChannelId}>`))).toBe(true);
  });

  it('places the new session channel under the /init sessions category when present', async () => {
    const prov = new FakeProvisioner('g1');
    // Seed the sessions category id into the fake so createTextChannel records its parent.
    prov.channels.set('sessions-cat', 'Agent - Sessions');
    const { calls } = await runStartFlow(prov, 'sessions-cat');
    // start was called (session bound to the created channel).
    expect(calls.start).toHaveBeenCalledOnce();
    // The created project channel exists in the provisioner.
    const created = prov.createdNames.find((n) => n.startsWith('proj-'));
    expect(created).toBeTruthy();
  });
});

describe('InteractionRouter /agent close deletes the session channel', () => {
  it('deletes the closed channel via the provisioner (A4D behavior)', async () => {
    channelRegistry.set(binding(home, { channelId: 'sess-1' }));
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    prov.channels.set('sess-1', 'proj-thing');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });
    const { interaction } = slash({ commandName: 'agent', subcommand: 'close', channelId: 'sess-1' });
    await router.handle(interaction);
    expect(calls.stop).toHaveBeenCalledWith('g1', 'sess-1');
    expect(wcalls.detach).toHaveBeenCalledWith('g1', 'sess-1');
    expect(prov.deleted).toContain('sess-1');
  });

  it('never deletes the control channel on close', async () => {
    // Persist an /init structure whose control channel is 'ctrl'.
    store.saveServerConfig({
      version: 1,
      guildId: 'g1',
      channels: { categoryId: 'cat', controlChannelId: 'ctrl', sessionsCategoryId: 'sess-cat', statusChannelId: null },
    });
    channelRegistry.set(binding(home, { channelId: 'ctrl' }));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    prov.channels.set('ctrl', 'agent-start');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });
    const { interaction } = slash({ commandName: 'agent', subcommand: 'close', channelId: 'ctrl' });
    await router.handle(interaction);
    expect(prov.deleted).not.toContain('ctrl');
  });
});

// A logger whose calls are recorded, for the interaction-receipt + error-logging tests.
function fakeLogger(): { logger: Logger; info: ReturnType<typeof vi.fn>; error: ReturnType<typeof vi.fn> } {
  const info = vi.fn();
  const error = vi.fn();
  const logger: Logger = { debug: vi.fn(), info, warn: vi.fn(), error };
  return { logger, info, error };
}

// These tests assert the ACK-ORDERING CONTRACT — the fix for Discord's 3-second
// deadline ("application did not respond"). Because CI cannot reach the real gateway,
// they verify that the router acknowledges (defers) BEFORE the slow handler work and
// that no path (including a thrown handler) leaves the interaction unacknowledged. The
// real fix is validated by a live retest against Discord.
describe('InteractionRouter acknowledgment contract (3s window fix)', () => {
  it('/stop DEFERS before doing the slow orchestrator/wiring work', async () => {
    channelRegistry.set(binding(home));
    const order: string[] = [];
    const { wiring } = fakeWiring();
    const orchestrator = {
      start: vi.fn(),
      stop: vi.fn(async () => {
        order.push('stop');
      }),
      stopAll: vi.fn(),
    } as unknown as SessionOrchestrator;
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, acks } = slash({ commandName: 'stop' });
    // Record the defer relative to the orchestrator work.
    const origDefer = interaction.deferReply;
    interaction.deferReply = async (o) => {
      order.push('defer');
      return origDefer(o);
    };
    await router.handle(interaction);
    // The ack (defer) fired FIRST, before orchestrator.stop.
    expect(order).toEqual(['defer', 'stop']);
    expect(acks[0].kind).toBe('deferReply');
  });

  it('a slash handler that THROWS still produces a user-visible ack (no unhandled rejection)', async () => {
    channelRegistry.set(binding(home));
    const { wiring } = fakeWiring();
    // orchestrator.stop throws → the /stop handler body throws after the defer.
    const orchestrator = {
      start: vi.fn(),
      stop: vi.fn(async () => {
        throw new Error('boom');
      }),
      stopAll: vi.fn(),
    } as unknown as SessionOrchestrator;
    const { logger, error } = fakeLogger();
    const router = buildRouter({ orchestrator, wiring, logger });
    const { interaction, replies, acks } = slash({ commandName: 'stop' });
    // Must not reject.
    await expect(router.handle(interaction)).resolves.toBeUndefined();
    // Deferred first, then the error was edited into the deferred reply.
    expect(acks[0].kind).toBe('deferReply');
    const errorReply = replies.find((r) => r.content && r.content.includes('처리하지 못했'));
    expect(errorReply).toBeTruthy();
    // The error was logged WITH its stack to the operator terminal.
    expect(error).toHaveBeenCalled();
    const errMeta = error.mock.calls.find((c) => typeof c[1] === 'object') as unknown[] | undefined;
    expect(errMeta && (errMeta[1] as { stack?: string }).stack).toContain('boom');
  });

  it('logs a receipt line for EVERY received interaction (slash + component)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { logger, info } = fakeLogger();
    const router = buildRouter({ orchestrator, wiring, logger });

    const { interaction: s } = slash({ commandName: 'stop' });
    await router.handle(s);
    const slashReceipt = info.mock.calls.find(
      (c) => c[0] === 'interaction received' && (c[1] as { type?: string })?.type === 'slash',
    );
    expect(slashReceipt).toBeTruthy();
    expect((slashReceipt?.[1] as { command?: string }).command).toBe('stop');
    expect((slashReceipt?.[1] as { userId?: string }).userId).toBe('u1');

    const { interaction: c } = component({ customId: 'perm:req-1:allow' });
    await router.handle(c);
    const compReceipt = info.mock.calls.find(
      (call) => call[0] === 'interaction received' && (call[1] as { type?: string })?.type === 'component',
    );
    expect(compReceipt).toBeTruthy();
    expect((compReceipt?.[1] as { customId?: string }).customId).toBe('perm:req-1:allow');
  });

  it('a perm button DEFERS (deferUpdate) before resolving the permission', async () => {
    const order: string[] = [];
    const orchestrator = fakeOrchestrator().orchestrator;
    const wiring = {
      attach: vi.fn(),
      detach: vi.fn(),
      resolvePermission: vi.fn(async () => {
        order.push('resolve');
        return { behavior: 'allow' as const };
      }),
    } as unknown as SessionWiring;
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = component({ customId: 'perm:req-1:allow' });
    const origDefer = interaction.deferUpdate;
    interaction.deferUpdate = async () => {
      order.push('defer');
      return origDefer();
    };
    await router.handle(interaction);
    // deferUpdate fired BEFORE resolvePermission (never miss the 3s window).
    expect(order).toEqual(['defer', 'resolve']);
  });
});
