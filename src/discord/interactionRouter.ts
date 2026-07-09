import * as fs from 'node:fs';
import * as path from 'node:path';
import type { Logger, ModeSession, PermMode, ResumableSession } from '../core/contracts.js';
import {
  defaultEffortFor,
  effortChoicesFor,
  permissionChoicesFor,
  permissionModeLabel,
  type ModelChoice,
} from '../core/providerCatalog.js';
import type { Authorizer, AuthAction } from '../core/auth.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { ConfigStore } from '../core/config.js';
import type { ConfigResolver } from '../core/configResolver.js';
import type { PermissionResolver } from '../core/permissionResolver.js';
import type { ModeRegistry } from '../core/modeRegistry.js';
import type { SessionOrchestrator, StartParams } from '../core/sessionOrchestrator.js';
import type { UsageResult, UsageService } from '../core/usageService.js';
import type { SessionWiring } from './wiring.js';
import { ChannelWizard, type WizardInput } from './wizard/channelWizard.js';
import { ResumeWizard } from './wizard/resumeWizard.js';
import { DirectoryBrowser } from './directoryBrowser.js';
import { parseCustomId } from './renderers/permissionButtons.js';
import { parseInterruptId } from './renderers/interruptButton.js';
import { parseUpdateId, buildUpdateDecidedRow } from './renderers/updateButton.js';
import type { AutoUpdater, DecisionCtx } from '../update/autoUpdater.js';
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
  'agent.stats': 'drive',
  'mode.backend': 'drive',
  'mode.perm': 'drive',
  model: 'drive',
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
  // Claude usage/limits service (§7.4). Read by /agent stats for the usage summary
  // (Claude-global; unavailable line when OAuth is not logged in).
  usageService: UsageService;
  logger: Logger;
  // Allowed roots for the wizard's folder browser (config-driven; app boot supplies).
  browseRoots?: string[];
  // Models offered per backend, as English {value,label} pairs from the provider
  // catalog. Async so every /config or /agent start open re-probes the SDK's live
  // model list (Codex still resolves synchronously from its documented default).
  modelsFor?: (backend: string) => Promise<ModelChoice[]>;
  // Names the 'custom' backend's actual configured provider (e.g. "Custom
  // (kimi-k2.7-code)"), mirroring /mode backend's choice label (client.ts
  // buildSlashCommands) — see modes/custom/shellEnv.ts customBackendLabel().
  // Optional so tests/deploys without the custom backend need not wire it; the
  // wizard then falls back to the plain i18n 'backend.custom' label.
  customBackendLabel?: () => string;
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
  // The auto-update orchestrator (§7). Optional so the pre-gateway graph and most tests
  // build without it; app boot injects it via setAutoUpdater once the client exists.
  // Update-prompt button clicks (approve/dismiss) route here after the admin gate.
  autoUpdater?: AutoUpdater;
}

function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

