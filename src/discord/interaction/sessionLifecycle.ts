import type { ModeSession, ResumableSession } from '../../core/contracts.js';
import type { StartParams } from '../../core/sessionOrchestrator.js';
import {
  createSessionChannel,
  type GuildChannels,
} from '../guildChannels.js';
import { buildStatusEmbed } from '../renderers/statusEmbed.js';
import { t } from '../i18n.js';
import type { InteractionRouterHost } from './types.js';

export async function startSession(host: InteractionRouterHost, params: StartParams) : Promise< { session: ModeSession; channelId: string }> {
    const channelId = await resolveSessionChannelId(host, params);
    const session = await startInChannel(host, { ...params, channelId });
    await postSessionIntro(host, channelId, params, session);
    return { session, channelId };
  }

export async function startInChannel(host: InteractionRouterHost, params: StartParams) : Promise<ModeSession> {
    const session = await host.deps.orchestrator.start(params);
    await host.deps.wiring.attach(params.guildId, params.channelId, params.mode);
    return session;
  }

export async function switchSession(host: InteractionRouterHost, params: StartParams) : Promise< { session: ModeSession; channelId: string }> {
    await host.deps.orchestrator.stop(params.guildId, params.channelId);
    host.deps.wiring.detach(params.guildId, params.channelId);
    const session = await startInChannel(host, { ...params });
    return { session, channelId: params.channelId };
  }

export async function resolveSessionChannelId(host: InteractionRouterHost, params: StartParams) : Promise<string> {
    const provisioner = host.deps.resolveGuildProvisioner
      ? await host.deps.resolveGuildProvisioner(params.guildId)
      : null;
    if (!provisioner) return params.channelId;
    const channels = guildChannels(host, params.guildId);
    const created = await createSessionChannel(provisioner, params.cwd, channels?.sessionsCategoryId);
    return created.id;
  }

export function guildChannels(host: InteractionRouterHost, guildId: string) : GuildChannels | undefined {
    return host.deps.configStore.loadServerConfig(guildId)?.channels;
  }

export async function postSessionIntro(host: InteractionRouterHost, channelId: string, params: StartParams, session: ModeSession) : Promise<void> {
    const resolve = host.deps.resolveChannel;
    if (!resolve) return;
    try {
      const channel = await resolve(channelId);
      if (!channel) return;
      const usagePanel = host.deps.modeRegistry.has(params.mode)
        ? host.deps.modeRegistry.get(params.mode).capabilities.usagePanel
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
      host.logError('failed to post session intro', err);
    }
  }

export async function deleteSessionChannel(host: InteractionRouterHost, guildId: string, channelId: string) : Promise<void> {
    const channels = guildChannels(host, guildId);
    if (channels && channelId === channels.controlChannelId) return;
    const provisioner = host.deps.resolveGuildProvisioner
      ? await host.deps.resolveGuildProvisioner(guildId)
      : null;
    if (!provisioner) return;
    try {
      await provisioner.deleteChannel(channelId);
    } catch (err) {
      host.logError('failed to delete session channel', err);
    }
  }

export async function listResumableFor(host: InteractionRouterHost, backend: string, cwd: string) : Promise<ResumableSession[]> {
    if (!host.deps.modeRegistry.has(backend)) return [];
    const mode = host.deps.modeRegistry.get(backend);
    if (!mode.listResumable) return [];
    try {
      const ctx = host.deps.orchestrator.buildListContext(backend, cwd);
      return await mode.listResumable(ctx);
    } catch (err) {
      host.logError('listResumable failed', err);
      return [];
    }
  }


export async function resumeSession(
  host: InteractionRouterHost,
  params: {
    guildId: string;
    channelId: string;
    ownerId: string;
    backend: string;
    cwd: string;
    sessionId: string;
  },
): Promise<{ session: ModeSession; channelId: string }> {
    const startParams: StartParams = {
      guildId: params.guildId,
      channelId: await resolveSessionChannelId(host, {
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
    const session = await host.deps.orchestrator.resume(startParams, params.sessionId);
    await host.deps.wiring.attach(startParams.guildId, startParams.channelId, startParams.mode);
    await postResumeIntro(host, startParams.channelId, startParams, session);
    return { session, channelId: startParams.channelId };
  }

export async function postResumeIntro(host: InteractionRouterHost, channelId: string, params: StartParams, session: ModeSession) : Promise<void> {
    const resolve = host.deps.resolveChannel;
    if (!resolve) return;
    try {
      const channel = await resolve(channelId);
      if (!channel) return;
      const usagePanel = host.deps.modeRegistry.has(params.mode)
        ? host.deps.modeRegistry.get(params.mode).capabilities.usagePanel
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
      host.logError('failed to post resume intro', err);
    }
  }
