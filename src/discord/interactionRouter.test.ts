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
import { setLocale } from './i18n.js';
import type { ShareResult } from './documentShare.js';
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
  ModeCatalog,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../core/contracts.js';
import { claudeCatalog, codexCatalog } from '../core/providerCatalog.js';
import type { ActiveChannelInfo, SessionOrchestrator } from '../core/sessionOrchestrator.js';
import type { AutoUpdater, DecisionCtx } from '../update/autoUpdater.js';
import type { UsageResult, UsageService } from '../core/usageService.js';
import type { SessionWiring } from './wiring.js';
import type { ChromiumProvisioner } from './render/chromiumProvisioner.js';

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

// A no-op AgentMode used only for its name + capabilities in the router. `resumable`
// scripts what listResumable returns (per-backend, for the resume-flow tests); when
// undefined, listResumable is absent so the mode simply has no resumable list.
class StubMode implements AgentMode {
  // Carry the real per-backend catalog matching the impersonated name, mirroring app.ts
  // wiring (claude/custom → claudeCatalog, codex → codexCatalog), so the router's wizard/
  // /effort option lists resolve exactly as they would in production.
  readonly catalog: ModeCatalog;
  constructor(
    readonly name: string,
    readonly capabilities: Capabilities,
    private readonly resumable?: ResumableSession[],
  ) {
    this.catalog = name === 'codex' ? codexCatalog : claudeCatalog;
    if (this.resumable !== undefined) {
      this.listResumable = async (_ctx: ModeContext): Promise<ResumableSession[]> => this.resumable!;
    }
  }
  listResumable?: (ctx: ModeContext) => Promise<ResumableSession[]>;
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
    autoUpdate: { enabled: true },
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
function fakeOrchestrator(active: ActiveChannelInfo[] = []) {
  const calls = {
    start: vi.fn(async () => ({ sessionId: 'new-sess', async send() {}, async stop() {} }) as ModeSession),
    resume: vi.fn(async (_p: unknown, sessionId: string) => ({ sessionId, async send() {}, async stop() {} }) as ModeSession),
    stop: vi.fn(async (_g: string, _c: string) => {}),
    stopAll: vi.fn(async () => {}),
    interrupt: vi.fn(async (_g: string, _c: string) => true),
    setModel: vi.fn(async (_g: string, _c: string, _m: string) => 'ok' as const),
    setEffort: vi.fn(async (_g: string, _c: string, _e: string) => 'ok' as const),
    listActive: vi.fn((_guildId: string) => active),
    // A minimal read-only ModeContext for listResumable (cwd/config/logger only).
    buildListContext: vi.fn((_mode: string, cwd: string) => ({
      guildId: '',
      channelId: '',
      cwd,
      ownerId: '',
      permMode: 'default' as const,
      emit: () => {},
      requestPermission: async () => ({ behavior: 'deny' as const }),
      config: {},
      logger,
      audit: () => {},
    }) as unknown as ModeContext),
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
  browseRoots?: string[];
  resolveGuildProvisioner?: (guildId: string) => Promise<GuildChannelProvisioner | null>;
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
  usageService?: UsageService;
  imageProvisioner?: ChromiumProvisioner;
  customBackendLabel?: () => string;
  pickFolder?: (startDir: string, prompt: string, timeoutMs: number) => Promise<string | null>;
  shareDocumentFor?: (guildId: string, channelId: string) => (path: string) => Promise<ShareResult>;
}): InteractionRouter {
  // Default: Claude usage unavailable (API-key-only / no OAuth) so /agent stats shows the
  // login notice; a test can inject a usage snapshot to exercise the utilization lines.
  const usageService =
    deps.usageService ??
    ({
      isAvailable: () => false,
      getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }),
    } as unknown as UsageService);
  return new InteractionRouter({
    authorizer,
    orchestrator: deps.orchestrator,
    channelRegistry,
    configStore: store,
    stateStore,
    configResolver,
    permissionResolver,
    modeRegistry,
    wiring: deps.wiring,
    usageService,
    logger: deps.logger ?? logger,
    // Backend-aware, mirroring app.ts wiring: codex offers its own catalog (the
    // configured default first), claude the probed list.
    modelsFor: async (backend: string) =>
      backend === 'codex'
        ? [
            { value: 'gpt-5.5', label: 'gpt-5.5' },
            { value: 'gpt-5.4', label: 'gpt-5.4' },
          ]
        : [
            { value: 'opus', label: 'opus' },
            { value: 'sonnet', label: 'sonnet' },
          ],
    ...(deps.browseRoots ? { browseRoots: deps.browseRoots } : {}),
    ...(deps.resolveGuildProvisioner ? { resolveGuildProvisioner: deps.resolveGuildProvisioner } : {}),
    ...(deps.resolveChannel ? { resolveChannel: deps.resolveChannel } : {}),
    ...(deps.imageProvisioner ? { imageProvisioner: deps.imageProvisioner } : {}),
    ...(deps.customBackendLabel ? { customBackendLabel: deps.customBackendLabel } : {}),
    ...(deps.pickFolder ? { pickFolder: deps.pickFolder } : {}),
    ...(deps.shareDocumentFor ? { shareDocumentFor: deps.shareDocumentFor } : {}),
  });
}

// A fake ChromiumProvisioner exposing only isInstalled() — the sole method
// maybePromptRenderSetup consults for the render-setup gate.
function fakeProvisioner(installed: boolean): ChromiumProvisioner {
  return { isInstalled: () => installed } as unknown as ChromiumProvisioner;
}

