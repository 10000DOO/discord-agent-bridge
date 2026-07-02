import type { Logger, ModeSession, PermMode } from '../core/contracts.js';
import type { Authorizer, AuthAction } from '../core/auth.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { ConfigStore } from '../core/config.js';
import type { ConfigResolver } from '../core/configResolver.js';
import type { PermissionResolver } from '../core/permissionResolver.js';
import type { ModeRegistry } from '../core/modeRegistry.js';
import type { SessionOrchestrator, StartParams } from '../core/sessionOrchestrator.js';
import type { SessionWiring } from './wiring.js';
import { ChannelWizard, type WizardInput } from './wizard/channelWizard.js';
import { DirectoryBrowser } from './directoryBrowser.js';
import { parseCustomId } from './renderers/permissionButtons.js';
import { ConfigPanel, isConfigPanelId, type ConfigPanelInput } from './configPanel.js';
import type { ComponentRow, EmbedSpec } from './ports.js';
import { t } from './i18n.js';

// InteractionCreate router (§4, §7.1, §9). Authorizes FIRST (tier per action), then
// dispatches slash commands and component interactions. discord.js is not imported
// as a value: narrow interaction shapes below are satisfied structurally by the real
// discord.js interactions, so unit tests drive fakes. The client.ts handler narrows
// a raw Interaction with the discord.js type guards and calls handle().

// The tier each command requires (§7.1): stop-all is admin; the rest are execute.
const ACTION_TIER: Record<string, AuthAction> = {
  'agent.start': 'drive',
  'agent.resume': 'drive',
  'agent.close': 'drive',
  'mode.backend': 'drive',
  'mode.perm': 'drive',
  stop: 'drive',
  'stop-all': 'admin',
};

// ---- Narrow interaction shapes (real discord.js interactions satisfy these) ----

interface Replier {
  // `content` is optional so an interactive panel (embed + component rows) can be
  // replied without a text body; `embeds`/`components` carry the /config panel UI.
  reply: (options: {
    content?: string;
    ephemeral?: boolean;
    embeds?: EmbedSpec[];
    components?: ComponentRow[];
  }) => Promise<unknown>;
}

// Common actor/context fields present on every interaction we handle.
interface BaseInteraction extends Replier {
  guildId: string | null;
  channelId: string;
  user: { id: string };
  member: { roles: { cache: { map: (fn: (r: { id: string }) => string) => string[] } } } | null;
  // True when the acting member has the Discord Administrator permission. Populated
  // by the client.ts adapter from member.permissions. Used ONLY as the /config
  // bootstrap gate (server admins can open /config even before the role allowlist
  // is set). Absent/false in DMs and for non-admins.
  hasAdminPermission?: boolean;
}

export interface SlashInteraction extends BaseInteraction {
  kind: 'slash';
  commandName: string; // 'agent' | 'mode' | 'stop' | 'stop-all'
  subcommand: string | null; // e.g. 'start' | 'resume' | 'close' | 'backend' | 'perm'
  getString: (name: string) => string | null;
}

export interface ComponentInteraction extends BaseInteraction {
  kind: 'component';
  customId: string;
  // Selected value for a string-select; empty for a button.
  value?: string;
  // Selected values for a multi-select (string- or role-select). For a role-select
  // these are the picked role IDs. Absent for a button.
  values?: string[];
  // Acknowledge a component interaction without a new reply (defer update).
  deferUpdate: () => Promise<unknown>;
}

export type RouterInteraction = SlashInteraction | ComponentInteraction;

export interface InteractionRouterDeps {
  authorizer: Authorizer;
  orchestrator: SessionOrchestrator;
  channelRegistry: ChannelRegistry;
  configStore: ConfigStore;
  configResolver: ConfigResolver;
  permissionResolver: PermissionResolver;
  modeRegistry: ModeRegistry;
  wiring: SessionWiring;
  logger: Logger;
  // Allowed roots for the wizard's folder browser (config-driven; app boot supplies).
  browseRoots?: string[];
  // Models offered in the wizard's model step per backend (app boot supplies).
  modelsFor?: (backend: string) => string[];
}

function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

export class InteractionRouter {
  private readonly deps: InteractionRouterDeps;
  // Active wizards keyed by guildId:channelId, so follow-up component interactions
  // (folder/backend/model/perm selects, confirm/cancel) route back to the same flow.
  private readonly wizards = new Map<string, ChannelWizard>();
  // Active /config panels keyed by guildId:channelId, so follow-up role/string
  // selects + Save route back to the panel that holds the pending selections.
  private readonly configPanels = new Map<string, ConfigPanel>();

  constructor(deps: InteractionRouterDeps) {
    this.deps = deps;
  }

