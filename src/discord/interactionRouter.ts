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

// The shape of a reply/edit/follow-up payload. `content` is optional so an
// interactive panel (embed + component rows) can be sent without a text body;
// `embeds`/`components` carry the /config panel UI.
export interface AckPayload {
  content?: string;
  ephemeral?: boolean;
  embeds?: EmbedSpec[];
  components?: ComponentRow[];
}

interface Replier {
  reply: (options: AckPayload) => Promise<unknown>;
  // Acknowledge the interaction WITHOUT a visible message yet, buying the full
  // 15-minute follow-up window (Discord's 3s ack rule). `editReply` then fills in
  // the deferred reply; `followUp` posts an additional message (e.g. a second row
  // batch that would overflow the 5-action-row-per-message limit).
  deferReply: (options?: { ephemeral?: boolean }) => Promise<unknown>;
  editReply: (options: AckPayload) => Promise<unknown>;
  followUp: (options: AckPayload) => Promise<unknown>;
  // True once this interaction has been acknowledged (replied or deferred). The
  // adapter reads discord.js's own `replied`/`deferred` flags; a fake test double
  // tracks it so the guaranteed-error-ack path picks reply vs editReply correctly.
  readonly acknowledged: boolean;
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
    // Operator visibility (§7.3): log EVERY received interaction to the terminal so
    // `node dist/cli.js` shows exactly what fired. Redaction is handled by the logger.
    this.logReceipt(interaction);
    if (interaction.kind === 'component') {
      await this.handleComponent(interaction);
      return;
    }
    await this.handleSlash(interaction);
  }

  // One info line per interaction: type + command/customId + guild + user. This is
  // the operator's window into what the gateway delivered (see the bug where a slash
  // command silently timed out — now the terminal shows it fired).
  private logReceipt(i: RouterInteraction): void {
    if (i.kind === 'slash') {
      this.deps.logger.info('interaction received', {
        type: 'slash',
        command: i.subcommand ? `${i.commandName} ${i.subcommand}` : i.commandName,
        guildId: i.guildId,
        userId: i.user.id,
      });
    } else {
      this.deps.logger.info('interaction received', {
        type: 'component',
        customId: i.customId,
        guildId: i.guildId,
        userId: i.user.id,
      });
    }
  }

  // ---- Slash commands -----------------------------------------------------

  private async handleSlash(i: SlashInteraction): Promise<void> {
    const actionKey = i.subcommand ? `${i.commandName}.${i.subcommand}` : i.commandName;

    // Acknowledge IMMEDIATELY, before any slow work (auth, disk reads, panel/wizard
    // build, session start/stop). Deferring buys the 15-minute follow-up window so we
    // never miss Discord's 3-second ack deadline — the root cause of "application did
    // not respond". Every subsequent user-facing message is an editReply/followUp.
    // The defer is ephemeral (only the actor sees the ack + any notices); a command
    // that needs a PUBLIC message (e.g. /mode backend's fresh-context warning) posts
    // it as a non-ephemeral followUp.
    if (!(await this.ackDefer(i, { ephemeral: true }))) return;

    // /config has a bespoke bootstrap gate (Administrator OR admin tier) so it works
    // on first run with an empty allowlist AND later for configured admins — handled
    // outside the tier-per-action table below.
    if (actionKey === 'config') {
      await this.guarded(i, () => this.openConfigPanel(i));
      return;
    }

    const action = ACTION_TIER[actionKey] ?? 'drive';

    if (!this.authorize(i, action)) return;

    await this.guarded(i, async () => {
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
    });
  }

  // Defer the interaction (the first ack) with a best-effort guard. Returns false if
  // the defer itself failed (a stale/expired interaction) so the caller bails out
  // rather than doing work whose result can never be delivered. Logs the failure with
  // its stack so the operator sees it in the terminal.
  private async ackDefer(i: RouterInteraction, options?: { ephemeral?: boolean }): Promise<boolean> {
    try {
      await i.deferReply(options);
      return true;
    } catch (err) {
      this.logError('interaction defer failed', err);
      return false;
    }
  }

  // Run a handler with a GUARANTEED user-visible ack: any thrown error becomes an
  // ephemeral error message (editReply when already deferred/replied, else reply), so
  // Discord never shows "did not respond" — worst case the user sees the error. The
  // error is logged WITH its stack to the operator terminal (redacted by the logger).
  private async guarded(i: RouterInteraction, fn: () => Promise<void>): Promise<void> {
    try {
      await fn();
    } catch (err) {
      this.logError('interaction handler failed', err);
      const payload: AckPayload = { content: t('cmd.error', { error: String(err) }), ephemeral: true };
      await safe(i.acknowledged ? i.editReply(payload) : i.reply(payload));
    }
  }

  // Log an error to the operator terminal WITH its stack trace (the logger redacts
  // secrets). A bare `String(err)` drops the stack, so pass the Error through.
  private logError(message: string, err: unknown): void {
    if (err instanceof Error) {
      this.deps.logger.error(message, { error: err.message, stack: err.stack });
    } else {
      this.deps.logger.error(message, { error: String(err) });
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
    await i.editReply({ content: t('cmd.start.launched') });
  }

  // Open the /config role-tier + defaults panel. Bootstrap gate: allowed if the actor
  // has the Discord Administrator permission OR our admin tier — so it works on first
  // run with an empty allowlist AND later for configured admins (§7.1). Prefills the
  // panel from the guild's current server-layer auth + resolved defaults; a bystander
  // cannot advance it (owner-bound, mirroring the wizard).
  private async openConfigPanel(i: SlashInteraction): Promise<void> {
    if (i.guildId === null) {
      await i.editReply({ content: t('auth.denied', { reason: 'DM' }) });
      return;
    }
    if (!this.authorizeConfig(i)) {
      await i.editReply({ content: t('cmd.config.denied') });
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
    // A single Discord message allows at most 5 action rows; the panel has 7 (3 role
    // tiers + 3 default selects + Save). Deliver the role tiers + Save on the deferred
    // reply (4 rows) and the defaults on a follow-up (3 rows). Both are ephemeral.
    const { embed, roleRows, defaultRows } = panel.render();
    await i.editReply({ content: t('cmd.config.opened'), embeds: [embed], components: roleRows });
    await i.followUp({ components: defaultRows, ephemeral: true });
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
      // Save is a button on the primary (ephemeral) message; a fresh ephemeral reply
      // carries the confirmation summary without disturbing the still-open panel.
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
      await i.editReply({ content: t('cmd.resume.none') });
      return;
    }
    // For Claude, listResumable is currently [] — re-bind/inform gracefully.
    await this.deps.wiring.attach(guildId, i.channelId, binding.mode);
    await i.editReply({ content: t('cmd.resume.rebound') });
  }

  private async close(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    await this.deps.orchestrator.stop(guildId, i.channelId);
    this.deps.wiring.detach(guildId, i.channelId);
    await i.editReply({ content: t('cmd.close.done') });
  }

  private async switchBackend(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const backend = i.getString('backend');
    if (!backend) return;
    // Validate the target backend BEFORE any teardown: an unregistered backend (e.g.
    // Codex before Phase 2 registers it) must NOT stop/detach the running session.
    if (!this.deps.modeRegistry.has(backend)) {
      await i.editReply({ content: t('cmd.mode.unavailable', { backend }) });
      return;
    }
    // Require an existing binding: there is no cwd/owner to carry over otherwise, and
    // falling back to process.cwd() would start a session in the bot's own directory.
    const binding = this.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await i.editReply({ content: t('router.noSession') });
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
    // Confirmation closes the ephemeral deferred reply (only the actor sees it). The
    // fresh-context warning (§9 step 3) is PUBLIC so the whole channel sees the context
    // reset — posted as a non-ephemeral followUp since the deferred reply is ephemeral.
    await i.editReply({ content: t('cmd.mode.switched', { backend }) });
    await safe(i.followUp({ content: t('cmd.mode.freshContext', { backend }), ephemeral: false }));
  }

  private async switchPerm(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const value = i.getString('value');
    if (!value) return;
    const binding = this.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await i.editReply({ content: t('router.noSession') });
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
    await i.editReply({ content: t('cmd.perm.switched', { perm: resolved.profile ?? resolved.permMode }) });
  }

  private async stop(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    await this.deps.orchestrator.stop(guildId, i.channelId);
    this.deps.wiring.detach(guildId, i.channelId);
    await i.editReply({ content: t('cmd.stop.done') });
  }

  private async stopAll(i: SlashInteraction): Promise<void> {
    // Detach every wired channel first so no renderer lingers, then stop all.
    const bindings = this.deps.channelRegistry.list().filter((b) => !b.archived);
    for (const b of bindings) this.deps.wiring.detach(b.guildId, b.channelId);
    await this.deps.orchestrator.stopAll();
    await i.editReply({ content: t('cmd.stopAll.done', { count: bindings.length }) });
  }

  // ---- Component interactions (buttons / selects) -------------------------

  private async handleComponent(i: ComponentInteraction): Promise<void> {
    // /config panel components own their own ack flow (deferUpdate on a pending pick,
    // an ephemeral reply on Save / denial). Fast work only (in-memory panel state plus
    // one small JSON write on Save), so they ack within the window without a leading
    // defer. Same bootstrap gate as opening the panel; owner-bound.
    if (isConfigPanelId(i.customId)) {
      await this.handleConfigComponent(i);
      return;
    }

    // Permission buttons: perm:<reqId>:<action>. These are gated to execute tier
    // (the driver decides). Route to the channel's PermissionButtonsHandler, passing
    // the acting user id so the handler enforces that ONLY the prompt's approver
    // (the session owner) can resolve it — a bystander click is ignored (§7.1/§7.5).
    if (parseCustomId(i.customId)) {
      if (!this.authorize(i, 'drive')) return;
      // Acknowledge FIRST (deferUpdate keeps the existing message), THEN resolve the
      // permission — resolvePermission touches the session and must never delay the
      // ack past Discord's 3s window.
      if (!(await this.ackDeferUpdate(i))) return;
      await this.guarded(i, async () => {
        if (i.guildId) {
          await this.deps.wiring.resolvePermission(i.guildId, i.channelId, i.customId, i.user.id);
        }
      });
      return;
    }

    // Otherwise it is a wizard component (folder/backend/model/perm/confirm/cancel).
    // The wizard flow is a drive action; only the driver who opened it advances it.
    if (!this.authorize(i, 'drive')) return;
    // Acknowledge FIRST: the confirm step calls orchestrator.start (spawns an agent),
    // which can exceed 3s — deferUpdate now, do the work after.
    if (!(await this.ackDeferUpdate(i))) return;
    if (!i.guildId) return;
    await this.guarded(i, async () => {
      const wizard = this.wizards.get(channelKey(i.guildId as string, i.channelId));
      // Enforce wizard ownership: a component from anyone other than the driver who
      // opened the wizard is acknowledged but ignored, so a bystander's stray select
      // cannot corrupt another driver's flow (§7.1).
      if (!wizard || wizard.ownerId !== i.user.id) return;
      const input: WizardInput = { id: i.customId, ...(i.value !== undefined ? { value: i.value } : {}) };
      const step = await wizard.handle(input);
      if (step === 'done' || step === 'cancelled') {
        this.wizards.delete(channelKey(i.guildId as string, i.channelId));
      }
    });
  }

  // deferUpdate the component interaction (the first ack, keeping its message). Returns
  // false when the ack itself failed (stale interaction) so the caller bails out.
  private async ackDeferUpdate(i: ComponentInteraction): Promise<boolean> {
    try {
      await i.deferUpdate();
      return true;
    } catch (err) {
      this.logError('interaction deferUpdate failed', err);
      return false;
    }
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
      // Ephemeral denial. A slash interaction is already deferred (edit its reply); a
      // component interaction is not yet acked (send a fresh ephemeral reply).
      const payload: AckPayload = { content: t('auth.denied', { reason: decision.reason ?? '' }), ephemeral: true };
      void safe(i.acknowledged ? i.editReply(payload) : i.reply(payload));
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