export class InteractionRouter {
  private readonly deps: InteractionRouterDeps;
  // Active wizards keyed by guildId:channelId, so follow-up component interactions
  // (folder/backend/model/perm selects, confirm/cancel) route back to the same flow.
  private readonly wizards = new Map<string, ChannelWizard>();
  // Active resume flows keyed by guildId:channelId (started from the folder step's
  // "Resume Session" button), so the backend/session selects route back to the flow.
  private readonly resumeFlows = new Map<string, ResumeWizard>();
  // Active /config panels keyed by guildId:channelId, so follow-up role/string
  // selects + Save route back to the panel that holds the pending selections.
  private readonly configPanels = new Map<string, ConfigPanel>();
  // Short-lived cache for /model's autocomplete ONLY (see getModelAutocomplete).
  // deps.modelsFor stays uncached for the wizard/config panel, which need the
  // freshest list on every (rare) open.
  private modelAutocompleteCache: { choices: ModelChoice[]; fetchedAt: number } | null = null;
  private static readonly MODEL_AUTOCOMPLETE_CACHE_MS = 60_000;

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
  // Inject the auto-updater AFTER construction (app boot): the client depends on this
  // router, and the updater depends on the client (guild enumeration for postPrompt), so
  // it cannot be a constructor dep — same late-binding pattern as the resolvers above.
  setAutoUpdater(autoUpdater: AutoUpdater): void {
    this.deps.autoUpdater = autoUpdater;
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
        case 'agent.stats':
          await this.stats(i);
          break;
        case 'mode.backend':
          await this.switchBackend(i);
          break;
        case 'mode.perm':
          await this.switchPerm(i);
          break;
        case 'model':
          await this.switchModel(i);
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

    // Model list per backend — materialized ONCE at wizard start so the sync render
    // reads by backend key. The Claude probe is awaited here (fresh SDK list every
    // open); Codex resolves from its static list. Fallback covers a boot without the
    // dep wired.
    const modelsByBackend: Record<string, ModelChoice[]> = {};
    for (const b of backends) {
      modelsByBackend[b] =
        (await this.deps.modelsFor?.(b)) ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    }
    const modelsFor = (b: string): ModelChoice[] =>
      modelsByBackend[b] ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    // Permission options per backend: Claude PermMode list vs Codex sandbox terms.
    const permsFor = (b: string): ModelChoice[] => permissionChoicesFor(b);
    // Reasoning-effort options per backend, narrowed for Claude to the chosen model's
    // SDK-reported supportedEffortLevels when present.
    const effortsFor = (b: string, model: string): ModelChoice[] => {
      const supported = modelsFor(b).find((m) => m.value === model)?.supportedEffortLevels;
      return effortChoicesFor(b, supported);
    };
    // The wizard's pre-selected reasoning effort per backend. Prefers the guild's
    // server-saved default (from /config) when present; falls back to the provider
    // catalog's per-backend default (Claude 'high', Codex 'medium').
    const defaultEffortForBackend = (b: string): string => {
      const saved = b === 'codex' ? resolved.codexEffort : resolved.claudeEffort;
      return saved ?? defaultEffortFor(b);
    };

    // Unbounded folder browsing by default (browse anywhere up to '/'), unless the
    // operator configured explicit browse roots — so the admin can pick a cwd on any
    // volume (Fix 1). Session file confinement is a separate mechanism and unaffected.
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
        // Backend-aware initial model: applyBackend only resets on a backend CHANGE,
        // so a codex default backend must not leak the Claude default into `codex -m`.
        // getCodexModels offers config.defaults.codexModel first, so [0] is the
        // configured Codex default when one is set.
        model: backend === 'codex' ? (modelsFor('codex')[0]?.value ?? resolved.claudeModel) : resolved.claudeModel,
        permMode: resolved.permissionMode,
        profile: resolved.permissionProfile,
      },
      backends,
      // Computed fresh on every wizard open (same dotfile scan /mode backend's choice
      // uses at command-registration time, but here it is live — no bot restart needed
      // to see a dotfile edit). Absent when the custom backend is not registered.
      ...(backends.includes('custom') && this.deps.customBackendLabel
        ? { customBackendLabel: this.deps.customBackendLabel() }
        : {}),
      modelsFor,
      profiles,
      permsFor,
      effortsFor,
      defaultEffortFor: defaultEffortForBackend,
      browser,
    });
    this.wizards.set(channelKey(guildId, i.channelId), wizard);
    // Render the FIRST step (the folder picker) and attach it to the deferred reply.
    // Sending only cmd.start.launched left the user with a text line and nothing to
    // click — the wizard's embed + component rows (folder select + ⬆/✅ buttons) must
    // ride the editReply so the picker actually appears (mirrors openConfigPanel).
    const { embed, rows } = wizard.render();
    await i.editReply({ content: t('cmd.start.launched'), embeds: [embed], components: rows });
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
    const models = (await this.deps.modelsFor?.(resolved.mode)) ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    const permModes = this.permModeChoicesFor(resolved.mode);
    // Reasoning-effort options + prefilled default for the CURRENT backend. Claude's
    // list is narrowed by the selected model's supportedEffortLevels when the SDK
    // reports them; Codex ignores the narrowing hint.
    const supportedClaudeLevels =
      resolved.mode === 'codex'
        ? undefined
        : models.find((m) => m.value === resolved.claudeModel)?.supportedEffortLevels;
    const efforts = effortChoicesFor(resolved.mode, supportedClaudeLevels);
    const resolvedEffort =
      resolved.mode === 'codex' ? resolved.codexEffort : resolved.claudeEffort;
    const currentEffort = resolvedEffort ?? defaultEffortFor(resolved.mode);

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
        effort: currentEffort,
        // The /config default-permission select is Claude's PermMode vocabulary; take it
        // from the config layer (server override else global), NOT the resolved value —
        // a channel binding may carry a Codex sandbox mode, which does not belong here.
        permMode: server?.defaults?.permissionMode ?? global.defaults.permissionMode,
        // locale is per-guild (server override) or the global default. Codex home is
        // NOT configured here — it auto-resolves to ~/.codex via the resolver default.
        locale: server?.locale ?? global.locale,
      },
      backends,
      models,
      efforts,
      permModes,
    });
    this.configPanels.set(channelKey(guildId, i.channelId), panel);
    // A single Discord message allows at most 5 action rows. Role tiers + Save (4 rows)
    // ride the deferred reply; the defaults follow-up carries backend/model/effort/
    // permMode/locale selects (5 rows — exactly at the limit). Both are ephemeral.
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
    if (result.kind === 'notifPanel') {
      // The 🔔 button opens the notifications sub-panel as a fresh ephemeral message
      // (toggle + channel picker), keeping the primary panel open.
      await safe(i.reply({ embeds: [result.embed], components: result.rows, ephemeral: true }));
      return;
    }
    if (result.kind === 'notifUpdated') {
      // A toggle/channel change persisted and re-rendered the sub-panel in place: ack
      // with a deferUpdate, then edit the sub-panel's own message with the new state.
      await safe(i.deferUpdate());
      await safe(i.editReply({ embeds: [result.embed], components: result.rows }));
      return;
    }
    // A pending selection or an ignored input: just acknowledge (keep the panel open).
    await safe(i.deferUpdate());
  }

  // Route a submitted modal. The only modal the bot opens is the folder-step 📁 Create
  // dialog (dir:create); its submit creates the subfolder and re-renders the browser.
  // Any other modal id is a stray/replayed interaction — acknowledged with a generic
  // ephemeral notice (no persistence) so it never shows "did not respond".
  private async handleModalSubmit(i: ModalSubmitInteraction): Promise<void> {
    if (i.customId === 'dir:create') {
      await this.guarded(i, () => this.handleCreateFolderModal(i));
      return;
    }
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

  // /agent stats: an EPHEMERAL summary (only the requester sees it) of this guild's
  // live sessions, session bindings, and Claude usage. Usage is Claude-GLOBAL (not
  // per-guild), so it is labelled as such; when Claude OAuth is not logged in, a line
  // says the panel only shows after login. Read-only — builds one embed, no side effects.
  private async stats(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string; // authorize() rejected DMs (no guild)
    const fields: { name: string; value: string; inline?: boolean }[] = [];

    // Active sessions (this guild): count + up to 10 channel lines.
    const active = this.deps.orchestrator.listActive(guildId);
    const lines = active.slice(0, 10).map((a) => {
      const base = `<#${a.channelId}> · ${a.mode} · \`${path.basename(a.cwd)}\` · queue ${a.queueDepth}`;
      return a.running ? `${base} · running` : base;
    });
    if (active.length > 10) lines.push(t('stats.more', { n: active.length - 10 }));
    fields.push({
      name: t('stats.active', { n: active.length }),
      value: lines.length > 0 ? lines.join('\n') : t('stats.none'),
    });

    // Session bindings (this guild): active vs archived.
    const bindings = this.deps.channelRegistry.list().filter((b) => b.guildId === guildId);
    const archived = bindings.filter((b) => b.archived).length;
    fields.push({
      name: t('stats.bindings'),
      value: t('stats.bindings.value', { active: bindings.length - archived, archived }),
    });

    // Claude usage (global — labelled). Only shown when Claude OAuth is logged in.
    fields.push({ name: t('stats.usage'), value: await this.usageStatsLine() });

    await i.editReply({ embeds: [{ title: t('stats.title'), fields }] });
  }

  // The Claude usage line for /agent stats: 5-hour + weekly utilization (with reset
  // times when present) when Claude OAuth is available, else a notice that usage only
  // shows after Claude login. Best-effort: a usage-fetch failure degrades to the notice.
  private async usageStatsLine(): Promise<string> {
    if (!this.deps.usageService.isAvailable()) return t('stats.usage.unavailable');
    let usage: UsageResult;
    try {
      usage = await this.deps.usageService.getUsage();
    } catch {
      return t('stats.usage.unavailable');
    }
    if (!('fetchedAt' in usage)) return t('stats.usage.unavailable');
    const parts: string[] = [];
    if (usage.fiveHour) parts.push(this.usageSegment(t('usage.fiveHour'), usage.fiveHour));
    if (usage.sevenDay) parts.push(this.usageSegment(t('usage.weekly'), usage.sevenDay));
    return parts.length > 0 ? parts.join(' · ') : t('stats.usage.unavailable');
  }

  // One "<label> <util>% (초기화 <reset>)" segment for the usage stats line.
  private usageSegment(label: string, limit: { utilization: number; resetsAt?: string }): string {
    const base = `${label} ${Math.round(limit.utilization)}%`;
    return limit.resetsAt ? `${base} (${t('usage.resets', { reset: limit.resetsAt })})` : base;
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
    const { cwd, ownerId, permMode, profile, model, mode: prevMode } = binding;

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
      // Carry the model only when restarting on the SAME backend; model ids are
      // backend-specific, so a cross-backend switch discards it (config default).
      ...(backend === prevMode && model !== undefined ? { model } : {}),
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
      // set() REPLACES the binding — carry the wizard-chosen model or it is dropped.
      ...(binding.model !== undefined ? { model: binding.model } : {}),
      ...(binding.projectAuth ? { projectAuth: binding.projectAuth } : {}),
    });
    await i.editReply({ content: t('cmd.perm.switched', { perm: resolved.profile ?? resolved.permMode }) });
  }

  // /model <value>: change the model on the live session (no restart, context
  // kept). The orchestrator applies it and persists it; here we map the status to a notice.
  private async switchModel(i: SlashInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const value = i.getString('value');
    if (!value) return;
    const outcome = await this.deps.orchestrator.setModel(guildId, i.channelId, value);
    const key =
      outcome === 'ok'
        ? 'cmd.model.switched'
        : outcome === 'unsupported'
          ? 'cmd.model.unsupported'
          : outcome === 'no-session'
            ? 'router.noSession'
            : 'cmd.model.failed';
    await i.editReply({ content: t(key, { model: value }) });
  }

  // /model's `value` option autocomplete: live suggestions from the Claude model
  // catalog (providerCatalog.getClaudeModels — never a static id list), filtered by
  // the user's partial input against either the model id or its display label.
  // Discord caps autocomplete results at 25; getClaudeModels never throws (falls
  // back to the alias list on any failure), so this never rejects either.
  async getModelAutocomplete(query: string): Promise<{ name: string; value: string }[]> {
    const models = await this.claudeModelsForAutocomplete();
    const q = query.trim().toLowerCase();
    const matches =
      q.length === 0
        ? models
        : models.filter((m) => m.value.toLowerCase().includes(q) || m.label.toLowerCase().includes(q));
    return matches.slice(0, 25).map((m) => ({ name: m.label, value: m.value }));
  }

  // The Claude model list, cached for MODEL_AUTOCOMPLETE_CACHE_MS. Discord's autocomplete
  // interaction expires ~3s after it fires; getClaudeModels() spawns the native SDK CLI
  // fresh on every call (no cross-invocation cache, by design — the wizard/config panel
  // want the newest list on every rare open), which routinely exceeds that window,
  // especially right after boot while resume-on-boot is spawning several sessions at
  // once. A minute-stale model list is an acceptable tradeoff here: the account's model
  // catalog does not change second to second, and a burst of keystrokes from one typed
  // command should not each pay a fresh subprocess spawn — only the first keystroke
  // after the cache goes stale does.
  private async claudeModelsForAutocomplete(): Promise<ModelChoice[]> {
    const now = Date.now();
    if (
      this.modelAutocompleteCache &&
      now - this.modelAutocompleteCache.fetchedAt < InteractionRouter.MODEL_AUTOCOMPLETE_CACHE_MS
    ) {
      return this.modelAutocompleteCache.choices;
    }
    const choices = (await this.deps.modelsFor?.('claude')) ?? [];
    this.modelAutocompleteCache = { choices, fetchedAt: now };
    return choices;
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

    // Interrupt "stop" button on a streaming embed: interrupt:<guildId>:<channelId>.
    // Cancels the CURRENT turn only — the session/binding/context are kept, so the same
    // channel continues on the next message (terminal-`claude` ESC; NOT /stop). Same tier
    // as /stop (drive / session driver). Ack FIRST (deferUpdate keeps the message; a
    // showModal is not involved), THEN interrupt via the orchestrator's single shared
    // path. CRITICAL: never wiring.detach() here — the renderer subscription must stay so
    // the interrupted stream finalizes and the next turn renders. Feedback is an ephemeral
    // followUp (does not clobber the streaming embed message).
    const interruptTarget = parseInterruptId(i.customId);
    if (interruptTarget) {
      if (!this.authorize(i, 'drive')) return;
      if (!(await this.ackDeferUpdate(i))) return;
      await this.guarded(i, async () => {
        const ok = await this.deps.orchestrator.interrupt(interruptTarget.guildId, interruptTarget.channelId);
        await safe(i.followUp({ content: ok ? t('cmd.interrupt.done') : t('cmd.interrupt.none'), ephemeral: true }));
      });
      return;
    }

    // Auto-update prompt buttons: dab-update:<approve|dismiss>:<version>. Admin-gated —
    // the SAME gate as opening /config (Discord Administrator OR the admin tier); a
    // non-admin click gets an ephemeral denial and is ignored (mirrors permission-button
    // approver gating). Ack FIRST (deferUpdate keeps the prompt message), THEN drive the
    // AutoUpdater: approve installs + restarts the process (no drain), dismiss silences the
    // version. The DecisionCtx keeps this layer's discord.js out of update/: ack posts an
    // ephemeral followUp, disableButtons collapses the clicked prompt via editReply.
    const updateTarget = parseUpdateId(i.customId);
    if (updateTarget) {
      if (!this.authorizeConfig(i)) {
        await safe(i.reply({ content: t('update.denied'), ephemeral: true }));
        return;
      }
      if (!(await this.ackDeferUpdate(i))) return;
      await this.guarded(i, async () => {
        const updater = this.deps.autoUpdater;
        if (!updater) return;
        const ctx: DecisionCtx = {
          actorId: i.user.id,
          guildId: i.guildId ?? '',
          channelId: i.channelId,
          ack: (text) => safe(i.followUp({ content: text, ephemeral: true })),
          disableButtons: () => safe(i.editReply({ components: [buildUpdateDecidedRow(updateTarget.action)] })),
        };
        if (updateTarget.action === 'approve') {
          await updater.approve(updateTarget.version, ctx);
        } else {
          await updater.dismiss(updateTarget.version, ctx);
        }
      });
      return;
    }

    // The 📁 Create button opens a modal, and showModal IS the ack — it must NOT be
    // preceded by a deferUpdate (a deferred component can no longer show a modal). So
    // this is handled BEFORE the generic defer below. Drive-gated + owner-bound.
    if (i.customId === 'dir:create') {
      if (!this.authorize(i, 'drive')) return;
      await this.guarded(i, () => this.openCreateFolderModal(i));
      return;
    }

    // The "Resume Session" button and the resume flow's own selects (resume.*) drive a
    // separate resume state machine. Deferred-update first (listResumable/resume can
    // exceed 3s), then routed to the flow.
    if (i.customId === 'dir:resume' || i.customId.startsWith('resume.')) {
      if (!this.authorize(i, 'drive')) return;
      if (!(await this.ackDeferUpdate(i))) return;
      if (!i.guildId) return;
      await this.guarded(i, () => this.handleResumeComponent(i));
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
        return;
      }
      // Every non-terminal transition re-renders the CURRENT step (folder → backend →
      // model → perm → confirm) and edits it into the wizard's message, so each step's
      // picker actually appears. A cancel renders the terminal notice with no rows. The
      // component was deferUpdate'd above, so editReply updates that same message.
      const { embed, rows } = wizard.render();
      await safe(i.editReply({ embeds: [embed], components: rows }));
    });
  }

  // ---- 📁 Create folder --------------------------------------------------

  // Open the create-folder modal for the active wizard's folder step. Owner-bound: a
  // bystander (or a stale button with no wizard) is acknowledged (deferUpdate) and
  // ignored, so it never shows "did not respond". showModal is the ack for the owner's
  // click — the modal-submit interaction (handleCreateFolderModal) does the mkdir.
  private async openCreateFolderModal(i: ComponentInteraction): Promise<void> {
    const wizard = i.guildId ? this.wizards.get(channelKey(i.guildId, i.channelId)) : undefined;
    if (!wizard || wizard.ownerId !== i.user.id) {
      await safe(i.deferUpdate());
      return;
    }
    await i.showModal({
      customId: 'dir:create',
      title: t('dir.create.title'),
      fields: [
        {
          customId: 'name',
          label: t('dir.create.label'),
          placeholder: t('dir.create.placeholder'),
          required: true,
        },
      ],
    });
  }

  // Handle the create-folder modal submit: validate the name, create it as a DIRECT
  // subfolder of the wizard's CURRENT browsed directory, and re-render the folder step
  // (so the new folder appears). The name must be a single path segment — reject '/'
  // or '\\', '.'/'..' traversal, and any absolute path — so a crafted name can only
  // ever create a direct child of the browsed dir, never escape it. Owner-bound.
  private async handleCreateFolderModal(i: ModalSubmitInteraction): Promise<void> {
    if (!i.guildId) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    const wizard = this.wizards.get(channelKey(i.guildId, i.channelId));
    if (!wizard || wizard.ownerId !== i.user.id) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    const name = i.getField('name').trim();
    if (!isSafeFolderName(name)) {
      await safe(i.reply({ content: t('dir.create.invalid'), ephemeral: true }));
      return;
    }
    // Confine to a DIRECT child of the browsed dir: resolve and verify the parent is
    // exactly the browsed dir (defense in depth beyond the name check above).
    const parent = wizard.browserCwd();
    const target = path.join(parent, name);
    if (path.dirname(target) !== parent) {
      await safe(i.reply({ content: t('dir.create.invalid'), ephemeral: true }));
      return;
    }
    try {
      fs.mkdirSync(target, { recursive: true });
    } catch (err) {
      await safe(i.reply({ content: t('dir.create.failed', { error: String(err) }), ephemeral: true }));
      return;
    }
    // Re-render the folder step (the browser re-lists children on render, so the new
    // folder shows) and confirm the creation ephemerally. The modal submit is its own
    // interaction, so we reply to it directly.
    const { embed, rows } = wizard.render();
    await safe(i.reply({ content: t('dir.create.done', { name }), embeds: [embed], components: rows, ephemeral: true }));
  }

  // ---- Resume Session flow -----------------------------------------------

  // Route a resume-flow component: the "Resume Session" button starts a new flow (from
  // the active wizard's browsed folder); the resume.* selects/buttons advance it. The
  // interaction is already deferUpdate'd by the caller. Owner-bound to the wizard's
  // driver so a bystander cannot hijack the resume of another driver's folder pick.
  private async handleResumeComponent(i: ComponentInteraction): Promise<void> {
    const guildId = i.guildId as string;
    const key = channelKey(guildId, i.channelId);

    if (i.customId === 'dir:resume') {
      const wizard = this.wizards.get(key);
      if (!wizard || wizard.ownerId !== i.user.id) return; // owner-bound; ignore strays
      const flow = this.buildResumeWizard(guildId, i.channelId, i.user.id, wizard.browserCwd());
      this.resumeFlows.set(key, flow);
      const { embed, rows } = flow.render();
      await safe(i.editReply({ embeds: [embed], components: rows }));
      return;
    }

    // A resume.* select/button for an existing flow.
    const flow = this.resumeFlows.get(key);
    if (!flow || flow.ownerId !== i.user.id) return;
    const step = await flow.handle({ id: i.customId, ...(i.value !== undefined ? { value: i.value } : {}) });
    if (step === 'done' || step === 'cancelled' || step === 'empty') {
      this.resumeFlows.delete(key);
    }
    if (step === 'done') {
      const newChannelId = flow.sessionChannelId();
      if (newChannelId) {
        await safe(i.editReply({ content: t('resume.done', { channel: `<#${newChannelId}>` }), embeds: [], components: [] }));
      }
      return;
    }
    if (step === 'empty') {
      // No resumable sessions for the picked backend: ephemeral notice, flow ends.
      await safe(i.editReply({ content: t('resume.none'), embeds: [], components: [] }));
      return;
    }
    const { embed, rows } = flow.render();
    await safe(i.editReply({ embeds: [embed], components: rows }));
  }

  // Build a ResumeWizard bound to the driver + the folder in view. listResumableFor
  // dispatches to the chosen backend's mode.listResumable (Claude via listSessions,
  // Codex via CodexDiscovery); resume creates/binds a session channel and calls
  // orchestrator.resume there (mirroring the start flow's channel creation).
  private buildResumeWizard(guildId: string, channelId: string, ownerId: string, cwd: string): ResumeWizard {
    const resolved = this.deps.configResolver.resolve(guildId, channelId);
    return new ResumeWizard({
      guildId,
      channelId,
      ownerId,
      cwd,
      backends: this.deps.modeRegistry.list(),
      defaultBackend: resolved.mode,
      listResumableFor: (backend, dir) => this.listResumableFor(backend, dir),
      resume: (params) => this.resumeSession(params),
      relativeTime,
    });
  }

  // List resumable sessions for a backend, scoped to `cwd`, via the mode's optional
  // listResumable. A mode without it (or a throw) yields [] so the picker shows the
  // empty notice rather than failing. The ModeContext is a MINIMAL read-only context:
  // listResumable only reads ctx.cwd/ctx.config/ctx.logger (never emits/starts).
  private async listResumableFor(backend: string, cwd: string): Promise<ResumableSession[]> {
    if (!this.deps.modeRegistry.has(backend)) return [];
    const mode = this.deps.modeRegistry.get(backend);
    if (!mode.listResumable) return [];
    try {
      const ctx = this.deps.orchestrator.buildListContext(backend, cwd);
      return await mode.listResumable(ctx);
    } catch (err) {
      this.logError('listResumable failed', err);
      return [];
    }
  }

  // Resume a chosen session: create a dedicated session channel from the picked folder
  // (like the start flow), resume the backend session bound to THAT channel via
  // orchestrator.resume, wire renderers/permission/sendFile, and post a resumed-status
  // embed. Returns the new channel id so the flow links it back to the driver.
  private async resumeSession(params: {
    guildId: string;
    channelId: string;
    ownerId: string;
    backend: string;
    cwd: string;
    sessionId: string;
  }): Promise<{ session: ModeSession; channelId: string }> {
    const startParams: StartParams = {
      guildId: params.guildId,
      channelId: await this.resolveSessionChannelId({
        guildId: params.guildId,
        channelId: params.channelId,
        mode: params.backend,
        cwd: params.cwd,
        ownerId: params.ownerId,
      }),
      mode: params.backend,
      cwd: params.cwd,
      ownerId: params.ownerId,
    };
    const session = await this.deps.orchestrator.resume(startParams, params.sessionId);
    await this.deps.wiring.attach(startParams.guildId, startParams.channelId, startParams.mode);
    await this.postResumeIntro(startParams.channelId, startParams, session);
    return { session, channelId: startParams.channelId };
  }

  // Post the resumed-session status embed into the new channel (mirrors
  // postSessionIntro but titled as a resume). Best-effort; never fails the resume.
  private async postResumeIntro(channelId: string, params: StartParams, session: ModeSession): Promise<void> {
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
      await channel.send({ content: t('cmd.start.intro'), embeds: [{ ...embed, title: t('resume.status.title') }] });
    } catch (err) {
      this.logError('failed to post resume intro', err);
    }
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

