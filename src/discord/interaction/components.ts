import type { DecisionCtx } from '../../update/autoUpdater.js';
import { parseCustomId } from '../renderers/permissionButtons.js';
import { parseInterruptId } from '../renderers/interruptButton.js';
import { parseUpdateId, buildUpdateDecidedRow } from '../renderers/updateButton.js';
import { parseRenderSetupId } from '../renderers/renderSetupButton.js';
import { isConfigPanelId, type ConfigPanelInput } from '../configPanel.js';
import { ResumeWizard } from '../wizard/resumeWizard.js';
import type { WizardInput } from '../wizard/channelWizard.js';
import type { ModalSpec } from '../ports.js';
import { t } from '../i18n.js';
import { channelKey, safe, relativeTime } from './helpers.js';
import type {
  ComponentInteraction,
  InteractionRouterHost,
  PresetDraft,
} from './types.js';
import { handleRenderSetup, applyLocaleIfLocaleSelect } from './slashCommands.js';
import { listResumableFor, resumeSession } from './sessionLifecycle.js';

export async function handleConfigComponent(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    if (!i.guildId) {
      await safe(i.deferUpdate());
      return;
    }
    if (!host.authorizeConfig(i)) {
      await safe(i.reply({ content: t('cmd.config.denied'), ephemeral: true }));
      return;
    }
    const panel = host.configPanels.get(channelKey(i.guildId, i.channelId));
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
      host.configPanels.delete(channelKey(i.guildId, i.channelId));
      // Save is a button on the primary (ephemeral) message; a fresh ephemeral reply
      // carries the confirmation summary without disturbing the still-open panel.
      await safe(i.reply({ content: result.summary, ephemeral: true }));
      return;
    }
    if (result.kind === 'autosaved') {
      // A defaults select persisted one field immediately; confirm it ephemerally
      // (a fresh reply, keeping the panel open). If it was the locale select, drive
      // setLocale so THIS session's subsequent responses use the chosen language.
      applyLocaleIfLocaleSelect(host, i.customId, i.value);
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
    if (result.kind === 'renderPanel') {
      // 🖼 opens the image-render sub-panel as a fresh ephemeral message.
      await safe(i.reply({ embeds: [result.embed], components: result.rows, ephemeral: true }));
      return;
    }
    if (result.kind === 'renderUpdated') {
      await safe(i.deferUpdate());
      await safe(i.editReply({ embeds: [result.embed], components: result.rows }));
      return;
    }
    if (result.kind === 'renderInstall') {
      // Install from /config reuses the same provisioner flow as the /setup button.
      await safe(i.deferUpdate());
      await handleRenderSetup(host, i, 'install');
      return;
    }
    // A pending selection or an ignored input: just acknowledge (keep the panel open).
    await safe(i.deferUpdate());
  }