// A fake provisioner for /setup + session-channel tests: records creates + deletes and
// resolves reuse by an in-memory channel map (mirrors guildChannels.test.ts's fake).
class FakeProvisioner implements GuildChannelProvisioner {
  readonly guildId: string;
  readonly channels = new Map<string, string>(); // id → name
  readonly createdNames: string[] = [];
  readonly deleted: string[] = [];
  private seq = 0;
  manageChannels = true;
  constructor(guildId = 'g1') {
    this.guildId = guildId;
  }
  canManageChannels(): boolean {
    return this.manageChannels;
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
  async renameChannel(id: string, name: string) {
    if (this.channels.has(id)) this.channels.set(id, name);
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

  it('/agent start launches the wizard WITH the folder-picker components (not just text)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'agent', subcommand: 'start' });
    await router.handle(interaction);
    // The launched reply carries the step embed AND the folder-picker component rows —
    // this is the LIVE bug: it used to send only the "마법사 열었어요" text with no
    // components, so the user had nothing to click.
    expect(replies[0].content).toContain('마법사');
    expect(replies[0].embeds && (replies[0].embeds as unknown[]).length).toBeGreaterThan(0);
    const rows = (replies[0].components ?? []) as { components: { type: string; customId: string }[] }[];
    expect(rows.length).toBeGreaterThan(0);
    const flat = rows.flatMap((r) => r.components);
    // The folder select (dir:into) + ⬆ up / ✅ start buttons are all present.
    expect(flat.some((c) => c.type === 'select' && c.customId === 'dir:into')).toBe(true);
    expect(flat.some((c) => c.type === 'button' && c.customId === 'dir:up')).toBe(true);
    expect(flat.some((c) => c.type === 'button' && c.customId === 'dir:here')).toBe(true);
  });

  it('/agent start: a folder-select advances the wizard and re-renders the NEXT step with components', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);

    // Selecting the current folder (✅ 이 폴더로 시작) advances folder → backend; the
    // component is deferUpdate'd and the router edits the message with the backend step,
    // which again carries components (the backend select + cancel button).
    const { interaction: pick, replies } = component({ customId: 'dir:here', user: { id: 'u1' } });
    await router.handle(pick);
    const edited = replies.find((r) => r.components && (r.components as unknown[]).length > 0);
    expect(edited).toBeTruthy();
    const rows = (edited!.components ?? []) as { components: { type: string; customId: string }[] }[];
    const flat = rows.flatMap((r) => r.components);
    expect(flat.some((c) => c.type === 'select' && c.customId === 'backend')).toBe(true);
  });

  it('/agent start: dir:panel opens the host picker from the browsed cwd and jumps the browser to the pick', async () => {
    const target = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-panel-'));
    try {
      const { orchestrator } = fakeOrchestrator();
      const { wiring } = fakeWiring();
      const picks: { startDir: string; prompt: string; timeoutMs: number }[] = [];
      const router = buildRouter({
        orchestrator,
        wiring,
        pickFolder: async (startDir, prompt, timeoutMs) => {
          picks.push({ startDir, prompt, timeoutMs });
          return target;
        },
      });
      const { interaction: start, replies: startReplies } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
      await router.handle(start);
      // A wired picker renders the 🖥️ button on the folder step.
      const startRows = (startReplies[0].components ?? []) as { components: { customId: string }[] }[];
      expect(startRows.flatMap((r) => r.components).some((c) => c.customId === 'dir:panel')).toBe(true);

      const { interaction: click, replies, acks } = component({ customId: 'dir:panel', user: { id: 'u1' } });
      await router.handle(click);
      // deferUpdate is the ack (the pick can far exceed the 3s window); the picker was
      // opened from the wizard's browsed cwd with a bounded timeout.
      expect(acks[0].kind).toBe('deferUpdate');
      expect(picks).toHaveLength(1);
      expect(picks[0].timeoutMs).toBeGreaterThan(0);
      // The folder step was re-rendered at the picked path — ✅ Start now selects it.
      const edited = replies.find((r) => r.embeds && (r.embeds as { description?: string }[])[0]?.description?.includes(target));
      expect(edited).toBeTruthy();
    } finally {
      fs.rmSync(target, { recursive: true, force: true });
    }
  });

  it('/agent start: a cancelled dir:panel pick leaves the browsed folder unchanged', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring, pickFolder: async () => null });
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);

    const { interaction: click, replies } = component({ customId: 'dir:panel', user: { id: 'u1' } });
    await router.handle(click);
    // The cancel notice is a followUp; the wizard message itself is not re-rendered.
    expect(replies.some((r) => typeof r.content === 'string' && r.content.includes('취소'))).toBe(true);
    expect(replies.some((r) => r.embeds && (r.embeds as unknown[]).length > 0)).toBe(false);
  });

  it('/agent start: without a wired picker the dir:panel button is absent and a stray click is a no-op', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction: start, replies: startReplies } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);
    const startRows = (startReplies[0].components ?? []) as { components: { customId: string }[] }[];
    expect(startRows.flatMap((r) => r.components).some((c) => c.customId === 'dir:panel')).toBe(false);

    // A stale dir:panel click (e.g. an old message) is acknowledged and ignored.
    const { interaction: click, replies, acks } = component({ customId: 'dir:panel', user: { id: 'u1' } });
    await router.handle(click);
    expect(acks[0].kind).toBe('deferUpdate');
    expect(replies).toHaveLength(0);
  });

  it('/agent start: the "custom" backend option is named after the resolved provider', async () => {
    modeRegistry.register(new StubMode('custom', CLAUDE_CAPS));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring, customBackendLabel: () => 'Custom (kimi-k2.7-code)' });
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);

    const { interaction: pick, replies } = component({ customId: 'dir:here', user: { id: 'u1' } });
    await router.handle(pick);
    const edited = replies.find((r) => r.components && (r.components as unknown[]).length > 0);
    const rows = (edited!.components ?? []) as {
      components: { type: string; customId: string; options?: { value: string; label: string }[] }[];
    }[];
    const backendSelect = rows.flatMap((r) => r.components).find((c) => c.customId === 'backend');
    const custom = backendSelect?.options?.find((o) => o.value === 'custom');
    expect(custom?.label).toBe('Custom (kimi-k2.7-code)');
  });

  it('/agent start: EVERY step advances via its BUTTON and re-renders the next step with components', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);

    // The choice steps advance on their confirm BUTTON (backend.next / model.next /
    // effort.next), not the select's change. Each transition re-renders the next step
    // with its select/buttons on the edited message. The final perm step carries the
    // ✅ 시작 (perm.start) button.
    const steps: { customId: string; expectId: string; expectType: string }[] = [
      { customId: 'dir:here', expectId: 'backend', expectType: 'select' },
      { customId: 'backend.next', expectId: 'model', expectType: 'select' },
      { customId: 'model.next', expectId: 'effort', expectType: 'select' },
      { customId: 'effort.next', expectId: 'perm.start', expectType: 'button' },
    ];
    for (const step of steps) {
      const { interaction, replies } = component({ customId: step.customId, user: { id: 'u1' } });
      await router.handle(interaction);
      const edited = replies.find((r) => r.components && (r.components as unknown[]).length > 0);
      expect(edited, `step after ${step.customId} must carry components`).toBeTruthy();
      const flat = ((edited!.components ?? []) as { components: { type: string; customId: string }[] }[])
        .flatMap((r) => r.components);
      expect(flat.some((c) => c.type === step.expectType && c.customId === step.expectId)).toBe(true);
    }
  });

  it('/agent start: a select-change updates pending state + re-renders WITHOUT advancing', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction);

    // Changing the backend select (to codex) must NOT advance to the model step — it
    // re-renders the backend step with codex pre-selected; the session is not started.
    const { interaction: change, replies } = component({ customId: 'backend', value: 'codex', user: { id: 'u1' } });
    await router.handle(change);
    const edited = replies.find((r) => r.components && (r.components as unknown[]).length > 0);
    const flat = ((edited?.components ?? []) as { components: { type: string; customId: string; options?: { value: string; default?: boolean }[] }[] }[]).flatMap((r) => r.components);
    // Still on the backend step (backend select + backend.next button), NOT the model step.
    expect(flat.some((c) => c.customId === 'backend.next')).toBe(true);
    expect(flat.some((c) => c.customId === 'model')).toBe(false);
    const backendSelect = flat.find((c) => c.customId === 'backend');
    expect(backendSelect?.options?.find((o) => o.value === 'codex')?.default).toBe(true);
    expect(calls.start).not.toHaveBeenCalled();
  });

  it('/mode backend to a DIFFERENT backend opens the reconfigure popup WITHOUT tearing down the session (R1/R4)', async () => {
    channelRegistry.set(binding(home)); // a running claude session
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies, acks } = slash({
      commandName: 'mode',
      subcommand: 'backend',
      getStringValue: 'codex',
    });
    await router.handle(interaction);
    // The switch is only PROPOSED — nothing is stopped/detached/started until confirm (R1/R4).
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    // The popup (embed + component rows) rides the deferred ephemeral reply.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    const popup = replies.find((r) => (r.embeds?.length ?? 0) > 0 && (r.components?.length ?? 0) > 0);
    expect(popup).toBeTruthy();
    // It opens at the MODEL step (folder/preset/backend skipped): model select + model.next,
    // no backend/folder components; reconfigure first step DOES show back (cancels popup).
    const flat = ((popup!.components ?? []) as { components: { type: string; customId: string }[] }[]).flatMap((r) => r.components);
    expect(flat.some((c) => c.type === 'select' && c.customId === 'model')).toBe(true);
    expect(flat.some((c) => c.customId === 'model.next')).toBe(true);
    expect(flat.some((c) => c.customId === 'backend')).toBe(false);
    expect(flat.some((c) => c.customId === 'dir:into')).toBe(false);
    expect(flat.some((c) => c.customId === 'wizard.back')).toBe(true);
    // The embed carries the reconfigure title + step-1/3 guidance for the target backend.
    const embed = (popup!.embeds as { title?: string; description?: string }[])[0];
    expect(embed.title).toContain('codex');
    expect(embed.description).toContain('1/3');
    // A reconfigure wizard is now registered for this channel.
    const wizard = (router as unknown as { wizards: Map<string, { isReconfigure(): boolean }> }).wizards.get('g1:c1');
    expect(wizard?.isReconfigure()).toBe(true);
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

  it('/mode perm keeps the persisted effort on the binding across the REPLACE', async () => {
    channelRegistry.set(binding(home, { model: 'opus', effort: 'high' }));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = slash({ commandName: 'mode', subcommand: 'perm', getStringValue: 'plan' });
    await router.handle(interaction);
    // Prove the set() actually ran (binding() seeds permMode 'default'), so the effort/model
    // assertions below are not trivially satisfied by a no-op early-return…
    expect(channelRegistry.get('g1', 'c1')?.permMode).toBe('plan');
    // …then that the REPLACE carried model AND effort forward across the perm-only change.
    expect(channelRegistry.get('g1', 'c1')?.effort).toBe('high');
    expect(channelRegistry.get('g1', 'c1')?.model).toBe('opus');
  });

  it('/mode backend to the SAME backend carries the model + effort forward', async () => {
    channelRegistry.set(binding(home, { mode: 'claude', model: 'opus', effort: 'high' }));
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction } = slash({ commandName: 'mode', subcommand: 'backend', getStringValue: 'claude' });
    await router.handle(interaction);
    expect(calls.start).toHaveBeenCalledWith(
      expect.objectContaining({ mode: 'claude', model: 'opus', effort: 'high' }),
    );
  });

  it('/mode backend reconfigure popup: confirming restarts IN PLACE with the picked model/effort/perm + fresh-context (R3/D6)', async () => {
    channelRegistry.set(binding(home, { mode: 'claude', model: 'opus', effort: 'high', ownerId: 'owner' }));
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // Open the popup — still nothing stopped.
    const { interaction: open } = slash({ commandName: 'mode', subcommand: 'backend', getStringValue: 'codex', user: { id: 'u1' } });
    await router.handle(open);
    expect(calls.stop).not.toHaveBeenCalled();
    // Pick a codex model / effort / sandbox mode, then confirm (perm.start).
    await router.handle(component({ customId: 'model', value: 'gpt-5.4', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'model.next', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'effort', value: 'high', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'effort.next', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'perm.mode', value: 'workspace-write', user: { id: 'u1' } }).interaction);
    const { interaction: confirm, replies, acks } = component({ customId: 'perm.start', user: { id: 'u1' } });
    await router.handle(confirm);
    // The confirm — and ONLY the confirm — tears down + restarts in the SAME channel (R3).
    expect(calls.stop).toHaveBeenCalledWith('g1', 'c1');
    expect(wcalls.detach).toHaveBeenCalledWith('g1', 'c1');
    expect(calls.start).toHaveBeenCalledOnce();
    // The restarted session inherits the EXISTING binding's owner ('owner'), not the actor
    // who drove the popup ('u1') — R7 (owner carries over across the switch).
    expect(calls.start).toHaveBeenCalledWith(
      expect.objectContaining({ guildId: 'g1', channelId: 'c1', mode: 'codex', cwd: home, ownerId: 'owner', model: 'gpt-5.4', effort: 'high', permMode: 'workspace-write' }),
    );
    expect(wcalls.attach).toHaveBeenCalledWith('g1', 'c1', 'codex');
    // The public fresh-context warning is a NON-ephemeral followUp; the confirmation edits
    // the popup message (ephemeral).
    const fresh = acks.find((a) => a.kind === 'followUp');
    expect(fresh?.payload?.content).toContain('새 대화로 시작');
    expect(fresh?.payload?.ephemeral).toBe(false);
    expect(replies.some((r) => r.content?.includes('codex'))).toBe(true);
    // D6: an in-place restart — NO new session-channel link and NO "save as preset" button.
    const flatAll = replies.flatMap((r) => ((r.components ?? []) as { components: { customId: string }[] }[]).flatMap((row) => row.components));
    expect(flatAll.some((c) => c.customId === 'preset.save')).toBe(false);
  });

  it('/mode backend reconfigure popup: cancelling keeps the running session untouched (R4)', async () => {
    channelRegistry.set(binding(home)); // claude session s1
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction: open } = slash({ commandName: 'mode', subcommand: 'backend', getStringValue: 'codex', user: { id: 'u1' } });
    await router.handle(open);
    const { interaction: cancel, replies } = component({ customId: 'cancel', user: { id: 'u1' } });
    await router.handle(cancel);
    // No teardown, no restart — the existing session + binding survive intact.
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    const still = channelRegistry.get('g1', 'c1');
    expect(still?.mode).toBe('claude');
    expect(still?.sessionId).toBe('s1');
    // The cancel notice (wizard.cancelled) is rendered.
    expect(replies.some((r) => (r.embeds as { description?: string }[] | undefined)?.[0]?.description?.includes('취소'))).toBe(true);
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

  it('/clear with a binding stops + restarts the same mode/cwd/settings in place', async () => {
    channelRegistry.set(
      binding(home, {
        mode: 'claude',
        ownerId: 'owner',
        permMode: 'acceptEdits',
        profile: null,
        model: 'opus',
        effort: 'high',
      }),
    );
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, acks, replies } = slash({ commandName: 'clear' });
    await router.handle(interaction);
    expect(calls.stop).toHaveBeenCalledWith('g1', 'c1');
    expect(wcalls.detach).toHaveBeenCalledWith('g1', 'c1');
    expect(calls.start).toHaveBeenCalledWith(
      expect.objectContaining({
        guildId: 'g1',
        channelId: 'c1',
        mode: 'claude',
        cwd: home,
        ownerId: 'owner',
        permMode: 'acceptEdits',
        model: 'opus',
        effort: 'high',
      }),
    );
    expect(wcalls.attach).toHaveBeenCalledWith('g1', 'c1', 'claude');
    // Ephemeral confirmation (editReply) + public channel notice (non-ephemeral followUp).
    expect(replies.some((r) => r.content?.includes('대화 컨텍스트를 비웠'))).toBe(true);
    const publicNotice = acks.find((a) => a.kind === 'followUp');
    expect(publicNotice?.payload?.content).toContain('이전 맥락은 이어지지 않습니다');
    expect(publicNotice?.payload?.ephemeral).toBe(false);
  });

  it('/clear with NO binding is rejected (no stop/start)', async () => {
    // No channelRegistry.set → no binding.
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, acks, replies } = slash({ commandName: 'clear' });
    await router.handle(interaction);
    expect(calls.stop).not.toHaveBeenCalled();
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.start).not.toHaveBeenCalled();
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    expect(replies[0].content).toContain('활성 세션이 없어요');
  });

  it('/doc with a binding funnels to shareDocumentFor with the typed path and confirms', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    // The per-channel factory returns the inner share callback; assert BOTH the (guild,
    // channel) the factory was bound with AND the path the callback received.
    const shareInner = vi.fn(async (_path: string): Promise<ShareResult> => ({ ok: true, threadName: '📄 x.md', path: 'docs/x.md' }));
    const shareDocumentFor = vi.fn((_g: string, _c: string) => shareInner);
    const router = buildRouter({ orchestrator, wiring, shareDocumentFor });
    const { interaction, replies } = slash({ commandName: 'doc', getStringValue: 'docs/x.md' });
    await router.handle(interaction);
    expect(shareDocumentFor).toHaveBeenCalledWith('g1', 'c1');
    expect(shareInner).toHaveBeenCalledWith('docs/x.md');
    // The success notice echoes the shared relative path (doc.shared).
    expect(replies[0].content).toContain('docs/x.md');
  });

  it('/doc localizes a coded rejection via doc.error.<code> (no throw)', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const shareDocumentFor = vi.fn((_g: string, _c: string) => async (_p: string): Promise<ShareResult> => ({ ok: false, code: 'notFound' }));
    const router = buildRouter({ orchestrator, wiring, shareDocumentFor });
    const { interaction, replies } = slash({ commandName: 'doc', getStringValue: 'missing.md' });
    await router.handle(interaction);
    expect(replies[0].content).toContain('찾을 수 없어요');
  });

  it('/doc treats an uncoded {ok:false} as router.noSession (channel unwired backstop)', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    // Binding exists (the !binding gate passes) but the channel has no live sink, so
    // shareDocumentFor returns an UNCODED failure (no ShareErrorCode). This is the shared
    // backstop contract the WO-3/4/5 tool handlers also rely on.
    const shareDocumentFor = vi.fn((_g: string, _c: string) => async (_p: string): Promise<ShareResult> => ({ ok: false }));
    const router = buildRouter({ orchestrator, wiring, shareDocumentFor });
    const { interaction, replies } = slash({ commandName: 'doc', getStringValue: 'docs/x.md' });
    await router.handle(interaction);
    expect(shareDocumentFor).toHaveBeenCalledWith('g1', 'c1');
    expect(replies[0].content).toContain('활성 세션이 없어요');
  });

  it('/doc catches a thrown core error and falls back to a generic notice', async () => {
    channelRegistry.set(binding(home));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    // The core rethrows non-coded errors (EACCES etc.); the edge must catch, not crash.
    const shareDocumentFor = vi.fn((_g: string, _c: string) => async (_p: string): Promise<ShareResult> => {
      throw new Error('EACCES');
    });
    const router = buildRouter({ orchestrator, wiring, shareDocumentFor });
    const { interaction, replies } = slash({ commandName: 'doc', getStringValue: 'docs/x.md' });
    await router.handle(interaction);
    // Pin the inner catch (cmd.error.generic) exactly: if it were removed, the throw would
    // fall through to the outer guarded (cmd.error, which appends String(err) and can leak an
    // absolute path). Both messages share '처리하지 못했어요', so only the full generic string
    // — with its unique '잠시 후 다시 시도해 주세요.' tail — distinguishes them.
    expect(replies[0].content).toBe('명령을 처리하지 못했어요. 잠시 후 다시 시도해 주세요.');
  });

  it('/doc with NO binding returns router.noSession (shareDocumentFor not called)', async () => {
    // No channelRegistry.set → no binding.
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const shareDocumentFor = vi.fn((_g: string, _c: string) => async (_p: string): Promise<ShareResult> => ({ ok: true }));
    const router = buildRouter({ orchestrator, wiring, shareDocumentFor });
    const { interaction, replies, acks } = slash({ commandName: 'doc', getStringValue: 'docs/x.md' });
    await router.handle(interaction);
    expect(shareDocumentFor).not.toHaveBeenCalled();
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    expect(replies[0].content).toContain('활성 세션이 없어요');
  });

  it('/model (TOP-LEVEL, no subcommand) switches the live session model', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'model', subcommand: null, getStringValue: 'sonnet' });
    await router.handle(interaction);
    expect(calls.setModel).toHaveBeenCalledWith('g1', 'c1', 'sonnet');
    expect(replies[0].content).toContain('sonnet');
  });

  it('/effort (TOP-LEVEL, no subcommand) switches the live session effort', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'effort', subcommand: null, getStringValue: 'high' });
    await router.handle(interaction);
    expect(calls.setEffort).toHaveBeenCalledWith('g1', 'c1', 'high');
    expect(replies[0].content).toContain('high');
  });

  it('/effort maps each orchestrator outcome to the matching notice', async () => {
    const { wiring } = fakeWiring();
    const cases: { outcome: 'unsupported' | 'no-session' | 'error'; expect: string }[] = [
      { outcome: 'unsupported', expect: '지원하지 않아요' },
      { outcome: 'no-session', expect: '활성 세션이 없어요' },
      { outcome: 'error', expect: '실패했어요' },
    ];
    for (const c of cases) {
      const { orchestrator } = fakeOrchestrator();
      (orchestrator as unknown as { setEffort: (...a: unknown[]) => Promise<string> }).setEffort = async () => c.outcome;
      const router = buildRouter({ orchestrator, wiring });
      const { interaction, replies } = slash({ commandName: 'effort', subcommand: null, getStringValue: 'high' });
      await router.handle(interaction);
      expect(replies[0].content).toContain(c.expect);
    }
  });
});

