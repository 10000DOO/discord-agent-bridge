import * as path from 'node:path';
import type { ModelChoice, PermMode, SessionPermMode } from '../../core/contracts.js';
import { permissionModeLabel } from '../../core/providerCatalog.js';
import type { Preset } from '../../core/configSchema.js';
import type { UsageResult } from '../../core/usageService.js';
import { ChannelWizard } from '../wizard/channelWizard.js';
import { DirectoryBrowser } from '../directoryBrowser.js';
import { ConfigPanel } from '../configPanel.js';
import { ensureGuildChannels } from '../guildChannels.js';
import { setLocale, t, type Locale } from '../i18n.js';
import { channelKey, safe } from './helpers.js';
import type { ComponentInteraction, InteractionRouterHost, SlashInteraction } from './types.js';
import {
  deleteSessionChannel,
  startInChannel,
  startSession,
  switchSession,
  guildChannels,
} from './sessionLifecycle.js';

export function permModeChoicesFor(host: InteractionRouterHost, backend: string) : ModelChoice[] {
    const modes = host.deps.modeRegistry.get(backend).capabilities.permissionModes;
    return modes.map((m) => ({ value: m, label: permissionModeLabel(m) }));
  }

export async function startWizard(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string; // authorize() rejected DMs (no guild)
    // Always open at the folder step. When the guild has saved presets, the wizard offers
    // the preset picker AFTER the folder is chosen (folder → preset); with none it goes
    // straight to the backend step (R6 — no regression for guilds that never saved one).
    const wizard = await buildChannelWizard(host, guildId, i.channelId, i.user.id);
    host.wizards.set(channelKey(guildId, i.channelId), wizard);
    // Render the FIRST step (the folder picker) and attach it to the deferred reply.
    // Sending only cmd.start.launched left the user with a text line and nothing to
    // click — the wizard's embed + component rows (folder select + ⬆/✅ buttons) must
    // ride the editReply so the picker actually appears (mirrors openConfigPanel).
    const { embed, rows } = wizard.render();
    await i.editReply({ content: t('cmd.start.launched'), embeds: [embed], components: rows });
  }

export async function buildWizardOptionSources(host: InteractionRouterHost, guildId: string, channelId: string) {
    const resolved = host.deps.configResolver.resolve(guildId, channelId);
    const config = host.deps.configStore.load();
    const server = host.deps.configStore.loadServerConfig(guildId);
    const backends = host.deps.modeRegistry.list();
    const profiles = Object.keys(config.profiles);

    // Model list per backend — materialized ONCE at wizard start so the sync render
    // reads by backend key. The Claude probe is awaited here (fresh SDK list every
    // open); Codex resolves from its static list. Fallback covers a boot without the
    // dep wired.
    const modelsByBackend: Record<string, ModelChoice[]> = {};
    for (const b of backends) {
      modelsByBackend[b] =
        (await host.deps.modelsFor?.(b)) ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    }
    const modelsFor = (b: string): ModelChoice[] =>
      modelsByBackend[b] ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    // Permission + effort options come from each backend's OWN catalog (§6) — no branch on
    // the backend id. Claude narrows effort by the chosen model's SDK-reported
    // supportedEffortLevels; other backends' catalogs ignore that hint.
    const permsFor = (b: string): ModelChoice[] => host.deps.modeRegistry.get(b).catalog.permissionChoices();
    const effortsFor = (b: string, model: string): ModelChoice[] => {
      const supported = modelsFor(b).find((m) => m.value === model)?.supportedEffortLevels;
      return host.deps.modeRegistry.get(b).catalog.effortChoices(supported);
    };
    // The wizard's pre-selected reasoning effort per backend: the guild's server-saved
    // default (a NAMED config field, claudeEffort/codexEffort — §8, left as-is), then the
    // backend's catalog default. A preset seeds its own effort inside the wizard.
    const defaultEffortForBackend = (b: string): string => {
      const saved = b === 'codex' ? resolved.codexEffort : resolved.claudeEffort;
      return saved ?? host.deps.modeRegistry.get(b).catalog.defaultEffort() ?? '';
    };
    return { resolved, config, server, backends, profiles, modelsFor, permsFor, effortsFor, defaultEffortForBackend };
  }

