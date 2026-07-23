import type { ModelChoice } from '../../core/contracts.js';
import type { AuthAction } from '../../core/auth.js';
import { claudeCatalog } from '../../core/providerCatalog.js';
import type { AutoUpdater } from '../../update/autoUpdater.js';
import type { GuildChannelProvisioner } from '../guildChannels.js';
import type { MessageChannel } from '../ports.js';
import { ChannelWizard } from '../wizard/channelWizard.js';
import { ResumeWizard } from '../wizard/resumeWizard.js';
import { ConfigPanel } from '../configPanel.js';
import { buildRenderSetupButtons } from '../renderers/renderSetupButton.js';
import { t } from '../i18n.js';
import type {
  AckPayload,
  ComponentInteraction,
  InteractionRouterDeps,
  InteractionRouterHost,
  PresetDraft,
  RouterInteraction,
  SlashInteraction,
} from './types.js';
import { ACTION_TIER, safe } from './helpers.js';
import { handleComponent } from './components.js';
import { handleModalSubmit } from './modals.js';
import {
  startWizard,
  resume,
  close,
  stats,
  switchBackend,
  switchPerm,
  switchModel,
  switchEffort,
  stop,
  clearContext,
  shareDoc,
  stopAll,
  openConfigPanel,
  runSetup,
} from './slashCommands.js';

// InteractionCreate router (§4, §7.1, §9). Authorizes FIRST (tier per action), then
// dispatches slash commands and component interactions. discord.js is not imported
// as a value: narrow interaction shapes below are satisfied structurally by the real
// discord.js interactions, so unit tests drive fakes. The client.ts handler narrows
// a raw Interaction with the discord.js type guards and calls handle().
//
// Handler bodies live in interaction/* modules as free functions taking this host;
// the class owns mutable state maps and the shared ack/auth/queue helpers.

export class InteractionRouter implements InteractionRouterHost {
  readonly deps: InteractionRouterDeps;
  // Active wizards keyed by guildId:channelId, so follow-up component interactions
  // (folder/backend/model/perm selects, confirm/cancel) route back to the same flow.
  readonly wizards = new Map<string, ChannelWizard>();
  // Active resume flows keyed by guildId:channelId (started from the folder step's
  // "Resume Session" button), so the backend/session selects route back to the flow.
  readonly resumeFlows = new Map<string, ResumeWizard>();
  // Active /config panels keyed by guildId:channelId, so follow-up role/string
  // selects + Save route back to the panel that holds the pending selections.
  readonly configPanels = new Map<string, ConfigPanel>();
  // Session-config drafts captured when a NORMAL wizard reaches done, keyed by the ORIGINAL
  // command channel (guildId:channelId), so the done reply's "💾 save as preset" button
  // + name modal can persist what was just launched. A preset-launched wizard records none,
  // so it never re-offers saving. Deleted on save; overwritten by the next normal start on
  // the same channel. Not otherwise pruned — a draft can linger if the save button is never
  // clicked, the flow is cancelled after done, or the channel is deleted.
  readonly presetDrafts = new Map<string, PresetDraft>();
  // Short-lived cache for /model's autocomplete ONLY (see getModelAutocomplete).
  // deps.modelsFor stays uncached for the wizard/config panel, which need the
  // freshest list on every (rare) open.
  modelAutocompleteCache: { choices: ModelChoice[]; fetchedAt: number } | null = null;
  readonly modelAutocompleteCacheMs = 60_000;
  // Channels with a native folder picker currently open (dir:panel) — one panel per
  // channel; a second click is bounced instead of stacking dialogs on the host.
  readonly folderPanels = new Set<string>();
  // The picker is only useful when the operator is AT the host, so an unattended
  // dialog (e.g. tapped from mobile) is closed after this long.
  readonly folderPanelTimeoutMs = 120_000;
  // Per-channel wizard component serialization: concurrent button/select clicks on the
  // same channel must not interleave handle+editReply (race → stuck UI / dropped step).
  readonly wizardQueues = new Map<string, Promise<void>>();

  constructor(deps: InteractionRouterDeps) {
    this.deps = deps;
    // Restore any preset drafts backed up to state.json so a "💾 save as preset" button
    // survives a restart (the in-memory Map is otherwise lost on boot).
    for (const [key, draft] of Object.entries(deps.stateStore.getPresetDrafts())) {
      this.presetDrafts.set(key, draft);
    }
  }