  async handle(interaction: RouterInteraction): Promise<void> {
    if (interaction.kind === 'component') {
      await this.handleComponent(interaction);
      return;
    }
    await this.handleSlash(interaction);
  }

  // ---- Slash commands -----------------------------------------------------

  private async handleSlash(i: SlashInteraction): Promise<void> {
    const actionKey = i.subcommand ? `${i.commandName}.${i.subcommand}` : i.commandName;

    // /config has a bespoke bootstrap gate (Administrator OR admin tier) so it works
    // on first run with an empty allowlist AND later for configured admins — handled
    // outside the tier-per-action table below.
    if (actionKey === 'config') {
      await this.openConfigPanel(i);
      return;
    }

    const action = ACTION_TIER[actionKey] ?? 'drive';

    if (!this.authorize(i, action)) return;

    try {
      switch (actionKey) {
        case 'agent.start':
          await this.startWizard(i);
          break;
        case 'agent.resume':
          await this.resume(i);
          break;
        case 'agent.close':
          await this.close(i);
          break;
        case 'mode.backend':
          await this.switchBackend(i);
          break;
        case 'mode.perm':
          await this.switchPerm(i);
          break;
        case 'stop':
          await this.stop(i);
          break;
        case 'stop-all':
          await this.stopAll(i);
          break;
        default:
          break;
      }
    } catch (err) {
      this.deps.logger.error('slash command failed', { actionKey, err: String(err) });
      await safe(i.reply({ content: t('cmd.error', { error: String(err) }), ephemeral: true }));
    }
  }

  private async startWizard(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string; // authorize() rejected DMs (no guild)
    const resolved = this.deps.configResolver.resolve(guildId, i.channelId);
    const config = this.deps.configStore.load();
    const backends = this.deps.modeRegistry.list();
    const profiles = Object.keys(config.profiles);
    const backend = resolved.mode;
    const models = this.deps.modelsFor?.(backend) ?? [resolved.claudeModel];
    const permModes = this.deps.modeRegistry.get(backend).capabilities.permissionModes;

    const browser = new DirectoryBrowser({
      ...(this.deps.browseRoots && this.deps.browseRoots.length > 0
        ? { allowedRoots: this.deps.browseRoots }
        : {}),
    });

    const wizard = new ChannelWizard({
      guildId,
      channelId: i.channelId,
      ownerId: i.user.id,
      start: (params) => this.startSession(params),
      defaults: {
        backend,
        model: resolved.claudeModel,
        permMode: resolved.permissionMode,
        profile: resolved.permissionProfile,
      },
      backends,
      models,
      profiles,
      permModes,
      browser,
    });
    this.wizards.set(channelKey(guildId, i.channelId), wizard);
    await safe(i.reply({ content: t('cmd.start.launched'), ephemeral: true }));
  }

  // Open the /config role-tier + defaults panel. Bootstrap gate: allowed if the actor
  // has the Discord Administrator permission OR our admin tier — so it works on first
  // run with an empty allowlist AND later for configured admins (§7.1). Prefills the
  // panel from the guild's current server-layer auth + resolved defaults; a bystander
  // cannot advance it (owner-bound, mirroring the wizard).
  private async openConfigPanel(i: SlashInteraction): Promise<void> {
    if (i.guildId === null) {
      await safe(i.reply({ content: t('auth.denied', { reason: 'DM' }), ephemeral: true }));
      return;
    }
    if (!this.authorizeConfig(i)) {
      await safe(i.reply({ content: t('cmd.config.denied'), ephemeral: true }));
      return;
    }
    const guildId = i.guildId;
    const global = this.deps.configStore.load();
    const server = this.deps.configStore.loadServerConfig(guildId);
    const resolved = this.deps.configResolver.resolve(guildId, i.channelId);
    const backends = this.deps.modeRegistry.list();
    const models = this.deps.modelsFor?.(resolved.mode) ?? [resolved.claudeModel];
    const permModes = this.deps.modeRegistry.get(resolved.mode).capabilities.permissionModes;

    // Current effective role tiers = server override when present, else global.
    const panel = new ConfigPanel({
      guildId,
      ownerId: i.user.id,
      configStore: this.deps.configStore,
      defaults: {
        adminRoleIds: server?.auth?.adminRoleIds ?? global.auth.adminRoleIds,
        executeRoleIds: server?.auth?.executeRoleIds ?? global.auth.executeRoleIds,
        readOnlyRoleIds: server?.auth?.readOnlyRoleIds ?? global.auth.readOnlyRoleIds,
        backend: resolved.mode,
        model: resolved.claudeModel,
        permMode: resolved.permissionMode,
      },
      backends,
      models,
      permModes,
    });
    this.configPanels.set(channelKey(guildId, i.channelId), panel);
    const { embed, rows } = panel.render();
    await safe(i.reply({ content: t('cmd.config.opened'), embeds: [embed], components: rows, ephemeral: true }));
  }