export async function buildChannelWizard(host: InteractionRouterHost, guildId: string, channelId: string, ownerId: string) : Promise<ChannelWizard> {
    const src = await buildWizardOptionSources(host, guildId, channelId);
    const backend = src.resolved.mode;

    // Unbounded folder browsing by default (browse anywhere up to '/'), unless the
    // operator configured explicit browse roots — so the admin can pick a cwd on any
    // volume (Fix 1). Session file confinement is a separate mechanism and unaffected.
    const browser = new DirectoryBrowser({
      ...(host.deps.browseRoots && host.deps.browseRoots.length > 0
        ? { allowedRoots: host.deps.browseRoots }
        : {}),
      // Offer the 🖥️ native picker button only when a picker is actually wired.
      nativePanel: host.deps.pickFolder !== undefined,
    });

    return new ChannelWizard({
      guildId,
      channelId,
      ownerId,
      // The wizard just starts the session; the draft for "💾 save as preset" is captured
      // from wizard.current() in the done handler (only for a NON-preset launch).
      start: (params) => startSession(host, params),
      defaults: {
        backend,
        // Initial model = the backend's OWN catalog's first entry (mirrors applyBackend,
        // which resets to it on a backend CHANGE), so a non-Claude default backend never
        // leaks the Claude default. Codex's catalog leads with config.defaults.codexModel
        // when set; the alias fallback covers a boot without the models dep wired.
        model: src.modelsFor(backend)[0]?.value ?? src.resolved.claudeModel,
        permMode: src.resolved.permissionMode as SessionPermMode,
        profile: src.resolved.permissionProfile,
      },
      backends: src.backends,
      // Computed fresh on every wizard open (same dotfile scan /mode backend's choice
      // uses at command-registration time, but here it is live — no bot restart needed
      // to see a dotfile edit). Absent when the custom backend is not registered.
      ...(src.backends.includes('custom') && host.deps.customBackendLabel
        ? { customBackendLabel: host.deps.customBackendLabel() }
        : {}),
      modelsFor: src.modelsFor,
      profiles: src.profiles,
      permsFor: src.permsFor,
      effortsFor: src.effortsFor,
      defaultEffortFor: src.defaultEffortForBackend,
      browser,
      // Saved presets offered as the step after the folder (empty = no preset step, R6).
      // Deleting one removes it from the guild config and returns the refreshed list so the
      // picker re-renders in place (the wizard stays pure — the router owns persistence).
      presets: src.server?.presets ?? [],
      summarizePreset: (p) => summarizePreset(host, p),
      onDeletePreset: (name) => {
        host.deps.configStore.removeServerPreset(guildId, name);
        return host.deps.configStore.loadServerConfig(guildId)?.presets ?? [];
      },
      // A saved preset can outlive its backend (CLI removed / mode unregistered). The wizard
      // guards a pick against this before seeding + starting, so it never creates an orphan
      // session channel for a dead backend (mirrors isKnownBackend elsewhere in this router).
      backendAvailable: (b) => host.deps.modeRegistry.has(b),
    });
  }

export function summarizePreset(_host: InteractionRouterHost, p: Preset): string {
    // Discord caps a select option's description at 100 chars — clamp so a long summary
    // never throws when the picker renders (mirrors directoryBrowser.ts's clip helper).
    const clip = (s: string, max = 100): string => (s.length <= max ? s : s.slice(0, max - 1) + '…');
    return clip(
      t('preset.summary', {
        backend: p.backend,
        model: p.model ?? '-',
        effort: p.effort ?? '-',
        perm: p.profile ?? p.permMode ?? '-',
      }),
    );
  }