  // Bind the live-gateway resolvers AFTER construction (app boot). The client depends
  // on this router, so the router cannot capture the client at construction — these
  // setters mirror wiring.setResolveChannel. Used by /setup and /agent start's session-
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
      await handleComponent(this, interaction);
      return;
    }
    if (interaction.kind === 'modalSubmit') {
      await handleModalSubmit(this, interaction);
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
      await this.guarded(i, () => openConfigPanel(this, i));
      return;
    }

    // /setup creates the guild channel structure (control channel + sessions category).
    // Same bootstrap gate as /config (Administrator OR admin tier) so a fresh server
    // admin can run it before any role is configured.
    if (actionKey === 'setup') {
      await this.guarded(i, () => runSetup(this, i));
      return;
    }

    const action = ACTION_TIER[actionKey] ?? 'drive';

    if (!this.authorize(i, action)) return;

    await this.guarded(i, async () => {
      switch (actionKey) {
        case 'agent.start':
          await startWizard(this, i);
          break;
        case 'agent.resume':
          await resume(this, i);
          break;
        case 'agent.close':
          await close(this, i);
          break;
        case 'agent.stats':
          await stats(this, i);
          break;
        case 'mode.backend':
          await switchBackend(this, i);
          break;
        case 'mode.perm':
          await switchPerm(this, i);
          break;
        case 'model':
          await switchModel(this, i);
          break;
        case 'effort':
          await switchEffort(this, i);
          break;
        case 'stop':
          await stop(this, i);
          break;
        case 'clear':
          await clearContext(this, i);
          break;
        case 'doc':
          await shareDoc(this, i);
          break;
        case 'stop-all':
          await stopAll(this, i);
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
  async ackDefer(i: RouterInteraction, options?: { ephemeral?: boolean }): Promise<boolean> {
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
  async guarded(i: RouterInteraction, fn: () => Promise<void>): Promise<void> {
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
  logError(message: string, err: unknown): void {
    if (err instanceof Error) {
      this.deps.logger.error(message, { error: err.message, stack: err.stack });
    } else {
      this.deps.logger.error(message, { error: String(err) });
    }
  }

  // Post the one-time Chromium install prompt to a channel when image rendering is
  // enabled, no browser is present, and the operator has not yet decided. Best-effort:
  // a failure never affects /setup or guild provisioning. Anyone can act on it (host-wide
  // decision). Public so the app's GuildCreate auto-provision path can offer it on a fresh
  // invite (guarded there so ClientReady re-provisioning never re-posts it).
  async maybePromptRenderSetup(channelId: string): Promise<void> {
    const prov = this.deps.imageProvisioner;
    if (!prov) return;
    const cfg = this.deps.configStore.load();
    const enabled = cfg.render?.enabled ?? true;
    const decision = cfg.chromium?.decision ?? 'undecided';
    if (!enabled || decision !== 'undecided' || prov.isInstalled()) return;
    const sink = this.deps.resolveChannel ? await this.deps.resolveChannel(channelId) : null;
    if (!sink) return;
    await safe(sink.send({ content: t('render.setup.prompt'), components: [buildRenderSetupButtons()] }));
  }

  // The /config bootstrap gate: allow if the actor has the Discord Administrator
  // permission (works on first run with an empty allowlist) OR clears the admin tier
  // (works once the allowlist is configured). Never uses the generic tier-denial
  // reply — the caller sends the /config-specific notice.
  authorizeConfig(i: RouterInteraction): boolean {
    if (i.hasAdminPermission === true) return true;
    const roleIds = i.member ? i.member.roles.cache.map((r) => r.id) : [];
    return this.deps.authorizer.authorize({
      userId: i.user.id,
      roleIds,
      action: 'admin',
      context: { ...(i.guildId ? { guildId: i.guildId } : {}), channelId: i.channelId },
    }).allowed;
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

  // /effort's `value` option autocomplete: unlike /model (always Claude), the offered
  // levels depend on THIS channel's backend/model. Claude → the model's supportedEffortLevels
  // ∩ the runtime-settable set {low,medium,high,xhigh} (never 'max', which is start-only);
  // Codex/Grok → catalog.runtimeEffortChoices(model.supportedEffortLevels) from modelsFor
  // (local cache; empty supported → catalog fallback, e.g. full Codex list / Grok []).
  // Reads the channel binding for backend/model; when there is no binding yet it falls back
  // to the resolved backend default (the actual /effort then reports no-session). Claude
  // reuses the 60s model cache so a typing burst pays for at most one SDK probe; other
  // backends use modelsFor (mtime-gated file read). Discord caps results at 25; never rejects.
  async getEffortAutocomplete(
    guildId: string | null,
    channelId: string,
    query: string,
  ): Promise<{ name: string; value: string }[]> {
    const binding = guildId ? this.deps.channelRegistry.get(guildId, channelId) : undefined;
    const resolved = this.deps.configResolver.resolve(guildId ?? '', channelId);
    const backend = binding?.mode ?? resolved.mode;
    // An unregistered backend (e.g. a hand-edited config/binding) has no live vocabulary;
    // return no suggestions rather than throwing (autocomplete must never reject).
    if (!this.deps.modeRegistry.has(backend)) return [];
    const catalog = this.deps.modeRegistry.get(backend).catalog;
    // Claude: SDK-probed model list (cached) ∩ runtime set. Non-Claude: modelsFor (or
    // catalog.models fallback) → binding/default model → supportedEffortLevels, same shape
    // as the wizard's effortsFor (R3).
    let supported: readonly string[] | undefined;
    if (catalog === claudeCatalog) {
      const model = binding?.model ?? resolved.claudeModel;
      const models = await this.claudeModelsForAutocomplete();
      supported = models.find((m) => m.value === model)?.supportedEffortLevels;
    } else {
      const models =
        (await this.deps.modelsFor?.(backend)) ??
        (await Promise.resolve(catalog.models(resolved.codexModel || undefined)));
      const model =
        binding?.model ||
        (backend === 'codex' && resolved.codexModel ? resolved.codexModel : undefined) ||
        models[0]?.value;
      supported = model ? models.find((m) => m.value === model)?.supportedEffortLevels : undefined;
    }
    const choices = catalog.runtimeEffortChoices(supported);
    const q = query.trim().toLowerCase();
    const matches =
      q.length === 0
        ? choices
        : choices.filter((c) => c.value.toLowerCase().includes(q) || c.label.toLowerCase().includes(q));
    return matches.slice(0, 25).map((c) => ({ name: c.label, value: c.value }));
  }

  // The Claude model list, cached for modelAutocompleteCacheMs. Discord's autocomplete
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
      now - this.modelAutocompleteCache.fetchedAt < this.modelAutocompleteCacheMs
    ) {
      return this.modelAutocompleteCache.choices;
    }
    const choices = (await this.deps.modelsFor?.('claude')) ?? [];
    this.modelAutocompleteCache = { choices, fetchedAt: now };
    return choices;
  }

  // Chain a wizard handler onto the per-channel promise queue so concurrent component
  // interactions on the same channel never interleave. Errors from prior work are
  // swallowed for chain continuity (each job has its own guarded try/catch).
  enqueueWizard(key: string, job: () => Promise<void>): Promise<void> {
    const prev = this.wizardQueues.get(key) ?? Promise.resolve();
    const next = prev.then(job, job);
    this.wizardQueues.set(key, next);
    // Drop the map entry once this job finishes if nothing newer chained after it.
    void next.finally(() => {
      if (this.wizardQueues.get(key) === next) this.wizardQueues.delete(key);
    });
    return next;
  }

  // editReply for a wizard re-render: log failures (never silent) and retry once.
  async editWizardReply(i: ComponentInteraction, payload: AckPayload): Promise<void> {
    try {
      await i.editReply(payload);
    } catch (err) {
      this.logError('wizard editReply failed; retrying once', err);
      try {
        await i.editReply(payload);
      } catch (err2) {
        this.logError('wizard editReply retry failed', err2);
      }
    }
  }

  // deferUpdate the component interaction (the first ack, keeping its message). Returns
  // false when the ack itself failed (stale interaction) so the caller bails out.
  async ackDeferUpdate(i: ComponentInteraction): Promise<boolean> {
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
  authorize(i: RouterInteraction, action: AuthAction): boolean {
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
