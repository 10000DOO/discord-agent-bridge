import * as fs from 'node:fs';
import * as path from 'node:path';
import { t } from '../i18n.js';
import { channelKey, safe, isSafeFolderName } from './helpers.js';
import type { AckPayload, InteractionRouterHost, ModalSubmitInteraction } from './types.js';

export async function handleModalSubmit(host: InteractionRouterHost, i: ModalSubmitInteraction) : Promise<void> {
    if (i.customId === 'dir:create') {
      await host.guarded(i, () => handleCreateFolderModal(host, i));
      return;
    }
    if (i.customId === 'dir:manual') {
      await host.guarded(i, () => handleManualPathModal(host, i));
      return;
    }
    // The "save as preset" name modal submit persists the captured draft under the typed
    // name (its own 3s window — reply as usual).
    if (i.customId === 'preset.name') {
      await host.guarded(i, () => savePresetFromModal(host, i));
      return;
    }
    await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
  }

export async function handleCreateFolderModal(host: InteractionRouterHost, i: ModalSubmitInteraction) : Promise<void> {
    if (!i.guildId) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    const wizard = host.wizards.get(channelKey(i.guildId, i.channelId));
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

export async function handleManualPathModal(host: InteractionRouterHost, i: ModalSubmitInteraction) : Promise<void> {
    if (!i.guildId) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    const wizard = host.wizards.get(channelKey(i.guildId, i.channelId));
    if (!wizard || wizard.ownerId !== i.user.id) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    const input = i.getField('path').trim();
    if (!input || !path.isAbsolute(input)) {
      await safe(i.reply({ content: t('dir.manual.notabs'), ephemeral: true }));
      return;
    }
    if (!wizard.browserGoTo(input)) {
      await safe(i.reply({ content: t('dir.manual.invalid', { path: input }), ephemeral: true }));
      return;
    }
    const { embed, rows } = wizard.render();
    await safe(i.reply({ content: t('dir.manual.done', { path: wizard.browserCwd() }), embeds: [embed], components: rows, ephemeral: true }));
  }

export async function savePresetFromModal(host: InteractionRouterHost, i: ModalSubmitInteraction) : Promise<void> {
    // Not deferred yet: gate failures reply directly (best-effort, interaction still unacked).
    if (!i.guildId) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    const key = channelKey(i.guildId, i.channelId);
    const draft = host.presetDrafts.get(key);
    if (!draft) {
      await safe(i.reply({ content: t('preset.save.none'), ephemeral: true }));
      return;
    }
    const name = i.getField('name').trim();
    if (name.length === 0 || name.length > 100) {
      await safe(i.reply({ content: t('cmd.error.generic'), ephemeral: true }));
      return;
    }
    let payload: AckPayload;
    try {
      host.deps.configStore.addServerPreset(i.guildId, {
        name,
        backend: draft.backend,
        ...(draft.model !== undefined ? { model: draft.model } : {}),
        ...(draft.effort !== undefined ? { effort: draft.effort } : {}),
        ...(draft.permMode !== undefined ? { permMode: draft.permMode } : {}),
        ...(draft.profile !== undefined ? { profile: draft.profile } : {}),
      });
      // Config is source of truth: drop the draft (memory + state backup) after a
      // successful persist so a retry cannot double-save.
      host.presetDrafts.delete(key);
      host.deps.stateStore.deletePresetDraft(key);
      host.deps.logger.info('preset saved', { guildId: i.guildId, name });
      payload = { content: t('preset.saved', { name }), ephemeral: true };
    } catch (err) {
      // Persist failed — keep the draft so a retry can still save.
      host.logError('preset save failed', err);
      payload = { content: t('cmd.error', { error: String(err) }), ephemeral: true };
    }
    // Best-effort notification: a response failure must not undo the persisted save.
    await safe(i.acknowledged ? i.editReply(payload) : i.reply(payload));
  }
