import type { Logger, ModeSession, PermMode } from '../core/contracts.js';
import { permissionModeLabel, type ModelChoice } from '../core/providerCatalog.js';
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
import type { ComponentRow, EmbedSpec, MessageChannel, ModalSpec } from './ports.js';
import { buildStatusEmbed } from './renderers/statusEmbed.js';
import {
  ensureGuildChannels,
  createSessionChannel,
  type GuildChannelProvisioner,
  type GuildChannels,
} from './guildChannels.js';
import { setLocale, t, type Locale } from './i18n.js';

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
  // Open a modal dialog IN RESPONSE to this component. showModal IS the ack for the
  // interaction, so the caller must NOT deferUpdate/deferReply before calling it (a
  // deferred interaction can no longer show a modal — discord.js throws). Present on
  // button interactions; the client.ts adapter maps ModalSpec onto discord.js.
  showModal: (modal: ModalSpec) => Promise<unknown>;
}

// A submitted modal (discord.js ModalSubmitInteraction). Carries the field values
// keyed by field custom id. It is its OWN interaction (a fresh 3s window): reply /
// deferReply as usual. The client.ts adapter reads the fields off the submission.
export interface ModalSubmitInteraction extends BaseInteraction {
  kind: 'modalSubmit';
  customId: string;
  // Read a submitted text-field value by its custom id (empty string when absent).
  getField: (fieldId: string) => string;
}