export async function openConfigPanel(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    if (i.guildId === null) {
      await i.editReply({ content: t('auth.denied', { reason: 'DM' }) });
      return;
    }
    if (!host.authorizeConfig(i)) {
      await i.editReply({ content: t('cmd.config.denied') });
      return;
    }
    const guildId = i.guildId;
    const global = host.deps.configStore.load();
    const server = host.deps.configStore.loadServerConfig(guildId);
    const resolved = host.deps.configResolver.resolve(guildId, i.channelId);
    const backends = host.deps.modeRegistry.list();
    const models = (await host.deps.modelsFor?.(resolved.mode)) ?? [{ value: resolved.claudeModel, label: resolved.claudeModel }];
    const permModes = permModeChoicesFor(host, resolved.mode);
    // Reasoning-effort options + prefilled default for the CURRENT backend, from that
    // backend's catalog (§6). Claude narrows by the selected model's supportedEffortLevels;
    // other backends' catalogs ignore the hint, so it is passed unconditionally. The
    // resolved effort VALUE is a NAMED config field (claudeEffort/codexEffort — §8, left
    // as-is); its fallback is the catalog's default.
    const catalog = host.deps.modeRegistry.get(resolved.mode).catalog;
    const supportedClaudeLevels = models.find((m) => m.value === resolved.claudeModel)?.supportedEffortLevels;
    const efforts = catalog.effortChoices(supportedClaudeLevels);
    const resolvedEffort = resolved.mode === 'codex' ? resolved.codexEffort : resolved.claudeEffort;
    const currentEffort = resolvedEffort ?? catalog.defaultEffort() ?? '';

    // Current effective role tiers = server override when present, else global.
    const panel = new ConfigPanel({
      guildId,
      ownerId: i.user.id,
      configStore: host.deps.configStore,
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
      isKnownBackend: (b) => host.deps.modeRegistry.has(b),
      models,
      efforts,
      permModes,
    });
    host.configPanels.set(channelKey(guildId, i.channelId), panel);
    // A single Discord message allows at most 5 action rows. Role tiers + Save (4 rows)
    // ride the deferred reply; the defaults follow-up carries backend/model/effort/
    // permMode/locale selects (5 rows — exactly at the limit). Both are ephemeral.
    const { embed, roleRows, defaultRows } = panel.render();
    await i.editReply({ content: t('cmd.config.opened'), embeds: [embed], components: roleRows });
    await i.followUp({ components: defaultRows, ephemeral: true });
  }

export async function runSetup(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    if (i.guildId === null) {
      await i.editReply({ content: t('auth.denied', { reason: 'DM' }) });
      return;
    }
    if (!host.authorizeConfig(i)) {
      await i.editReply({ content: t('cmd.config.denied') });
      return;
    }
    const provisioner = host.deps.resolveGuildProvisioner
      ? await host.deps.resolveGuildProvisioner(i.guildId)
      : null;
    if (!provisioner) {
      await i.editReply({ content: t('cmd.setup.unavailable') });
      return;
    }
    // Skip create/rename entirely when the stored structure's four channels are all
    // still alive — a no-op re-run must not touch discord.js or offer the (already
    // resolved) Chromium prompt. Assumes a live control channel never has a stale
    // name, so a rename-only re-run is not a case this guard needs to handle.
    const existing = guildChannels(host, i.guildId);
    if (
      existing &&
      existing.statusChannelId &&
      provisioner.channelExists(existing.categoryId) &&
      provisioner.channelExists(existing.controlChannelId) &&
      provisioner.channelExists(existing.sessionsCategoryId) &&
      provisioner.channelExists(existing.statusChannelId)
    ) {
      await i.editReply({
        content: t('cmd.setup.alreadyDone', { control: `<#${existing.controlChannelId}>` }),
      });
      return;
    }
    const channels = await ensureGuildChannels(provisioner, host.deps.configStore);
    await i.editReply({
      content: t('cmd.setup.done', { control: `<#${channels.controlChannelId}>` }),
    });
    // Offer the Chromium install prompt in the fresh control channel (design §9.2).
    await host.maybePromptRenderSetup(channels.controlChannelId);
  }

export async function handleRenderSetup(host: InteractionRouterHost, i: ComponentInteraction, action: 'install' | 'decline') : Promise<void> {
    const prov = host.deps.imageProvisioner;
    if (!prov) {
      await safe(i.followUp({ content: t('render.setup.unavailable'), ephemeral: true }));
      return;
    }
    if (action === 'decline') {
      host.deps.configStore.setChromiumDecision('declined');
      await safe(i.followUp({ content: t('render.setup.declined'), ephemeral: false }));
      return;
    }
    host.deps.configStore.setChromiumDecision('accepted');
    if (prov.isInstalled()) {
      await safe(i.editReply({ content: t('render.setup.already'), components: [] }));
      return;
    }
    // Morph the prompt message (deferUpdate'd component → editReply edits it) into a live
    // progress bar as the download runs, then a completion line. Buttons removed.
    const bar = (pct: number): string => {
      const n = Math.max(0, Math.min(10, Math.round(pct / 10)));
      return t('render.setup.progress', { bar: '▓'.repeat(n) + '░'.repeat(10 - n), pct: String(pct) });
    };
    await safe(i.editReply({ content: bar(0), components: [] }));
    try {
      await prov.install((pct) => {
        host.deps.logger.info('chromium install progress', { pct });
        void safe(i.editReply({ content: bar(pct), components: [] }));
      });
      await safe(i.editReply({ content: t('render.setup.done'), components: [] }));
    } catch (err) {
      host.deps.logger.error('chromium install failed', { err: String(err) });
      await safe(i.editReply({ content: t('render.setup.failed'), components: [] }));
    }
  }