export async function handleComponent(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    // /config panel components own their own ack flow (deferUpdate on a pending pick,
    // an ephemeral reply on Save / denial). Fast work only (in-memory panel state plus
    // one small JSON write on Save), so they ack within the window without a leading
    // defer. Same bootstrap gate as opening the panel; owner-bound.
    if (isConfigPanelId(i.customId)) {
      await handleConfigComponent(host, i);
      return;
    }

    // Permission buttons: perm:<reqId>:<action>. These are gated to execute tier
    // (the driver decides). Route to the channel's PermissionButtonsHandler, passing
    // the acting user id so the handler enforces that ONLY the prompt's approver
    // (the session owner) can resolve it — a bystander click is ignored (§7.1/§7.5).
    if (parseCustomId(i.customId)) {
      if (!host.authorize(i, 'drive')) return;
      // Acknowledge FIRST (deferUpdate keeps the existing message), THEN resolve the
      // permission — resolvePermission touches the session and must never delay the
      // ack past Discord's 3s window.
      if (!(await host.ackDeferUpdate(i))) return;
      await host.guarded(i, async () => {
        if (i.guildId) {
          await host.deps.wiring.resolvePermission(i.guildId, i.channelId, i.customId, i.user.id);
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
      if (!host.authorize(i, 'drive')) return;
      if (!(await host.ackDeferUpdate(i))) return;
      await host.guarded(i, async () => {
        const ok = await host.deps.orchestrator.interrupt(interruptTarget.guildId, interruptTarget.channelId);
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
      if (!host.authorizeConfig(i)) {
        await safe(i.reply({ content: t('update.denied'), ephemeral: true }));
        return;
      }
      if (!(await host.ackDeferUpdate(i))) return;
      await host.guarded(i, async () => {
        const updater = host.deps.autoUpdater;
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

    // Chromium install prompt (render-setup:install|decline) — post at /setup. Anyone may
    // trigger it (design §8.2: no owner gate beyond the component's drive tier). The
    // decision is host-wide; install downloads Chromium in the background with progress.
    const renderSetup = parseRenderSetupId(i.customId);
    if (renderSetup) {
      if (!host.authorize(i, 'drive')) return;
      if (!(await host.ackDeferUpdate(i))) return;
      await host.guarded(i, () => handleRenderSetup(host, i, renderSetup.action));
      return;
    }

    // The 📁 Create button opens a modal, and showModal IS the ack — it must NOT be
    // preceded by a deferUpdate (a deferred component can no longer show a modal). So
    // this is handled BEFORE the generic defer below. Drive-gated + owner-bound.
    if (i.customId === 'dir:create') {
      if (!host.authorize(i, 'drive')) return;
      await host.guarded(i, () => openCreateFolderModal(host, i));
      return;
    }

    // The 📝 manual-path button also opens a modal, so — like dir:create — showModal IS
    // the ack and it must precede the generic defer below. Drive-gated + owner-bound.
    if (i.customId === 'dir:manual') {
      if (!host.authorize(i, 'drive')) return;
      await host.guarded(i, () => openManualPathModal(host, i));
      return;
    }

    // The 🖥️ native-panel button opens a folder picker ON THE HOST and waits for the
    // pick (can far exceed 3s) — deferUpdate now, jump the browser after. Drive-gated
    // + owner-bound. Handled before the generic wizard dispatch so the wizard state
    // machine never sees dir:panel.
    if (i.customId === 'dir:panel') {
      if (!host.authorize(i, 'drive')) return;
      if (!(await host.ackDeferUpdate(i))) return;
      if (!i.guildId) return;
      await host.guarded(i, () => handleFolderPanel(host, i));
      return;
    }

    // The "Resume Session" button and the resume flow's own selects (resume.*) drive a
    // separate resume state machine. Deferred-update first (listResumable/resume can
    // exceed 3s), then routed to the flow.
    if (i.customId === 'dir:resume' || i.customId.startsWith('resume.')) {
      if (!host.authorize(i, 'drive')) return;
      if (!(await host.ackDeferUpdate(i))) return;
      if (!i.guildId) return;
      await host.guarded(i, () => handleResumeComponent(host, i));
      return;
    }

    // The 💾 "save as preset" button on a completed wizard opens a name modal, and
    // showModal IS the ack — so, like dir:create, it must be handled BEFORE the generic
    // defer below (a deferred component can no longer show a modal). Gated on 'drive' only,
    // NOT owner-bound: the wizard was already deleted at done, so any drive user on this
    // channel can save the per-channel draft. A saved preset is then shared per-guild.
    if (i.customId === 'preset.save') {
      if (!host.authorize(i, 'drive')) return;
      await host.guarded(i, () => openPresetSaveModal(host, i));
      return;
    }

    // Otherwise it is a wizard component (folder/preset/backend/model/perm/confirm/cancel).
    // The preset-step selects/buttons (preset.pick / preset.direct / preset.delete) fall
    // through here too — they are just another step of the active wizard now — so no
    // separate preset routing is needed (only preset.save above is special, being a modal).
    // The wizard flow is a drive action; only the driver who opened it advances it.
    if (!host.authorize(i, 'drive')) return;
    // Acknowledge FIRST: the confirm step calls orchestrator.start (spawns an agent),
    // which can exceed 3s — deferUpdate now, do the work after.
    if (!(await host.ackDeferUpdate(i))) return;
    if (!i.guildId) return;
    const wKey = channelKey(i.guildId, i.channelId);
    // Serialize handle+editReply per channel so concurrent clicks cannot race the
    // state machine / re-render (stuck "Next" when two edits interleave).
    await host.enqueueWizard(wKey, () =>
      host.guarded(i, async () => {
        const wizard = host.wizards.get(wKey);
        // Enforce wizard ownership: a component from anyone other than the driver who
        // opened the wizard is acknowledged but ignored, so a bystander's stray select
        // cannot corrupt another driver's flow (§7.1).
        if (!wizard || wizard.ownerId !== i.user.id) return;
        const input: WizardInput = { id: i.customId, ...(i.value !== undefined ? { value: i.value } : {}) };
        const step = await wizard.handle(input);
        if (step === 'done' || step === 'cancelled') {
          host.wizards.delete(wKey);
        }
        // On a successful confirm the session was bound to a freshly created channel;
        // link it back to the driver (A4D-style "session started in <#newChannel>").
        if (step === 'done') {
          // A reconfigure (backend switch) popup restarts IN PLACE — no new channel and no
          // preset draft. Report the switch + the PUBLIC fresh-context warning (mirrors the
          // same-backend switchBackend path) and stop before the new-channel/preset logic (D6).
          if (wizard.isReconfigure()) {
            const backend = wizard.current().backend;
            await host.editWizardReply(i, { content: t('cmd.mode.switched', { backend }), embeds: [], components: [] });
            await safe(i.followUp({ content: t('cmd.mode.freshContext', { backend }), ephemeral: false }));
            return;
          }
          const newChannelId = wizard.sessionChannelId();
          if (newChannelId) {
            // Offer "💾 save as preset" ONLY for a NORMAL launch. A preset-launched wizard
            // records no draft and shows no button — you don't re-save what you launched
            // from. Capturing from current() at done (not at start) means each normal
            // completion records exactly what it just launched (no stale draft carries over).
            const fromPreset = wizard.launchedFromPreset();
            if (!fromPreset) {
              const s = wizard.current();
              const draft: PresetDraft = {
                backend: s.backend,
                model: s.model,
                effort: s.effort,
                permMode: s.permMode,
                profile: s.profile,
              };
              host.presetDrafts.set(wKey, draft);
              // Back the draft to state.json so the save button survives a restart. Deletion
              // on save success is wired in WO-3 alongside the save path. Best-effort: the
              // session already launched and the in-memory draft alone can back an in-session
              // save, so a backup write failure must not mask the channelCreated success notice.
              try {
                host.deps.stateStore.setPresetDraft(wKey, draft);
              } catch (err) {
                host.logError('preset draft backup failed', err);
              }
            }
            await host.editWizardReply(i, {
              content: t('cmd.start.channelCreated', { channel: `<#${newChannelId}>` }),
              embeds: [],
              components: fromPreset
                ? []
                : [{ components: [{ type: 'button', customId: 'preset.save', label: t('preset.save.button'), style: 'secondary' }] }],
            });
          }
          return;
        }
        // Every non-terminal transition re-renders the CURRENT step (folder → backend →
        // model → perm → confirm) and edits it into the wizard's message, so each step's
        // picker actually appears. A cancel renders the terminal notice with no rows. The
        // component was deferUpdate'd above, so editReply updates that same message.
        // Failures are logged + retried once (not swallowed by silent safe()).
        const { embed, rows } = wizard.render();
        await host.editWizardReply(i, { embeds: [embed], components: rows });
      }),
    );
  }

export async function openCreateFolderModal(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    const wizard = i.guildId ? host.wizards.get(channelKey(i.guildId, i.channelId)) : undefined;
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

export async function openManualPathModal(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    const wizard = i.guildId ? host.wizards.get(channelKey(i.guildId, i.channelId)) : undefined;
    if (!wizard || wizard.ownerId !== i.user.id) {
      await safe(i.deferUpdate());
      return;
    }
    await i.showModal({
      customId: 'dir:manual',
      title: t('dir.manual.title'),
      fields: [
        {
          customId: 'path',
          label: t('dir.manual.label'),
          placeholder: t('dir.manual.placeholder'),
          required: true,
        },
      ],
    });
  }

export async function handleFolderPanel(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    const pickFolder = host.deps.pickFolder;
    if (!pickFolder) return; // stale button from a host that no longer wires a picker
    const key = channelKey(i.guildId as string, i.channelId);
    const wizard = host.wizards.get(key);
    if (!wizard || wizard.ownerId !== i.user.id) return; // owner-bound; ignore strays
    if (host.folderPanels.has(key)) {
      await safe(i.followUp({ content: t('dir.panel.busy'), ephemeral: true }));
      return;
    }
    host.folderPanels.add(key);
    await safe(i.followUp({ content: t('dir.panel.wait'), ephemeral: true }));
    try {
      const picked = await pickFolder(wizard.browserCwd(), t('dir.panel.prompt'), host.folderPanelTimeoutMs);
      if (picked === null) {
        await safe(i.followUp({ content: t('dir.panel.cancelled'), ephemeral: true }));
        return;
      }
      if (!wizard.browserGoTo(picked)) {
        await safe(i.followUp({ content: t('dir.manual.invalid', { path: picked }), ephemeral: true }));
        return;
      }
      const { embed, rows } = wizard.render();
      await safe(i.editReply({ embeds: [embed], components: rows }));
      await safe(i.followUp({ content: t('dir.manual.done', { path: wizard.browserCwd() }), ephemeral: true }));
    } catch (err) {
      const timedOut = err instanceof Error && err.message === 'timeout';
      await safe(
        i.followUp({
          content: timedOut ? t('dir.panel.timeout') : t('dir.panel.error', { err: String(err) }),
          ephemeral: true,
        }),
      );
    } finally {
      host.folderPanels.delete(key);
    }
  }

export async function handleResumeComponent(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    const guildId = i.guildId as string;
    const key = channelKey(guildId, i.channelId);

    if (i.customId === 'dir:resume') {
      const wizard = host.wizards.get(key);
      if (!wizard || wizard.ownerId !== i.user.id) return; // owner-bound; ignore strays
      const flow = buildResumeWizard(host, guildId, i.channelId, i.user.id, wizard.browserCwd());
      host.resumeFlows.set(key, flow);
      const { embed, rows } = flow.render();
      await safe(i.editReply({ embeds: [embed], components: rows }));
      return;
    }

    // A resume.* select/button for an existing flow.
    const flow = host.resumeFlows.get(key);
    if (!flow || flow.ownerId !== i.user.id) return;
    const step = await flow.handle({ id: i.customId, ...(i.value !== undefined ? { value: i.value } : {}) });
    if (step === 'done' || step === 'cancelled' || step === 'empty') {
      host.resumeFlows.delete(key);
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

export function buildResumeWizard(host: InteractionRouterHost, guildId: string, channelId: string, ownerId: string, cwd: string) : ResumeWizard {
    const resolved = host.deps.configResolver.resolve(guildId, channelId);
    return new ResumeWizard({
      guildId,
      channelId,
      ownerId,
      cwd,
      backends: host.deps.modeRegistry.list(),
      defaultBackend: resolved.mode,
      listResumableFor: (backend, dir) => listResumableFor(host, backend, dir),
      resume: (params) => resumeSession(host, params),
      relativeTime,
    });
  }

export async function openPresetSaveModal(host: InteractionRouterHost, i: ComponentInteraction) : Promise<void> {
    const draft = i.guildId ? host.presetDrafts.get(channelKey(i.guildId, i.channelId)) : undefined;
    if (!draft) {
      await safe(i.reply({ content: t('preset.save.none'), ephemeral: true }));
      return;
    }
    const modal: ModalSpec = {
      customId: 'preset.name',
      title: t('preset.save.title'),
      fields: [
        {
          customId: 'name',
          label: t('preset.save.label'),
          placeholder: t('preset.save.placeholder'),
          required: true,
        },
      ],
    };
    try {
      await i.showModal(modal);
    } catch (err) {
      host.logError('preset save showModal failed; retrying once', err);
      await new Promise((r) => setTimeout(r, 200));
      await i.showModal(modal); // rethrow on second failure → guarded surfaces the error
    }
  }