export type RouterInteraction = SlashInteraction | ComponentInteraction | ModalSubmitInteraction;

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
  // Models offered per backend, as English {value,label} pairs from the provider
  // catalog (app boot supplies: Claude = dynamic/cached; Codex = documented default).
  modelsFor?: (backend: string) => ModelChoice[];
  // Resolve a guildId to a channel provisioner over the live gateway (A4D-style /init
  // + auto-created session channels). Returns null when the guild is unknown or the
  // client is not connected yet (tests inject a fake). Optional so the pre-gateway
  // graph builds without it; when absent, /init and session-channel creation report a
  // graceful notice instead of throwing.
  resolveGuildProvisioner?: (guildId: string) => Promise<GuildChannelProvisioner | null>;
  // Resolve a channelId to a message sink (to post the status embed + intro into a
  // freshly created session channel). Defaults to the wiring's resolver; app boot
  // binds it to the live gateway. Optional for the same reason as above.
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
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

  // Bind the live-gateway resolvers AFTER construction (app boot). The client depends
  // on this router, so the router cannot capture the client at construction — these
  // setters mirror wiring.setResolveChannel. Used by /init and /agent start's session-
  // channel creation + intro post.
  setResolveGuildProvisioner(fn: (guildId: string) => Promise<GuildChannelProvisioner | null>): void {
    this.deps.resolveGuildProvisioner = fn;
  }
  setResolveChannel(fn: (channelId: string) => Promise<MessageChannel | null>): void {
    this.deps.resolveChannel = fn;
  }

  async handle(interaction: RouterInteraction): Promise<void> {
    // Operator visibility (§7.3): log EVERY received interaction to the terminal so
    // `node dist/cli.js` shows exactly what fired. Redaction is handled by the logger.
    this.logReceipt(interaction);
    if (interaction.kind === 'component') {
      await this.handleComponent(interaction);
      return;
    }
    if (interaction.kind === 'modalSubmit') {
      await this.handleModalSubmit(interaction);
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
        type: i.kind === 'modalSubmit' ? 'modalSubmit' : 'component',
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

    // /init creates the guild channel structure (control channel + sessions category).
    // Same bootstrap gate as /config (Administrator OR admin tier) so a fresh server
    // admin can run it before any role is configured.
    if (actionKey === 'init') {
      await this.guarded(i, () => this.runInit(i));
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

  // The permission-mode option list for a backend as English {value,label} pairs. The
  // backend's declared capabilities.permissionModes stays authoritative for WHICH modes
  // it accepts (Codex excludes dontAsk/auto); the provider catalog supplies the English
  // label for each — so the dropdowns show original English identifiers, not Korean.
  private permModeChoicesFor(backend: string): ModelChoice[] {
    const modes = this.deps.modeRegistry.get(backend).capabilities.permissionModes;
    return modes.map((m) => ({ value: m, label: permissionModeLabel(m) }));
  }

  private async startWizard(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string; // authorize() rejected DMs (no guild)
    const resolved = this.deps.configResolver.resolve(guildId, i.channelId);
    const config = this.deps.configStore.load();
    const backends = this.deps.modeRegistry.list();
    const profiles = Object.keys(config.profiles);
    const backend = resolved.mode;
    const models = this.deps.modelsFor?.(backend) ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    const permModes = this.permModeChoicesFor(backend);

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
    const models = this.deps.modelsFor?.(resolved.mode) ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    const permModes = this.permModeChoicesFor(resolved.mode);

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
        // locale is per-guild (server override) or the global default. Codex home is
        // NOT configured here — it auto-resolves to ~/.codex via the resolver default.
        locale: server?.locale ?? global.locale,
      },
      backends,
      models,
      permModes,
    });
    this.configPanels.set(channelKey(guildId, i.channelId), panel);
    // A single Discord message allows at most 5 action rows. Role tiers + Save (4 rows)
    // ride the deferred reply; the defaults follow-up carries backend/model/permMode/
    // locale selects (4 rows). Both are ephemeral.
    const { embed, roleRows, defaultRows } = panel.render();
    await i.editReply({ content: t('cmd.config.opened'), embeds: [embed], components: roleRows });
    await i.followUp({ components: defaultRows, ephemeral: true });
  }

  // /init: idempotently create the A4D-style channel structure (control channel +
  // sessions category) and persist the ids to servers/<guildId>.json. Re-running
  // reuses existing channels by their stored ids. Same bootstrap gate as /config.
  private async runInit(i: SlashInteraction): Promise<void> {
    if (i.guildId === null) {
      await i.editReply({ content: t('auth.denied', { reason: 'DM' }) });
      return;
    }
    if (!this.authorizeConfig(i)) {
      await i.editReply({ content: t('cmd.config.denied') });
      return;
    }
    const provisioner = this.deps.resolveGuildProvisioner
      ? await this.deps.resolveGuildProvisioner(i.guildId)
      : null;
    if (!provisioner) {
      await i.editReply({ content: t('cmd.init.unavailable') });
      return;
    }
    const channels = await ensureGuildChannels(provisioner, this.deps.configStore);
    await i.editReply({
      content: t('cmd.init.done', { control: `<#${channels.controlChannelId}>` }),
    });
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
    if (result.kind === 'autosaved') {
      // A defaults select persisted one field immediately; confirm it ephemerally
      // (a fresh reply, keeping the panel open). If it was the locale select, drive
      // setLocale so THIS session's subsequent responses use the chosen language.
      this.applyLocaleIfLocaleSelect(i.customId, i.value);
      await safe(i.reply({ content: result.notice, ephemeral: true }));
      return;
    }
    // A pending selection or an ignored input: just acknowledge (keep the panel open).
    await safe(i.deferUpdate());
  }

  // Route a submitted modal. The bot no longer opens any modal (Codex home auto-resolves
  // and the folder is picked in the /agent start wizard), so a modal submit here is a
  // stray/replayed interaction. It must still be acknowledged within Discord's window —
  // a generic ephemeral notice, no persistence — so it never shows "did not respond".
  private async handleModalSubmit(i: ModalSubmitInteraction): Promise<void> {
    await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
  }

  // When a /config auto-save was the LOCALE select, drive setLocale so this running
  // process renders subsequent responses in the chosen language (the per-guild locale
  // is also persisted; the global config.locale still seeds the boot default). A value
  // outside the known set is left to the module default — never throws.
  private applyLocaleIfLocaleSelect(customId: string, value?: string): void {
    if (customId !== 'config.default.locale' || !value) return;
    if (value === 'ko' || value === 'en') setLocale(value as Locale);
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

  // A4D-style session start: CREATE a dedicated session channel from the picked
  // folder, start the session bound to THAT new channel (not the command's channel),
  // wire renderers/permission/sendFile there, and post the status embed + intro. Falls
  // back to the command's channel when the guild has no /init structure and no
  // provisioner is available (so a session can still start), but the channel is created
  // under the sessions category when /init has run. Returns the effective channel id so
  // the wizard/router can link the new channel to the driver.
  private async startSession(params: StartParams): Promise<{ session: ModeSession; channelId: string }> {
    const channelId = await this.resolveSessionChannelId(params);
    const session = await this.startInChannel({ ...params, channelId });
    await this.postSessionIntro(channelId, params, session);
    return { session, channelId };
  }

  // orchestrator.start + wire renderers/permission/sendFile for the given channel. The
  // /mode backend switch reuses this to restart IN PLACE (same channel) — it must not
  // create a new session channel.
  private async startInChannel(params: StartParams): Promise<ModeSession> {
    const session = await this.deps.orchestrator.start(params);
    await this.deps.wiring.attach(params.guildId, params.channelId, params.mode);
    return session;
  }

  // Create the dedicated session channel for this start, or fall back to the command's
  // channel when no provisioner is wired. When /init has run, the new channel is placed
  // under the guild's sessions category; otherwise it is created without a parent (or,
  // if creation is impossible, the command's channel is reused).
  private async resolveSessionChannelId(params: StartParams): Promise<string> {
    const provisioner = this.deps.resolveGuildProvisioner
      ? await this.deps.resolveGuildProvisioner(params.guildId)
      : null;
    if (!provisioner) return params.channelId;
    const channels = this.guildChannels(params.guildId);
    const created = await createSessionChannel(provisioner, params.cwd, channels?.sessionsCategoryId);
    return created.id;
  }

  // The persisted /init channel structure for a guild, or undefined when /init has not
  // run. A corrupt server file is treated as absent (loadServerConfig returns null).
  private guildChannels(guildId: string): GuildChannels | undefined {
    return this.deps.configStore.loadServerConfig(guildId)?.channels;
  }

  // Post the pinned-style status embed + a short intro into the new session channel so
  // the conversation happens there (A4D behavior). Best-effort: a resolve/post failure
  // is logged but never fails the start (the session is already live).
  private async postSessionIntro(channelId: string, params: StartParams, session: ModeSession): Promise<void> {
    const resolve = this.deps.resolveChannel;
    if (!resolve) return;
    try {
      const channel = await resolve(channelId);
      if (!channel) return;
      const usagePanel = this.deps.modeRegistry.has(params.mode)
        ? this.deps.modeRegistry.get(params.mode).capabilities.usagePanel
        : true;
      const embed = buildStatusEmbed({
        mode: params.mode,
        cwd: params.cwd,
        sessionId: session.sessionId,
        permMode: params.permMode ?? 'default',
        usagePanel,
      });
      await channel.send({ content: t('cmd.start.intro'), embeds: [embed] });
    } catch (err) {
      this.logError('failed to post session intro', err);
    }
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
    // A4D behavior: delete the dedicated session channel on close. Guarded — never
    // delete the control channel or a channel that isn't the closed session's, and
    // skip when no provisioner is wired. Best-effort: a delete failure still reports
    // the session closed (the reply may not survive if this channel is the one deleted,
    // which is expected). Reply BEFORE deleting so the ack lands first.
    await i.editReply({ content: t('cmd.close.done') });
    await this.deleteSessionChannel(guildId, i.channelId);
  }

  // Delete the session channel that was closed, unless it is the guild's control
  // channel (never delete /init's control channel). No-op when no provisioner is wired.
  private async deleteSessionChannel(guildId: string, channelId: string): Promise<void> {
    const channels = this.guildChannels(guildId);
    if (channels && channelId === channels.controlChannelId) return;
    const provisioner = this.deps.resolveGuildProvisioner
      ? await this.deps.resolveGuildProvisioner(guildId)
      : null;
    if (!provisioner) return;
    try {
      await provisioner.deleteChannel(channelId);
    } catch (err) {
      this.logError('failed to delete session channel', err);
    }
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
    await this.startInChannel({
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
      // On a successful confirm the session was bound to a freshly created channel;
      // link it back to the driver (A4D-style "session started in <#newChannel>").
      if (step === 'done') {
        const newChannelId = wizard.sessionChannelId();
        if (newChannelId) {
          await safe(i.editReply({ content: t('cmd.start.channelCreated', { channel: `<#${newChannelId}>` }) }));
        }
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
      // A Discord Administrator is granted the admin tier unconditionally (never
      // locked out); the adapter populates hasAdminPermission from member permissions.
      ...(i.hasAdminPermission === true ? { isAdministrator: true } : {}),
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