export function applyLocaleIfLocaleSelect(_host: InteractionRouterHost, customId: string, value?: string): void {
    if (customId !== 'config.default.locale' || !value) return;
    if (value === 'ko' || value === 'en') setLocale(value as Locale);
  }

export async function resume(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const binding = host.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding || binding.archived) {
      await i.editReply({ content: t('cmd.resume.none') });
      return;
    }
    // For Claude, listResumable is currently [] — re-bind/inform gracefully.
    await host.deps.wiring.attach(guildId, i.channelId, binding.mode);
    await i.editReply({ content: t('cmd.resume.rebound') });
  }

export async function close(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    await host.deps.orchestrator.stop(guildId, i.channelId);
    host.deps.wiring.detach(guildId, i.channelId);
    // A4D behavior: delete the dedicated session channel on close. Guarded — never
    // delete the control channel or a channel that isn't the closed session's, and
    // skip when no provisioner is wired. Best-effort: a delete failure still reports
    // the session closed (the reply may not survive if this channel is the one deleted,
    // which is expected). Reply BEFORE deleting so the ack lands first.
    await i.editReply({ content: t('cmd.close.done') });
    await deleteSessionChannel(host, guildId, i.channelId);
  }

export async function stats(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string; // authorize() rejected DMs (no guild)
    const fields: { name: string; value: string; inline?: boolean }[] = [];

    // Active sessions (this guild): count + up to 10 channel lines.
    const active = host.deps.orchestrator.listActive(guildId);
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
    const bindings = host.deps.channelRegistry.list().filter((b) => b.guildId === guildId);
    const archived = bindings.filter((b) => b.archived).length;
    fields.push({
      name: t('stats.bindings'),
      value: t('stats.bindings.value', { active: bindings.length - archived, archived }),
    });

    // Claude usage (global — labelled). Only shown when Claude OAuth is logged in.
    fields.push({ name: t('stats.usage'), value: await usageStatsLine(host) });

    await i.editReply({ embeds: [{ title: t('stats.title'), fields }] });
  }

export async function usageStatsLine(host: InteractionRouterHost) : Promise<string> {
    if (!host.deps.usageService.isAvailable()) return t('stats.usage.unavailable');
    let usage: UsageResult;
    try {
      usage = await host.deps.usageService.getUsage();
    } catch {
      return t('stats.usage.unavailable');
    }
    if (!('fetchedAt' in usage)) return t('stats.usage.unavailable');
    const parts: string[] = [];
    if (usage.fiveHour) parts.push(usageSegment(host, t('usage.fiveHour'), usage.fiveHour));
    if (usage.sevenDay) parts.push(usageSegment(host, t('usage.weekly'), usage.sevenDay));
    return parts.length > 0 ? parts.join(' · ') : t('stats.usage.unavailable');
  }

export function usageSegment(
  _host: InteractionRouterHost,
  label: string,
  limit: { utilization: number; resetsAt?: string },
): string {
    const base = `${label} ${Math.round(limit.utilization)}%`;
    return limit.resetsAt ? `${base} (${t('usage.resets', { reset: limit.resetsAt })})` : base;
  }