  // Route a /config panel component (role/string select or Save) to its panel. Gated
  // by the same bootstrap rule as opening it and owner-bound: a bystander's stray
  // select is acknowledged but ignored, so it cannot corrupt an admin's pending edit.
  private async handleConfigComponent(i: ComponentInteraction): Promise<void> {
    if (!i.guildId) {
      await safe(i.deferUpdate());
      return;
    }
    if (!this.authorizeConfig(i)) {
      await safe(i.reply({ content: t('cmd.config.denied'), ephemeral: true }));
      return;
    }
    const panel = this.configPanels.get(channelKey(i.guildId, i.channelId));
    if (!panel || panel.ownerId !== i.user.id) {
      await safe(i.deferUpdate());
      return;
    }
    const input: ConfigPanelInput = {
      id: i.customId,
      ...(i.value !== undefined ? { value: i.value } : {}),
      ...(i.values !== undefined ? { values: i.values } : {}),
    };
    const result = panel.handle(input);
    if (result.kind === 'saved') {
      this.configPanels.delete(channelKey(i.guildId, i.channelId));
      await safe(i.reply({ content: result.summary, ephemeral: true }));
      return;
    }
    // A pending selection or an ignored input: just acknowledge (keep the panel open).
    await safe(i.deferUpdate());
  }

  // The /config bootstrap gate: allow if the actor has the Discord Administrator
  // permission (works on first run with an empty allowlist) OR clears the admin tier
  // (works once the allowlist is configured). Never uses the generic tier-denial
  // reply — the caller sends the /config-specific notice.
  private authorizeConfig(i: RouterInteraction): boolean {
    if (i.hasAdminPermission === true) return true;
    const roleIds = i.member ? i.member.roles.cache.map((r) => r.id) : [];
    return this.deps.authorizer.authorize({
      userId: i.user.id,
      roleIds,
      action: 'admin',
      context: { ...(i.guildId ? { guildId: i.guildId } : {}), channelId: i.channelId },
    }).allowed;
  }

  // orchestrator.start + wire renderers/permission/sendFile for the new session.
  private async startSession(params: StartParams): Promise<ModeSession> {
    const session = await this.deps.orchestrator.start(params);
    await this.deps.wiring.attach(params.guildId, params.channelId, params.mode);
    return session;
  }