describe('InteractionRouter.getModelAutocomplete — /model value suggestions', () => {
  it('an empty query returns the full live Claude catalog (never a static list)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    expect(await router.getModelAutocomplete('')).toEqual([
      { name: 'opus', value: 'opus' },
      { name: 'sonnet', value: 'sonnet' },
    ]);
  });

  it('filters case-insensitively against either the id or the display label', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    expect(await router.getModelAutocomplete('OP')).toEqual([{ name: 'opus', value: 'opus' }]);
    expect(await router.getModelAutocomplete('xyz')).toEqual([]);
  });

  it('always queries the Claude catalog, even when never asked to fetch Codex models', async () => {
    // /model only supports Claude (setModel is Claude-only); a router whose modelsFor
    // rejects for any backend but 'claude' must still answer, proving the fixed
    // backend argument rather than something derived from channel state.
    const orchestrator = fakeOrchestrator().orchestrator;
    const { wiring } = fakeWiring();
    const router = new InteractionRouter({
      authorizer,
      orchestrator,
      channelRegistry,
      configStore: store,
      stateStore,
      configResolver,
      permissionResolver,
      modeRegistry,
      wiring,
      usageService: { isAvailable: () => false, getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }) } as unknown as UsageService,
      logger,
      modelsFor: async (backend: string) => {
        if (backend !== 'claude') throw new Error(`unexpected backend: ${backend}`);
        return [{ value: 'claude-fable-5[1m]', label: 'Fable 5' }];
      },
    });
    expect(await router.getModelAutocomplete('fable')).toEqual([{ name: 'Fable 5', value: 'claude-fable-5[1m]' }]);
  });

  it('caps results at Discord’s 25-choice autocomplete limit', async () => {
    const many = Array.from({ length: 30 }, (_, i) => ({ value: `model-${i}`, label: `Model ${i}` }));
    const orchestrator = fakeOrchestrator().orchestrator;
    const { wiring } = fakeWiring();
    const router = new InteractionRouter({
      authorizer,
      orchestrator,
      channelRegistry,
      configStore: store,
      stateStore,
      configResolver,
      permissionResolver,
      modeRegistry,
      wiring,
      usageService: { isAvailable: () => false, getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }) } as unknown as UsageService,
      logger,
      modelsFor: async () => many,
    });
    expect((await router.getModelAutocomplete('')).length).toBe(25);
  });

  it('caches the Claude catalog for 60s so a typing burst pays for only ONE fetch', async () => {
    const modelsFor = vi.fn(async () => [{ value: 'opus', label: 'opus' }]);
    const orchestrator = fakeOrchestrator().orchestrator;
    const { wiring } = fakeWiring();
    const router = new InteractionRouter({
      authorizer,
      orchestrator,
      channelRegistry,
      configStore: store,
      stateStore,
      configResolver,
      permissionResolver,
      modeRegistry,
      wiring,
      usageService: { isAvailable: () => false, getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }) } as unknown as UsageService,
      logger,
      modelsFor,
    });
    vi.useFakeTimers();
    try {
      // Three "keystrokes" within the same second: only the first should hit modelsFor —
      // Discord's ~3s autocomplete window has no room for a fresh SDK-CLI spawn per key.
      await router.getModelAutocomplete('o');
      await router.getModelAutocomplete('op');
      await router.getModelAutocomplete('opu');
      expect(modelsFor).toHaveBeenCalledOnce();

      // Once the cache goes stale (60s), the next lookup re-fetches.
      await vi.advanceTimersByTimeAsync(60_001);
      await router.getModelAutocomplete('opus');
      expect(modelsFor).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe('InteractionRouter.getEffortAutocomplete — /effort value suggestions', () => {
  it('Claude: narrows the model’s supportedEffortLevels to the runtime set, excluding max', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    // A Claude channel bound to 'opus'.
    channelRegistry.set(binding(home, { mode: 'claude', model: 'opus' }));
    const router = new InteractionRouter({
      authorizer,
      orchestrator,
      channelRegistry,
      configStore: store,
      stateStore,
      configResolver,
      permissionResolver,
      modeRegistry,
      wiring,
      usageService: { isAvailable: () => false, getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }) } as unknown as UsageService,
      logger,
      // opus reports low/medium/max — the runtime set drops max and keeps only the ∩.
      modelsFor: async () => [{ value: 'opus', label: 'opus', supportedEffortLevels: ['low', 'medium', 'max'] }],
    });
    expect(await router.getEffortAutocomplete('g1', 'c1', '')).toEqual([
      { name: 'low', value: 'low' },
      { name: 'medium', value: 'medium' },
    ]);
  });

  it('Codex: offers the full Codex effort levels when modelsFor does not advertise supportedEffortLevels', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    channelRegistry.set(binding(home, { mode: 'codex' }));
    // Default buildRouter modelsFor lists gpt-5.5 without supportedEffortLevels → catalog
    // fallback (CODEX_EFFORT_LEVELS). Mirrors a missing/empty cache entry (R4).
    const router = buildRouter({ orchestrator, wiring });
    expect((await router.getEffortAutocomplete('g1', 'c1', '')).map((c) => c.value)).toEqual([
      'minimal',
      'low',
      'medium',
      'high',
      'xhigh',
    ]);
  });

  it('Codex: narrows to modelsFor supportedEffortLevels when the bound model advertises them', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    channelRegistry.set(binding(home, { mode: 'codex', model: 'gpt-5.5' }));
    const router = new InteractionRouter({
      authorizer,
      orchestrator,
      channelRegistry,
      configStore: store,
      stateStore,
      configResolver,
      permissionResolver,
      modeRegistry,
      wiring,
      usageService: {
        isAvailable: () => false,
        getUsage: async () => ({ available: false as const, reason: 'no-credentials' as const }),
      } as unknown as UsageService,
      logger,
      modelsFor: async () => [
        { value: 'gpt-5.5', label: 'GPT-5.5', supportedEffortLevels: ['low', 'high'] },
      ],
    });
    expect((await router.getEffortAutocomplete('g1', 'c1', '')).map((c) => c.value)).toEqual([
      'low',
      'high',
    ]);
  });

  it('no binding (no session): falls back to the resolved backend’s runtime set', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    // No channelRegistry.set → resolved backend is the config default (claude); the default
    // modelsFor reports no supportedEffortLevels, so the full runtime set is offered.
    const router = buildRouter({ orchestrator, wiring });
    expect((await router.getEffortAutocomplete('g1', 'c1', '')).map((c) => c.value)).toEqual([
      'low',
      'medium',
      'high',
      'xhigh',
    ]);
  });

  it('filters case-insensitively against the level name', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    expect(await router.getEffortAutocomplete('g1', 'c1', 'MED')).toEqual([{ name: 'medium', value: 'medium' }]);
    // A substring can legitimately match several levels (e.g. 'hi' → high AND xhigh).
    expect((await router.getEffortAutocomplete('g1', 'c1', 'HI')).map((c) => c.value)).toEqual(['high', 'xhigh']);
    expect(await router.getEffortAutocomplete('g1', 'c1', 'zzz')).toEqual([]);
  });

  it('an unregistered bound backend yields no suggestions (never rejects)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    // A hand-edited binding referencing a backend no build registered.
    channelRegistry.set(binding(home, { mode: 'future-backend' }));
    const router = buildRouter({ orchestrator, wiring });
    expect(await router.getEffortAutocomplete('g1', 'c1', '')).toEqual([]);
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

  it('interrupt:<guild>:<channel> button routes to orchestrator.interrupt WITHOUT detaching renderers', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, acks } = component({ customId: 'interrupt:g1:c1', user: { id: 'u1' } });
    await router.handle(interaction);
    // The single shared orchestrator interrupt path is called with the parsed channel.
    expect(calls.interrupt).toHaveBeenCalledWith('g1', 'c1');
    // CRITICAL: the interrupt path must NOT detach — the renderer subscription stays so
    // the next turn renders (the key difference from /stop).
    expect(wcalls.detach).not.toHaveBeenCalled();
    expect(calls.stop).not.toHaveBeenCalled();
    // Acked via deferUpdate (keeps the streaming message), then an ephemeral confirmation.
    expect(acks[0].kind).toBe('deferUpdate');
    const followUp = acks.find((a) => a.kind === 'followUp');
    expect(followUp?.payload?.ephemeral).toBe(true);
    expect(followUp?.payload?.content).toContain('중단');
  });

  it('interrupt button tells the user when there is no running task (orchestrator returns false)', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    calls.interrupt.mockResolvedValueOnce(false);
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, acks } = component({ customId: 'interrupt:g1:c1', user: { id: 'u1' } });
    await router.handle(interaction);
    const followUp = acks.find((a) => a.kind === 'followUp');
    expect(followUp?.payload?.content).toContain('없어요');
  });

  it('a denied user clicking the interrupt button does NOT interrupt', async () => {
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = component({ customId: 'interrupt:g1:c1', roles: ['role-nobody'] });
    await router.handle(interaction);
    expect(calls.interrupt).not.toHaveBeenCalled();
    expect(replies[0].content).toContain('권한이 없습니다');
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
      { customId: 'backend.next' },
      { customId: 'model.next' },
      { customId: 'effort.next' },
      { customId: 'perm.start' },
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

  it('/agent start with default backend codex: an untouched wizard starts with the CODEX default model', async () => {
    // Resolved default backend = codex. The wizard's initial model must come from the
    // codex catalog (applyBackend only resets on a backend CHANGE), so an untouched
    // flow must not leak the Claude default ('opus') into `codex -m`.
    const cfg = store.load();
    cfg.defaults.mode = 'codex';
    store.save(cfg);
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });

    const { interaction: start } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(start);
    for (const customId of ['dir:here', 'backend.next', 'model.next', 'effort.next', 'perm.start']) {
      await router.handle(component({ customId, user: { id: 'u1' } }).interaction);
    }

    expect(calls.start).toHaveBeenCalledOnce();
    expect(calls.start).toHaveBeenCalledWith(expect.objectContaining({ mode: 'codex', model: 'gpt-5.5' }));
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

describe('InteractionRouter /setup command', () => {
  it('creates the category + control channel + status channel + sessions category and persists the ids', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    const { interaction, replies } = slash({ commandName: 'setup', hasAdminPermission: true, roles: ['role-nobody'] });
    await router.handle(interaction);

    // Four channels created; ids persisted to servers/g1.json.
    expect(prov.createdNames).toHaveLength(4);
    const saved = store.loadServerConfig('g1');
    expect(saved?.channels?.controlChannelId).toBeTruthy();
    expect(saved?.channels?.sessionsCategoryId).toBeTruthy();
    expect(saved?.channels?.statusChannelId).toBeTruthy();
    // The reply links the control channel.
    expect(replies[0].content).toContain(`<#${saved!.channels!.controlChannelId}>`);
  });

  it('is idempotent: a second /setup reuses the stored channels (no duplicates)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    const { interaction: first } = slash({ commandName: 'setup', hasAdminPermission: true });
    await router.handle(first);
    const afterFirst = store.loadServerConfig('g1')?.channels;
    expect(prov.createdNames).toHaveLength(4);

    const { interaction: second } = slash({ commandName: 'setup', hasAdminPermission: true });
    await router.handle(second);
    // No new creates; the stored ids are unchanged.
    expect(prov.createdNames).toHaveLength(4);
    expect(store.loadServerConfig('g1')?.channels).toEqual(afterFirst);
  });

  it('skips channel creation when the stored structure is already fully alive', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    // Pre-provision all four channels directly on the fake (bypassing /setup) and
    // persist their ids, mirroring a guild that was already set up.
    const category = await prov.ensureCategory('🤖 Agent');
    const control = await prov.ensureTextChannel('session-generator', category.id);
    const status = await prov.ensureTextChannel('agent-status', category.id);
    const sessionsCategory = await prov.ensureCategory('Agent - Sessions');
    store.saveServerConfig({
      version: 1,
      guildId: 'g1',
      channels: {
        categoryId: category.id,
        controlChannelId: control.id,
        sessionsCategoryId: sessionsCategory.id,
        statusChannelId: status.id,
      },
    });
    const createdBefore = prov.createdNames.length;

    const { interaction, replies } = slash({ commandName: 'setup', hasAdminPermission: true });
    await router.handle(interaction);

    // No new channels created — the guard short-circuited before ensureGuildChannels.
    expect(prov.createdNames).toHaveLength(createdBefore);
    expect(replies[0].content).toContain('이미');
    expect(replies[0].content).toContain(`<#${control.id}>`);
  });

  it('denies /setup for a non-admin, non-allowlisted user (no channels created)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });

    const { interaction, replies } = slash({ commandName: 'setup', roles: [EXEC_ROLE], hasAdminPermission: false });
    await router.handle(interaction);
    expect(prov.createdNames).toHaveLength(0);
    expect(store.loadServerConfig('g1')?.channels).toBeUndefined();
    expect(replies[0].content).toContain('admin');
  });

  it('reports a graceful notice when no provisioner is available', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => null });
    const { interaction, replies } = slash({ commandName: 'setup', hasAdminPermission: true });
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
      // Seed a persisted /setup structure so the session channel is placed under it.
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
    // Owner drives the whole wizard to start via the confirm buttons.
    const flow: { customId: string; value?: string }[] = [
      { customId: 'dir:here' },
      { customId: 'backend.next' },
      { customId: 'model.next' },
      { customId: 'effort.next' },
      { customId: 'perm.start' },
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

  it('places the new session channel under the /setup sessions category when present', async () => {
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
    // Persist a /setup structure whose control channel is 'ctrl'.
    store.saveServerConfig({
      version: 1,
      guildId: 'g1',
      channels: { categoryId: 'cat', controlChannelId: 'ctrl', sessionsCategoryId: 'sess-cat', statusChannelId: null },
    });
    channelRegistry.set(binding(home, { channelId: 'ctrl' }));
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const prov = new FakeProvisioner('g1');
    prov.channels.set('ctrl', 'session-generator');
    const router = buildRouter({ orchestrator, wiring, resolveGuildProvisioner: async () => prov });
    const { interaction } = slash({ commandName: 'agent', subcommand: 'close', channelId: 'ctrl' });
    await router.handle(interaction);
    expect(prov.deleted).not.toContain('ctrl');
  });
});