// True when `name` is a safe SINGLE folder segment for the 📁 Create flow: non-empty,
// no path separators ('/' or '\\'), not '.'/'..' traversal, and not absolute. This
// guarantees the created folder is a DIRECT child of the current browsed directory and
// can never escape it (the router additionally verifies dirname(target) === parent).
function isSafeFolderName(name: string): boolean {
  if (name.length === 0) return false;
  if (name === '.' || name === '..') return false;
  if (name.includes('/') || name.includes('\\')) return false;
  if (path.isAbsolute(name)) return false;
  // A segment that path treats as anything other than itself (e.g. contains a NUL) is
  // rejected; path.basename normalizes trailing separators, so require an exact match.
  if (path.basename(name) !== name) return false;
  return true;
}

// Render an updatedAt ISO string as a short relative time for the resume picker
// (A4D-style "3분 전"). Absent/unparseable → empty (the option just shows its label).
function relativeTime(updatedAt: string | undefined): string {
  if (!updatedAt) return '';
  const then = Date.parse(updatedAt);
  if (Number.isNaN(then)) return '';
  const seconds = Math.max(0, Math.floor((Date.now() - then) / 1000));
  if (seconds < 60) return t('resume.time.now');
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return t('resume.time.min', { n: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return t('resume.time.hour', { n: hours });
  return t('resume.time.day', { n: Math.floor(hours / 24) });
}