  private async resume(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const binding = this.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding || binding.archived) {
      await safe(i.reply({ content: t('cmd.resume.none'), ephemeral: true }));
      return;
    }
    // For Claude, listResumable is currently [] — re-bind/inform gracefully.
    await this.deps.wiring.attach(guildId, i.channelId, binding.mode);
    await safe(i.reply({ content: t('cmd.resume.rebound'), ephemeral: true }));
  }

  private async close(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    await this.deps.orchestrator.stop(guildId, i.channelId);
    this.deps.wiring.detach(guildId, i.channelId);
    await safe(i.reply({ content: t('cmd.close.done'), ephemeral: true }));
  }

  private async switchBackend(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const backend = i.getString('backend');
    if (!backend) return;
    // Validate the target backend BEFORE any teardown: an unregistered backend (e.g.
    // Codex before Phase 2 registers it) must NOT stop/detach the running session.
    if (!this.deps.modeRegistry.has(backend)) {
      await safe(i.reply({ content: t('cmd.mode.unavailable', { backend }), ephemeral: true }));
      return;
    }
    // Require an existing binding: there is no cwd/owner to carry over otherwise, and
    // falling back to process.cwd() would start a session in the bot's own directory.
    const binding = this.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await safe(i.reply({ content: t('router.noSession'), ephemeral: true }));
      return;
    }
    // Switching the backend starts a fresh context (§9 step 3): stop the current
    // session, then start a new one on the same cwd/owner/permMode and re-wire.
    const { cwd, ownerId, permMode, profile } = binding;

    await this.deps.orchestrator.stop(guildId, i.channelId);
    this.deps.wiring.detach(guildId, i.channelId);
    await this.startSession({
      guildId,
      channelId: i.channelId,
      mode: backend,
      cwd,
      ownerId,
      permMode,
      profile,
    });
    // Fresh-context warning (§9 step 3) + confirmation.
    await safe(
      i.reply({
        content: `${t('cmd.mode.freshContext', { backend })}\n${t('cmd.mode.switched', { backend })}`,
        ephemeral: false,
      }),
    );
  }

  private async switchPerm(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const value = i.getString('value');
    if (!value) return;
    const binding = this.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await safe(i.reply({ content: t('router.noSession'), ephemeral: true }));
      return;
    }
    // A value that names a known profile switches the profile; otherwise it is a raw
    // permission mode. Either way the session is kept (applies on next turn/spawn).
    const config = this.deps.configStore.load();
    const isProfile = Object.prototype.hasOwnProperty.call(config.profiles, value);
    const override = isProfile
      ? { profile: value }
      : { permMode: value as PermMode };
    const resolved = this.deps.permissionResolver.resolve(guildId, i.channelId, override);
    this.deps.channelRegistry.set({
      guildId,
      channelId: i.channelId,
      mode: binding.mode,
      sessionId: binding.sessionId,
      cwd: binding.cwd,
      ownerId: binding.ownerId,
      permMode: resolved.permMode,
      profile: resolved.profile,
      ...(binding.projectAuth ? { projectAuth: binding.projectAuth } : {}),
    });
    await safe(
      i.reply({ content: t('cmd.perm.switched', { perm: resolved.profile ?? resolved.permMode }), ephemeral: true }),
    );
  }

  private async stop(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    await this.deps.orchestrator.stop(guildId, i.channelId);
    this.deps.wiring.detach(guildId, i.channelId);
    await safe(i.reply({ content: t('cmd.stop.done'), ephemeral: true }));
  }

  private async stopAll(i: SlashInteraction): Promise<void> {
    // Detach every wired channel first so no renderer lingers, then stop all.
    const bindings = this.deps.channelRegistry.list().filter((b) => !b.archived);
    for (const b of bindings) this.deps.wiring.detach(b.guildId, b.channelId);
    await this.deps.orchestrator.stopAll();
    await safe(i.reply({ content: t('cmd.stopAll.done', { count: bindings.length }), ephemeral: true }));
  }

  // ---- Component interactions (buttons / selects) -------------------------

  private async handleComponent(i: ComponentInteraction): Promise<void> {
    // Permission buttons: perm:<reqId>:<action>. These are gated to execute tier
    // (the driver decides). Route to the channel's PermissionButtonsHandler, passing
    // the acting user id so the handler enforces that ONLY the prompt's approver
    // (the session owner) can resolve it — a bystander click is ignored (§7.1/§7.5).
    if (parseCustomId(i.customId)) {
      if (!this.authorize(i, 'drive')) return;
      if (i.guildId) {
        await this.deps.wiring.resolvePermission(i.guildId, i.channelId, i.customId, i.user.id);
      }
      await safe(i.deferUpdate());
      return;
    }

    // /config panel components (role/string selects + Save). Same bootstrap gate as
    // opening the panel (Administrator OR admin tier) and owner-bound like the wizard.
    if (isConfigPanelId(i.customId)) {
      await this.handleConfigComponent(i);
      return;
    }

    // Otherwise it is a wizard component (folder/backend/model/perm/confirm/cancel).
    // The wizard flow is a drive action; only the driver who opened it advances it.
    if (!this.authorize(i, 'drive')) return;
    if (!i.guildId) {
      await safe(i.deferUpdate());
      return;
    }
    const wizard = this.wizards.get(channelKey(i.guildId, i.channelId));
    // Enforce wizard ownership: a component from anyone other than the driver who
    // opened the wizard is acknowledged but ignored, so a bystander's stray select
    // cannot corrupt another driver's flow (§7.1).
    if (!wizard || wizard.ownerId !== i.user.id) {
      await safe(i.deferUpdate());
      return;
    }
    const input: WizardInput = { id: i.customId, ...(i.value !== undefined ? { value: i.value } : {}) };
    const step = await wizard.handle(input);
    if (step === 'done' || step === 'cancelled') {
      this.wizards.delete(channelKey(i.guildId, i.channelId));
    }
    await safe(i.deferUpdate());
  }

  // ---- Auth ---------------------------------------------------------------

  // Authorize the interaction for an action; on denial send an ephemeral notice and
  // return false. DMs (no guild) are rejected by the Authorizer's dmPolicy.
  private authorize(i: RouterInteraction, action: AuthAction): boolean {
    const roleIds = i.member ? i.member.roles.cache.map((r) => r.id) : [];
    const decision = this.deps.authorizer.authorize({
      userId: i.user.id,
      roleIds,
      action,
      context: { ...(i.guildId ? { guildId: i.guildId } : {}), channelId: i.channelId },
    });
    if (!decision.allowed) {
      // A slash interaction replies; a component interaction also replies ephemerally.
      void safe(i.reply({ content: t('auth.denied', { reason: decision.reason ?? '' }), ephemeral: true }));
      return false;
    }
    return true;
  }
}

async function safe(p: Promise<unknown>): Promise<void> {
  try {
    await p;
  } catch {
    // best-effort
  }
}