export async function switchBackend(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const backend = i.getString('backend');
    if (!backend) return;
    // Validate the target backend BEFORE any teardown: an unregistered backend (e.g.
    // Codex before Phase 2 registers it) must NOT stop/detach the running session.
    if (!host.deps.modeRegistry.has(backend)) {
      await i.editReply({ content: t('cmd.mode.unavailable', { backend }) });
      return;
    }
    // Require an existing binding: there is no cwd/owner to carry over otherwise, and
    // falling back to process.cwd() would start a session in the bot's own directory.
    const binding = host.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await i.editReply({ content: t('router.noSession') });
      return;
    }
    // Same backend re-selected: keep the existing immediate switch (R6). model/effort are
    // carried over (both backend-specific — the SAME-backend guard below always holds here).
    if (backend === binding.mode) {
      // Switching the backend starts a fresh context (§9 step 3): stop the current
      // session, then start a new one on the same cwd/owner/permMode and re-wire.
      const { cwd, ownerId, permMode, profile, model, effort, mode: prevMode } = binding;

      await host.deps.orchestrator.stop(guildId, i.channelId);
      host.deps.wiring.detach(guildId, i.channelId);
      await startInChannel(host, {
        guildId,
        channelId: i.channelId,
        mode: backend,
        cwd,
        ownerId,
        permMode,
        profile,
        // Carry the model/effort only when restarting on the SAME backend; both are
        // backend-specific, so a cross-backend switch discards them (config default).
        ...(backend === prevMode && model !== undefined ? { model } : {}),
        ...(backend === prevMode && effort !== undefined ? { effort } : {}),
      });
      // Confirmation closes the ephemeral deferred reply (only the actor sees it). The
      // fresh-context warning (§9 step 3) is PUBLIC so the whole channel sees the context
      // reset — posted as a non-ephemeral followUp since the deferred reply is ephemeral.
      await i.editReply({ content: t('cmd.mode.switched', { backend }) });
      await safe(i.followUp({ content: t('cmd.mode.freshContext', { backend }), ephemeral: false }));
      return;
    }

    // Different backend: DO NOT stop the running session (R1/R4). Open the reconfigure popup
    // (model → effort → perm) so the driver re-picks settings for the new backend; the actual
    // stop → detach → same-channel restart happens only on confirm, via switchSession (R3).
    const src = await buildWizardOptionSources(host, guildId, i.channelId);
    const browser = new DirectoryBrowser({
      ...(host.deps.browseRoots && host.deps.browseRoots.length > 0
        ? { allowedRoots: host.deps.browseRoots }
        : {}),
      nativePanel: host.deps.pickFolder !== undefined,
    });
    const wizard = new ChannelWizard({
      guildId,
      channelId: i.channelId,
      // The actor drives the popup; the restarted session keeps the EXISTING binding's owner.
      ownerId: i.user.id,
      start: (p) => switchSession(host, { ...p, ownerId: binding.ownerId }),
      defaults: {
        backend,
        model: src.modelsFor(backend)[0]?.value ?? src.resolved.claudeModel,
        permMode: src.resolved.permissionMode as SessionPermMode,
        profile: src.resolved.permissionProfile,
      },
      backends: src.backends,
      ...(src.backends.includes('custom') && host.deps.customBackendLabel
        ? { customBackendLabel: host.deps.customBackendLabel() }
        : {}),
      modelsFor: src.modelsFor,
      profiles: src.profiles,
      permsFor: src.permsFor,
      effortsFor: src.effortsFor,
      defaultEffortFor: src.defaultEffortForBackend,
      browser,
      // Seed: omit model/effort so the wizard pre-selects the NEW backend's defaults (R5/D5);
      // carry the current permission (permMode/profile) over from the binding.
      entry: { backend, cwd: binding.cwd, permMode: binding.permMode, profile: binding.profile ?? null },
    });
    host.wizards.set(channelKey(guildId, i.channelId), wizard);
    const { embed, rows } = wizard.render();
    await i.editReply({ embeds: [embed], components: rows });
  }