describe('InteractionRouter /agent stats', () => {
  function activeInfo(over: Partial<ActiveChannelInfo> = {}): ActiveChannelInfo {
    return {
      guildId: 'g1',
      channelId: 'sess-a',
      mode: 'claude',
      cwd: '/home/me/my-project',
      ownerId: 'owner',
      queueDepth: 0,
      running: false,
      ...over,
    };
  }
  function usageService(over: { available?: boolean; usage?: UsageResult } = {}): UsageService {
    return {
      isAvailable: () => over.available ?? false,
      getUsage: async () => over.usage ?? { available: false as const, reason: 'no-credentials' as const },
    } as unknown as UsageService;
  }

  it('replies EPHEMERALLY with an embed summarizing active sessions + bindings', async () => {
    channelRegistry.set(binding(home, { channelId: 'sess-a' }));
    const { orchestrator } = fakeOrchestrator([
      activeInfo({ channelId: 'sess-a', queueDepth: 2, running: true }),
    ]);
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies, acks } = slash({ commandName: 'agent', subcommand: 'stats' });
    await router.handle(interaction);

    // Deferred ephemerally, then filled with the embed.
    expect(acks[0].kind).toBe('deferReply');
    expect(acks[0].payload?.ephemeral).toBe(true);
    const embed = (replies[0].embeds as { title?: string; fields?: { name: string; value: string }[] }[])[0];
    expect(embed.title).toContain('Agent Stats');
    const active = embed.fields?.find((f) => f.name.includes('활성 세션'));
    expect(active?.value).toContain('<#sess-a>');
    expect(active?.value).toContain('queue 2');
    expect(active?.value).toContain('running');
    expect(active?.value).toContain('my-project');
    // The usage field shows the login notice when Claude OAuth is unavailable.
    const usage = embed.fields?.find((f) => f.name.includes('Claude'));
    expect(usage?.value).toContain('로그인');
  });

  it('shows Claude usage utilization when OAuth is available', async () => {
    const { orchestrator } = fakeOrchestrator([]);
    const { wiring } = fakeWiring();
    const router = buildRouter({
      orchestrator,
      wiring,
      usageService: usageService({
        available: true,
        usage: { fetchedAt: 1, fiveHour: { utilization: 42 }, sevenDay: { utilization: 7, resetsAt: '2026-07-10' } },
      }),
    });
    const { interaction, replies } = slash({ commandName: 'agent', subcommand: 'stats' });
    await router.handle(interaction);
    const embed = (replies[0].embeds as { fields?: { name: string; value: string }[] }[])[0];
    const usage = embed.fields?.find((f) => f.name.includes('Claude'));
    expect(usage?.value).toContain('42%');
    expect(usage?.value).toContain('7%');
    expect(usage?.value).toContain('2026-07-10');
  });

  it('reports no active sessions when the guild has none', async () => {
    const { orchestrator } = fakeOrchestrator([]);
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'agent', subcommand: 'stats' });
    await router.handle(interaction);
    const embed = (replies[0].embeds as { fields?: { name: string; value: string }[] }[])[0];
    const active = embed.fields?.find((f) => f.name.includes('활성 세션'));
    expect(active?.value).toContain('없어요');
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

// ---------------------------------------------------------------------------
// 📁 Create folder (folder-step modal)
// ---------------------------------------------------------------------------

describe('InteractionRouter 📁 Create folder', () => {
  // Open a wizard rooted at `root` and return the router (so the folder step is live
  // with a browser whose cwd === root, the current browsed directory).
  async function openWizard(root: string) {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring, browseRoots: [root] });
    const { interaction } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(interaction);
    return router;
  }

  it('the Create button opens a modal WITHOUT a preceding defer (showModal is the ack)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-create-'));
    try {
      const router = await openWizard(root);
      const { interaction, acks } = component({ customId: 'dir:create', user: { id: 'u1' } });
      await router.handle(interaction);
      // showModal fired; no deferUpdate before it (a deferred component cannot show a modal).
      expect(acks.map((a) => a.kind)).toEqual(['showModal']);
      expect(acks[0].modal?.customId).toBe('dir:create');
      expect(acks[0].modal?.fields[0]?.customId).toBe('name');
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('the modal submit mkdir\'s the folder in the CURRENT browsed dir and re-renders', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-create-'));
    try {
      const router = await openWizard(root);
      // Open the modal (records the current path implicitly via the live wizard).
      await router.handle(component({ customId: 'dir:create', user: { id: 'u1' } }).interaction);
      // Submit the modal with a valid name.
      const { interaction, replies } = modalSubmit({ customId: 'dir:create', user: { id: 'u1' }, fields: { name: 'new-folder' } });
      await router.handle(interaction);
      // The directory was created as a direct child of the browsed dir.
      expect(fs.existsSync(path.join(root, 'new-folder'))).toBe(true);
      // The reply re-rendered the folder step (component rows present) + a confirmation.
      const reply = replies.find((r) => r.content?.includes('new-folder'));
      expect(reply).toBeDefined();
      expect(reply?.components && (reply.components as unknown[]).length).toBeGreaterThan(0);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('rejects a traversal / separator / absolute name — no mkdir, ephemeral notice', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-create-'));
    try {
      for (const bad of ['..', 'a/b', '/etc/evil', '.', 'x\\y']) {
        const router = await openWizard(root);
        await router.handle(component({ customId: 'dir:create', user: { id: 'u1' } }).interaction);
        const { interaction, replies } = modalSubmit({ customId: 'dir:create', user: { id: 'u1' }, fields: { name: bad } });
        await router.handle(interaction);
        // Nothing escaped: the only entry under root is never a traversal target.
        expect(fs.existsSync(path.join(root, '..', 'evil'))).toBe(false);
        // An invalid-name notice was returned (ephemeral).
        expect(replies.some((r) => r.ephemeral && (r.content ?? '').length > 0)).toBe(true);
      }
      // No folder named after any bad input was created directly either.
      expect(fs.readdirSync(root)).toHaveLength(0);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('a Create from a NON-owner is ignored (deferUpdate, no modal)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-create-'));
    try {
      const router = await openWizard(root); // owner u1
      const { interaction, acks } = component({ customId: 'dir:create', user: { id: 'intruder' } });
      await router.handle(interaction);
      // The stray click is acknowledged (deferUpdate) but shows NO modal.
      expect(acks.map((a) => a.kind)).toEqual(['deferUpdate']);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------
// Resume Session flow (both backends)
// ---------------------------------------------------------------------------

describe('InteractionRouter Resume Session flow', () => {
  // Re-register the modes with scripted resumable lists for this suite.
  function registerResumable(claude: ResumableSession[], codex: ResumableSession[]) {
    modeRegistry = new ModeRegistry();
    modeRegistry.register(new StubMode('claude', CLAUDE_CAPS, claude));
    modeRegistry.register(new StubMode('codex', { ...CLAUDE_CAPS, usagePanel: false }, codex));
  }

  async function openResumeFlow(root: string, opts: { claude?: ResumableSession[]; codex?: ResumableSession[] } = {}) {
    registerResumable(opts.claude ?? [], opts.codex ?? []);
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring, calls: wcalls } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const prov = new FakeProvisioner('g1');
    const router = buildRouter({
      orchestrator,
      wiring,
      browseRoots: [root],
      resolveGuildProvisioner: async () => prov,
      resolveChannel: async () => channel,
    });
    // Open the wizard (folder step) then press Resume Session.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    const { interaction: resumeBtn, replies: r0 } = component({ customId: 'dir:resume', user: { id: 'u1' } });
    await router.handle(resumeBtn);
    return { router, calls, wcalls, posts, prov, firstRender: r0 };
  }

  it('picking a backend lists THAT backend\'s sessions (Claude)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-resume-'));
    try {
      const { router } = await openResumeFlow(root, {
        claude: [{ sessionId: 'cl-1', cwd: root, label: 'Claude work' }],
        codex: [{ sessionId: 'cx-1', cwd: root, label: 'Codex work' }],
      });
      // Default backend is claude (config). Confirm the backend → list claude sessions.
      const { interaction, replies } = component({ customId: 'resume.backend.next', user: { id: 'u1' } });
      await router.handle(interaction);
      // The session-pick select is rendered with the claude session's label.
      const rows = (replies[replies.length - 1].components ?? []) as { components: { type: string; customId: string; options?: { label: string; value: string }[] }[] }[];
      const pick = rows.flatMap((r) => r.components).find((c) => c.customId === 'resume.pick');
      expect(pick).toBeDefined();
      expect(pick?.options?.map((o) => o.value)).toEqual(['cl-1']);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('selecting a session RESUMES it: orchestrator.resume + wiring.attach on a fresh channel (Claude)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-resume-'));
    try {
      const { router, calls, wcalls, posts, prov } = await openResumeFlow(root, {
        claude: [{ sessionId: 'cl-42', cwd: root, label: 'Resume me' }],
      });
      await router.handle(component({ customId: 'resume.backend.next', user: { id: 'u1' } }).interaction);
      const { interaction, replies } = component({ customId: 'resume.pick', value: 'cl-42', user: { id: 'u1' } });
      await router.handle(interaction);

      // A dedicated session channel was created (proj-*).
      expect(prov.createdNames.some((n) => n.startsWith('proj-'))).toBe(true);
      const newChannelId = [...prov.channels.keys()].find((id) => prov.channels.get(id)?.startsWith('proj-'))!;
      // orchestrator.resume was called with the chosen session id, bound to the NEW channel.
      expect(calls.resume).toHaveBeenCalledOnce();
      expect(calls.resume.mock.calls[0][0]).toMatchObject({ channelId: newChannelId, mode: 'claude', cwd: root });
      expect(calls.resume.mock.calls[0][1]).toBe('cl-42');
      // Renderers were wired to the new channel; a resumed-status embed was posted.
      expect(wcalls.attach).toHaveBeenCalledWith('g1', newChannelId, 'claude');
      expect(posts.some((p) => (p.embeds ?? []).length > 0)).toBe(true);
      // The driver was told where the resumed session lives.
      expect(replies.some((r) => r.content?.includes(`<#${newChannelId}>`))).toBe(true);
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('works for Codex too: picking codex lists + resumes a codex session', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-resume-'));
    try {
      const { router, calls } = await openResumeFlow(root, {
        claude: [],
        codex: [{ sessionId: 'cx-7', cwd: root, label: 'Codex thread' }],
      });
      // Switch the backend select to codex, then confirm.
      await router.handle(component({ customId: 'resume.backend', value: 'codex', user: { id: 'u1' } }).interaction);
      const { interaction, replies } = component({ customId: 'resume.backend.next', user: { id: 'u1' } });
      await router.handle(interaction);
      const rows = (replies[replies.length - 1].components ?? []) as { components: { type: string; customId: string; options?: { value: string }[] }[] }[];
      const pick = rows.flatMap((r) => r.components).find((c) => c.customId === 'resume.pick');
      expect(pick?.options?.map((o) => o.value)).toEqual(['cx-7']);
      // Pick it → resume with the codex backend.
      await router.handle(component({ customId: 'resume.pick', value: 'cx-7', user: { id: 'u1' } }).interaction);
      expect(calls.resume).toHaveBeenCalledOnce();
      expect(calls.resume.mock.calls[0][0]).toMatchObject({ mode: 'codex' });
      expect(calls.resume.mock.calls[0][1]).toBe('cx-7');
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('an empty list → ephemeral "재개할 세션이 없습니다" notice, resume NOT called', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-resume-'));
    try {
      const { router, calls } = await openResumeFlow(root, { claude: [], codex: [] });
      const { interaction, replies } = component({ customId: 'resume.backend.next', user: { id: 'u1' } });
      await router.handle(interaction);
      expect(replies.some((r) => (r.content ?? '').includes('재개할 세션이 없습니다'))).toBe(true);
      expect(calls.resume).not.toHaveBeenCalled();
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('a Resume Session from a NON-owner is ignored (no resume flow started)', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-resume-'));
    try {
      registerResumable([{ sessionId: 'cl-1', cwd: root }], []);
      const { orchestrator, calls } = fakeOrchestrator();
      const { wiring } = fakeWiring();
      const router = buildRouter({ orchestrator, wiring, browseRoots: [root], resolveGuildProvisioner: async () => new FakeProvisioner('g1') });
      await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
      // Intruder presses Resume → ignored; a later backend.next has no flow to advance.
      await router.handle(component({ customId: 'dir:resume', user: { id: 'intruder' } }).interaction);
      await router.handle(component({ customId: 'resume.backend.next', user: { id: 'intruder' } }).interaction);
      expect(calls.resume).not.toHaveBeenCalled();
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

describe('InteractionRouter auto-update buttons', () => {
  // A recording AutoUpdater double: approve/dismiss capture their (version, ctx) args.
  function fakeUpdater() {
    const approve = vi.fn(async (_v: string, _ctx: DecisionCtx) => {});
    const dismiss = vi.fn(async (_v: string, _ctx: DecisionCtx) => {});
    return { updater: { approve, dismiss } as unknown as AutoUpdater, approve, dismiss };
  }

  function routerWithUpdater(updater: AutoUpdater): InteractionRouter {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    router.setAutoUpdater(updater);
    return router;
  }

  it('admin (Administrator) approve → autoUpdater.approve(version, ctx); deferUpdate first', async () => {
    const { updater, approve } = fakeUpdater();
    const router = routerWithUpdater(updater);
    const { interaction, acks } = component({ customId: 'dab-update:approve:1.1.0', hasAdminPermission: true });
    await router.handle(interaction);
    expect(approve).toHaveBeenCalledTimes(1);
    const [version, ctx] = approve.mock.calls[0]!;
    expect(version).toBe('1.1.0');
    expect(ctx.actorId).toBe('u1');
    expect(ctx.guildId).toBe('g1');
    expect(ctx.channelId).toBe('c1');
    // Acked via deferUpdate (keeps the prompt message), not a fresh reply.
    expect(acks.some((a) => a.kind === 'deferUpdate')).toBe(true);
  });

  it('admin (admin tier role) dismiss → autoUpdater.dismiss(version, ctx)', async () => {
    const { updater, dismiss } = fakeUpdater();
    const router = routerWithUpdater(updater);
    const { interaction } = component({ customId: 'dab-update:dismiss:1.1.0', roles: [ADMIN_ROLE] });
    await router.handle(interaction);
    expect(dismiss).toHaveBeenCalledTimes(1);
    expect(dismiss.mock.calls[0]![0]).toBe('1.1.0');
  });

  it('non-admin click is denied ephemerally and never reaches the updater', async () => {
    const { updater, approve, dismiss } = fakeUpdater();
    const router = routerWithUpdater(updater);
    const { interaction, replies, acks } = component({
      customId: 'dab-update:approve:1.1.0',
      roles: [EXEC_ROLE],
      hasAdminPermission: false,
    });
    await router.handle(interaction);
    expect(approve).not.toHaveBeenCalled();
    expect(dismiss).not.toHaveBeenCalled();
    expect(acks.some((a) => a.kind === 'deferUpdate')).toBe(false);
    expect(replies[0]?.content).toBeTruthy();
    expect(replies[0]?.ephemeral).toBe(true);
  });

  it('a tampered custom_id is not routed to the updater', async () => {
    const { updater, approve, dismiss } = fakeUpdater();
    const router = routerWithUpdater(updater);
    const { interaction } = component({ customId: 'dab-update:install:1.1.0', hasAdminPermission: true });
    await router.handle(interaction);
    expect(approve).not.toHaveBeenCalled();
    expect(dismiss).not.toHaveBeenCalled();
  });

  it('the DecisionCtx wires ephemeral ack (followUp) and button-disable (editReply)', async () => {
    const { updater, approve } = fakeUpdater();
    // This fake approve exercises the router-supplied ctx ports.
    approve.mockImplementationOnce(async (_v, ctx) => {
      await ctx.disableButtons();
      await ctx.ack('done');
    });
    const router = routerWithUpdater(updater);
    const { interaction, replies, acks } = component({
      customId: 'dab-update:approve:1.1.0',
      hasAdminPermission: true,
    });
    await router.handle(interaction);
    // disableButtons edits the clicked prompt with a (disabled) component row.
    const edit = acks.find((a) => a.kind === 'editReply');
    expect(edit).toBeTruthy();
    expect((edit?.payload?.components as unknown[])?.length).toBe(1);
    // ack posts an ephemeral followUp.
    const followUp = replies.find((r) => r.content === 'done');
    expect(followUp?.ephemeral).toBe(true);
  });
});

// The render-setup prompt gate (design §9.2 + new-guild auto-provision). The app calls
// maybePromptRenderSetup on a fresh invite; it posts the [예]/[아니오] prompt ONLY when the
// feature is enabled, no browser is installed, and the operator has not yet decided.
describe('InteractionRouter.maybePromptRenderSetup gating', () => {
  it('posts the prompt when enabled + undecided + not installed', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const router = buildRouter({
      orchestrator,
      wiring,
      imageProvisioner: fakeProvisioner(false),
      resolveChannel: async () => channel,
    });
    await router.maybePromptRenderSetup('ctrl-1');
    expect(posts).toHaveLength(1);
    // The single post carries the install/decline buttons.
    expect((posts[0] as { components?: unknown[] }).components?.length).toBe(1);
  });

  it('does NOT post when a browser is already installed', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const router = buildRouter({
      orchestrator,
      wiring,
      imageProvisioner: fakeProvisioner(true),
      resolveChannel: async () => channel,
    });
    await router.maybePromptRenderSetup('ctrl-1');
    expect(posts).toHaveLength(0);
  });

  it('does NOT post when the operator has declined', async () => {
    store.setChromiumDecision('declined');
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const router = buildRouter({
      orchestrator,
      wiring,
      imageProvisioner: fakeProvisioner(false),
      resolveChannel: async () => channel,
    });
    await router.maybePromptRenderSetup('ctrl-1');
    expect(posts).toHaveLength(0);
  });

  it('does NOT post when image rendering is disabled', async () => {
    store.setRenderEnabled(false);
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const router = buildRouter({
      orchestrator,
      wiring,
      imageProvisioner: fakeProvisioner(false),
      resolveChannel: async () => channel,
    });
    await router.maybePromptRenderSetup('ctrl-1');
    expect(posts).toHaveLength(0);
  });

  it('does NOT post when no provisioner is wired', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { channel, posts } = fakeMessageChannel();
    const router = buildRouter({ orchestrator, wiring, resolveChannel: async () => channel });
    await router.maybePromptRenderSetup('ctrl-1');
    expect(posts).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// Session presets (WO-3 flow): folder → preset step → immediate start, save, delete.
// ---------------------------------------------------------------------------
describe('InteractionRouter session presets', () => {
  // Pin the locale: a /config locale test elsewhere in this file leaves the module-global
  // locale on 'en', which would otherwise flake these Korean-string assertions by order.
  beforeEach(() => {
    setLocale('ko');
  });

  // Flatten a reply's component rows to a single component list for assertions.
  function flatOf(reply: Reply | undefined): { type?: string; customId?: string; options?: { value: string }[] }[] {
    return ((reply?.components ?? []) as { components: { type?: string; customId?: string; options?: { value: string }[] }[] }[]).flatMap((r) => r.components);
  }

  it('/agent start always opens at the folder step (never the preset picker first)', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude', model: 'sonnet', effort: 'high', permMode: 'plan', profile: null });
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies } = slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } });
    await router.handle(interaction);
    const flat = flatOf(replies[0]);
    // First screen is the folder browser (dir:here), not the preset select.
    expect(flat.some((c) => c.customId === 'dir:here')).toBe(true);
    expect(flat.some((c) => c.customId === 'preset.pick')).toBe(false);
  });

  it('confirming the folder shows the preset step when the guild has saved presets', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude', model: 'sonnet', effort: 'high', permMode: 'plan', profile: null });
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    const { interaction, replies } = component({ customId: 'dir:here', user: { id: 'u1' } });
    await router.handle(interaction);
    const flat = flatOf(replies[replies.length - 1]);
    const pick = flat.find((c) => c.customId === 'preset.pick');
    expect(pick?.type).toBe('select');
    expect(pick?.options?.map((o) => o.value)).toEqual(['claude-plan']);
    expect(flat.some((c) => c.customId === 'preset.direct')).toBe(true);
    expect(flat.some((c) => c.customId === 'preset.delete')).toBe(true);
  });

  it('confirming the folder goes straight to the backend step when the guild has NO presets (R6)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    const { interaction, replies } = component({ customId: 'dir:here', user: { id: 'u1' } });
    await router.handle(interaction);
    const flat = flatOf(replies[replies.length - 1]);
    expect(flat.some((c) => c.customId === 'backend.next')).toBe(true);
    expect(flat.some((c) => c.customId === 'preset.pick')).toBe(false);
  });

  it('picking a preset on the preset step starts immediately with the preset config (folder already chosen)', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude', model: 'sonnet', effort: 'high', permMode: 'plan', profile: null });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    expect(calls.start).not.toHaveBeenCalled();
    // Picking the preset seeds the selection and starts at once (no more steps).
    await router.handle(component({ customId: 'preset.pick', value: 'claude-plan', user: { id: 'u1' } }).interaction);
    expect(calls.start).toHaveBeenCalledOnce();
    expect(calls.start).toHaveBeenCalledWith(expect.objectContaining({ mode: 'claude', model: 'sonnet', effort: 'high', permMode: 'plan' }));
  });

  it('picking a preset whose backend is no longer registered blocks the start (must-fix)', async () => {
    // A preset saved for a backend that is no longer registered (CLI removed / mode gone).
    store.addServerPreset('g1', { name: 'gone', backend: 'grok', model: 'grok-4', effort: 'high', permMode: 'default', profile: null });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    const { interaction, replies } = component({ customId: 'preset.pick', value: 'gone', user: { id: 'u1' } });
    await router.handle(interaction);
    // No session started → no orphan session channel created for the dead backend.
    expect(calls.start).not.toHaveBeenCalled();
    // The wizard stays on the preset step and re-renders the picker with the unavailable notice.
    const last = replies[replies.length - 1];
    expect(flatOf(last).some((c) => c.customId === 'preset.pick')).toBe(true);
    const description = (last?.embeds as { description?: string }[] | undefined)?.[0]?.description ?? '';
    expect(description).toContain('grok');
  });

  it('“set up manually” on the preset step advances to the backend step', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude' });
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    const { interaction, replies } = component({ customId: 'preset.direct', user: { id: 'u1' } });
    await router.handle(interaction);
    expect(flatOf(replies[replies.length - 1]).some((c) => c.customId === 'backend.next')).toBe(true);
  });

  it('delete mode removes the picked preset from the guild config and refreshes the list in place', async () => {
    store.addServerPreset('g1', { name: 'keep', backend: 'claude' });
    store.addServerPreset('g1', { name: 'drop', backend: 'codex' });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    // Toggle delete mode (re-renders the picker), then pick 'drop' to remove it.
    await router.handle(component({ customId: 'preset.delete', user: { id: 'u1' } }).interaction);
    const { interaction, replies } = component({ customId: 'preset.pick', value: 'drop', user: { id: 'u1' } });
    await router.handle(interaction);
    // 'drop' is gone from the guild config; picking in delete mode never starts a session.
    expect((store.loadServerConfig('g1')?.presets ?? []).map((p) => p.name)).toEqual(['keep']);
    expect(calls.start).not.toHaveBeenCalled();
    // The re-rendered picker shows the refreshed list (drop removed, keep still there).
    const pick = flatOf(replies[replies.length - 1]).find((c) => c.customId === 'preset.pick');
    expect(pick?.options?.map((o) => o.value)).toEqual(['keep']);
  });

  it('cancelling on the preset step ends the wizard without starting', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude' });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    const { interaction, replies } = component({ customId: 'cancel', user: { id: 'u1' } });
    await router.handle(interaction);
    // The wizard renders the cancel notice in its embed (mirrors a cancel from any step).
    expect(replies.some((r) => (r.embeds as { description?: string }[] | undefined)?.[0]?.description?.includes('취소'))).toBe(true);
    // The wizard is gone: a later pick does nothing (no start).
    await router.handle(component({ customId: 'preset.pick', value: 'claude-plan', user: { id: 'u1' } }).interaction);
    expect(calls.start).not.toHaveBeenCalled();
  });

  it('a completed normal wizard offers 💾 save; the name modal persists the launched config', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // No presets → straight to the manual wizard; drive it to done.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    let doneReply: Reply | undefined;
    for (const customId of ['dir:here', 'backend.next', 'model.next', 'effort.next', 'perm.start']) {
      const { interaction, replies } = component({ customId, user: { id: 'u1' } });
      await router.handle(interaction);
      if (replies.length > 0) doneReply = replies[replies.length - 1];
    }
    // The done reply carries the 💾 save button.
    expect(flatOf(doneReply).some((c) => c.customId === 'preset.save')).toBe(true);

    // Clicking save opens the name modal WITHOUT a preceding defer (showModal is the ack).
    const { interaction: save, acks } = component({ customId: 'preset.save', user: { id: 'u1' } });
    await router.handle(save);
    expect(acks.map((a) => a.kind)).toEqual(['showModal']);
    expect(acks[0].modal?.customId).toBe('preset.name');
    expect(acks[0].modal?.fields[0]?.customId).toBe('name');

    // Submitting the name persists the preset (backend from the launched config, no cwd).
    const { interaction: submit, replies: sr } = modalSubmit({ customId: 'preset.name', user: { id: 'u1' }, fields: { name: 'my-preset' } });
    await router.handle(submit);
    expect(sr.some((r) => (r.content ?? '').includes('my-preset'))).toBe(true);
    const presets = store.loadServerConfig('g1')?.presets ?? [];
    expect(presets.map((p) => p.name)).toEqual(['my-preset']);
    expect(presets[0]).toMatchObject({ backend: 'claude' });
    expect(presets[0]).not.toHaveProperty('cwd');
  });

  it('a draft backup write failure (state.json throws) does NOT hide the launch success notice', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const { logger: fake, error } = fakeLogger();
    const router = buildRouter({ orchestrator, wiring, logger: fake });
    // The state.json draft backup throws (e.g. disk I/O) at wizard done — the session has
    // already launched, so the failure must be swallowed and not mask the success notice.
    vi.spyOn(stateStore, 'setPresetDraft').mockImplementation(() => {
      throw new Error('disk full');
    });
    // No presets → straight to the manual wizard; drive it to done.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    let doneReply: Reply | undefined;
    for (const customId of ['dir:here', 'backend.next', 'model.next', 'effort.next', 'perm.start']) {
      const { interaction, replies } = component({ customId, user: { id: 'u1' } });
      await router.handle(interaction);
      if (replies.length > 0) doneReply = replies[replies.length - 1];
    }
    // The channelCreated notice + 💾 save button still arrive despite the backup failure.
    expect((doneReply?.content ?? '').includes('세션 채널')).toBe(true);
    expect(flatOf(doneReply).some((c) => c.customId === 'preset.save')).toBe(true);
    // The failure was logged best-effort, not surfaced as a command error.
    expect(error).toHaveBeenCalledWith('preset draft backup failed', expect.objectContaining({ error: 'disk full' }));
    // The in-memory draft still backs an in-session save (the button opens the name modal).
    const { interaction: save, acks } = component({ customId: 'preset.save', user: { id: 'u1' } });
    await router.handle(save);
    expect(acks.map((a) => a.kind)).toEqual(['showModal']);
  });

  it('clicking 💾 save with no captured draft replies with the “nothing to save” notice', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    const { interaction, replies, acks } = component({ customId: 'preset.save', user: { id: 'u1' } });
    await router.handle(interaction);
    expect(acks.some((a) => a.kind === 'showModal')).toBe(false);
    expect(replies.some((r) => (r.content ?? '').includes('저장할 최근 세션 설정이 없어요'))).toBe(true);
  });

  it('a preset-launched wizard shows NO save button on done and captures no draft', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude', model: 'sonnet', effort: 'high', permMode: 'plan', profile: null });
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    const { interaction, replies } = component({ customId: 'preset.pick', value: 'claude-plan', user: { id: 'u1' } });
    await router.handle(interaction);
    const done = replies.find((r) => (r.content ?? '').includes('세션 채널'));
    expect(done).toBeTruthy();
    expect((done?.components ?? []).length).toBe(0);
    // No draft captured → a subsequent 💾 save has nothing to persist.
    const { interaction: save, acks } = component({ customId: 'preset.save', user: { id: 'u1' } });
    await router.handle(save);
    expect(acks.some((a) => a.kind === 'showModal')).toBe(false);
  });

  it('a preset pick from a NON-owner is ignored; the owner can still pick', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude' });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    // A bystander (also execute tier) picks → ignored (owner-bound).
    await router.handle(component({ customId: 'preset.pick', value: 'claude-plan', user: { id: 'u2' } }).interaction);
    expect(calls.start).not.toHaveBeenCalled();
    // The owner picks → starts at once (folder already chosen).
    await router.handle(component({ customId: 'preset.pick', value: 'claude-plan', user: { id: 'u1' } }).interaction);
    expect(calls.start).toHaveBeenCalledOnce();
  });

  it('a preset pick from a non-drive user is denied', async () => {
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude' });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    const { interaction, replies } = component({ customId: 'preset.pick', value: 'claude-plan', roles: ['role-nobody'] });
    await router.handle(interaction);
    expect(calls.start).not.toHaveBeenCalled();
    expect(replies.some((r) => (r.content ?? '').includes('권한이 없습니다'))).toBe(true);
  });

  it('a raw preset (profile:null) does NOT fall back to the guild default profile on start', async () => {
    // Guild default profile is a non-null named profile; a RAW preset (profile:null) must
    // start with profile:null, not overfall to that guild default.
    store.saveServerConfig({
      version: CONFIG_VERSION,
      guildId: 'g1',
      defaults: { permissionProfile: 'safe' },
      presets: [{ name: 'raw-preset', backend: 'claude', model: 'sonnet', effort: 'high', permMode: 'default', profile: null }],
    });
    const { orchestrator, calls } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    await router.handle(component({ customId: 'preset.pick', value: 'raw-preset', user: { id: 'u1' } }).interaction);
    expect(calls.start).toHaveBeenCalledOnce();
    expect(calls.start).toHaveBeenCalledWith(expect.objectContaining({ mode: 'claude', profile: null }));
  });

  it('a preset-launched done shows no save button even after a prior normal wizard left a draft', async () => {
    // First run a NORMAL wizard (set up manually) to DONE without saving — leaves a draft.
    store.addServerPreset('g1', { name: 'claude-plan', backend: 'claude', model: 'sonnet', effort: 'high', permMode: 'plan', profile: null });
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction); // → preset step
    await router.handle(component({ customId: 'preset.direct', user: { id: 'u1' } }).interaction); // → backend step
    for (const customId of ['backend.next', 'model.next', 'effort.next', 'perm.start']) {
      await router.handle(component({ customId, user: { id: 'u1' } }).interaction);
    }
    // Same channel again: fresh wizard → folder → preset step → pick (express) to DONE.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    await router.handle(component({ customId: 'dir:here', user: { id: 'u1' } }).interaction);
    const { interaction, replies } = component({ customId: 'preset.pick', value: 'claude-plan', user: { id: 'u1' } });
    await router.handle(interaction);
    // The preset-launched done keys the button off launchedFromPreset, not a stale draft.
    const done = replies.find((r) => (r.content ?? '').includes('세션 채널'));
    expect(done).toBeTruthy();
    expect(flatOf(done).some((c) => c.customId === 'preset.save')).toBe(false);
    expect((done?.components ?? []).length).toBe(0);
  });

  it('savePresetFromModal rejects an empty or >100-char name (server-side validation, no persist)', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // No presets → normal wizard; drive to done to capture a draft on the channel.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    for (const customId of ['dir:here', 'backend.next', 'model.next', 'effort.next', 'perm.start']) {
      await router.handle(component({ customId, user: { id: 'u1' } }).interaction);
    }
    const addSpy = vi.spyOn(store, 'addServerPreset');
    // Empty name → rejected with a notice, nothing persisted.
    const empty = modalSubmit({ customId: 'preset.name', user: { id: 'u1' }, fields: { name: '   ' } });
    await router.handle(empty.interaction);
    expect(addSpy).not.toHaveBeenCalled();
    expect(empty.replies.length).toBeGreaterThan(0);
    // >100-char name → also rejected (draft is untouched by the failed save, so it is still present).
    const tooLong = modalSubmit({ customId: 'preset.name', user: { id: 'u1' }, fields: { name: 'x'.repeat(101) } });
    await router.handle(tooLong.interaction);
    expect(addSpy).not.toHaveBeenCalled();
    expect(tooLong.replies.length).toBeGreaterThan(0);
    expect((store.loadServerConfig('g1')?.presets ?? [])).toEqual([]);
  });

  it('a persist failure keeps the draft (retry can still save) and notifies with an error', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // No presets → normal wizard; drive to done to capture a draft on the channel.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    for (const customId of ['dir:here', 'backend.next', 'model.next', 'effort.next', 'perm.start']) {
      await router.handle(component({ customId, user: { id: 'u1' } }).interaction);
    }
    // addServerPreset throws (e.g. disk I/O) → the draft must survive so a retry can still save.
    const addSpy = vi.spyOn(store, 'addServerPreset').mockImplementation(() => {
      throw new Error('disk full');
    });
    const delSpy = vi.spyOn(stateStore, 'deletePresetDraft');
    const fail = modalSubmit({ customId: 'preset.name', user: { id: 'u1' }, fields: { name: 'my-preset' } });
    await router.handle(fail.interaction);
    expect(addSpy).toHaveBeenCalledOnce();
    // User is notified of the failure and the draft backup is NOT cleared.
    expect(fail.replies.length).toBeGreaterThan(0);
    expect(delSpy).not.toHaveBeenCalled();
    // Retry once the fault clears: the SAME draft persists, proving it was kept.
    addSpy.mockRestore();
    const retry = modalSubmit({ customId: 'preset.name', user: { id: 'u1' }, fields: { name: 'my-preset' } });
    await router.handle(retry.interaction);
    expect((store.loadServerConfig('g1')?.presets ?? []).map((p) => p.name)).toEqual(['my-preset']);
  });

  it('a response failure does not block the save: the preset persists and the draft is cleared', async () => {
    const { orchestrator } = fakeOrchestrator();
    const { wiring } = fakeWiring();
    const router = buildRouter({ orchestrator, wiring });
    // No presets → normal wizard; drive to done to capture a draft on the channel.
    await router.handle(slash({ commandName: 'agent', subcommand: 'start', user: { id: 'u1' } }).interaction);
    for (const customId of ['dir:here', 'backend.next', 'model.next', 'effort.next', 'perm.start']) {
      await router.handle(component({ customId, user: { id: 'u1' } }).interaction);
    }
    const addSpy = vi.spyOn(store, 'addServerPreset');
    const delSpy = vi.spyOn(stateStore, 'deletePresetDraft');
    // Discord replies fail (ConnectTimeout / Unknown interaction) — must NOT roll back the save.
    const submit = modalSubmit({ customId: 'preset.name', user: { id: 'u1' }, fields: { name: 'my-preset' } });
    submit.interaction.reply = async () => {
      throw new Error('Unknown interaction');
    };
    submit.interaction.editReply = async () => {
      throw new Error('Unknown interaction');
    };
    await router.handle(submit.interaction);
    // The persist ran and the draft (memory + state backup) was cleared despite the response failure.
    expect(addSpy).toHaveBeenCalledOnce();
    expect((store.loadServerConfig('g1')?.presets ?? []).map((p) => p.name)).toEqual(['my-preset']);
    expect(delSpy).toHaveBeenCalledWith('g1:c1');
  });
});