export async function switchPerm(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const value = i.getString('value');
    if (!value) return;
    const binding = host.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await i.editReply({ content: t('router.noSession') });
      return;
    }
    // A value that names a known profile switches the profile; otherwise it is a raw
    // permission mode. Either way the session is kept (applies on next turn/spawn).
    const config = host.deps.configStore.load();
    const isProfile = Object.prototype.hasOwnProperty.call(config.profiles, value);
    const override = isProfile
      ? { profile: value }
      : { permMode: value as PermMode };
    const resolved = host.deps.permissionResolver.resolve(guildId, i.channelId, override);
    host.deps.channelRegistry.set({
      guildId,
      channelId: i.channelId,
      mode: binding.mode,
      sessionId: binding.sessionId,
      cwd: binding.cwd,
      ownerId: binding.ownerId,
      permMode: resolved.permMode,
      profile: resolved.profile,
      // set() REPLACES the binding — carry the wizard-chosen model/effort or they are dropped.
      ...(binding.model !== undefined ? { model: binding.model } : {}),
      ...(binding.effort !== undefined ? { effort: binding.effort } : {}),
      ...(binding.projectAuth ? { projectAuth: binding.projectAuth } : {}),
    });
    await i.editReply({ content: t('cmd.perm.switched', { perm: resolved.profile ?? resolved.permMode }) });
  }

export async function switchModel(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const value = i.getString('value');
    if (!value) return;
    const outcome = await host.deps.orchestrator.setModel(guildId, i.channelId, value);
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

export async function switchEffort(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const value = i.getString('value');
    if (!value) return;
    const outcome = await host.deps.orchestrator.setEffort(guildId, i.channelId, value);
    const key =
      outcome === 'ok'
        ? 'cmd.effort.switched'
        : outcome === 'unsupported'
          ? 'cmd.effort.unsupported'
          : outcome === 'no-session'
            ? 'router.noSession'
            : 'cmd.effort.failed';
    await i.editReply({ content: t(key, { effort: value }) });
  }


export async function stop(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    await host.deps.orchestrator.stop(guildId, i.channelId);
    host.deps.wiring.detach(guildId, i.channelId);
    await i.editReply({ content: t('cmd.stop.done') });
  }

export async function clearContext(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const binding = host.deps.channelRegistry.get(guildId, i.channelId);
    if (!binding) {
      await i.editReply({ content: t('router.noSession') });
      return;
    }
    const { cwd, ownerId, permMode, profile, model, effort, mode } = binding;

    await host.deps.orchestrator.stop(guildId, i.channelId);
    host.deps.wiring.detach(guildId, i.channelId);
    await startInChannel(host, {
      guildId,
      channelId: i.channelId,
      mode,
      cwd,
      ownerId,
      permMode,
      profile,
      ...(model !== undefined ? { model } : {}),
      ...(effort !== undefined ? { effort } : {}),
    });
    // Ephemeral confirmation for the actor; public channel notice so everyone sees the
    // context reset (same pattern as /mode backend's fresh-context followUp).
    await i.editReply({ content: t('cmd.clear.done') });
    await safe(i.followUp({ content: t('cmd.clear.public'), ephemeral: false }));
  }

export async function shareDoc(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const binding = host.deps.channelRegistry.get(guildId, i.channelId);
    const shareDocumentFor = host.deps.shareDocumentFor;
    if (!binding || !shareDocumentFor) {
      await i.editReply({ content: t('router.noSession') });
      return;
    }
    const docPath = i.getString('path');
    if (!docPath) return;
    // The core returns one of its five ShareErrorCodes for known rejections but RETHROWS
    // anything else (EACCES, a stat↔read race, a Discord post failure — ch.8). Wrap the
    // funnel so a thrown error becomes a generic notice, not an unhandled rejection.
    try {
      const res = await shareDocumentFor(guildId, i.channelId)(docPath);
      if (res.ok) {
        await i.editReply({ content: t('doc.shared', { path: res.path ?? docPath }) });
      } else if (res.code) {
        await i.editReply({ content: t('doc.error.' + res.code, { path: docPath, ...(res.max ? { max: res.max } : {}) }) });
      } else {
        // Uncoded failure = the channel has no live session/sink (shareDocumentFor backstop).
        await i.editReply({ content: t('router.noSession') });
      }
    } catch (err) {
      host.logError('failed to share document', err);
      await i.editReply({ content: t('cmd.error.generic') });
    }
  }

export async function stopAll(host: InteractionRouterHost, i: SlashInteraction) : Promise<void> {
    // Detach every wired channel first so no renderer lingers, then stop all.
    const bindings = host.deps.channelRegistry.list().filter((b) => !b.archived);
    for (const b of bindings) host.deps.wiring.detach(b.guildId, b.channelId);
    await host.deps.orchestrator.stopAll();
    await i.editReply({ content: t('cmd.stopAll.done', { count: bindings.length }) });
  }
