import type { ConfigStore } from '../core/config.js';
import type { ServerConfig } from '../core/configSchema.js';
import type { Logger } from '../core/contracts.js';

// A4D-style channel provisioning (§ init / session channels). This module owns the
// idempotent logic for creating the guild's channel STRUCTURE (a control channel +
// a sessions category) and for spinning up a per-project session channel on
// /agent start. discord.js is NOT imported here as a value: the guild's channel
// operations are behind the GuildChannelProvisioner port, which client.ts adapts
// onto a real discord.js Guild and tests drive with a fake. So this stays testable
// without a live gateway (mirrors the ports.ts / renderer seam).

// The narrow view of a created/reused channel the layer reads back.
export interface ProvisionedChannel {
  id: string;
  name: string;
}

// The channel operations the init/session flows need, all scoped to ONE guild. The
// client.ts adapter binds these to a discord.js Guild; every method resolves an
// existing channel by id when given (idempotency) and only creates when absent.
export interface GuildChannelProvisioner {
  // The guild these operations act on (surfaced for logging / summaries).
  readonly guildId: string;
  // True when the bot has the Manage Channels permission in this guild. Auto-provision
  // (ClientReady / GuildCreate) checks this FIRST and skips with a warning when false,
  // so a missing permission logs a clear notice instead of throwing a create error.
  canManageChannels(): boolean;
  // True when a channel with this id still exists in the guild (was not deleted).
  channelExists(id: string): boolean;
  // Reuse the category at `existingId` when it still exists, else create one named
  // `name`. Returns the resolved category channel.
  ensureCategory(name: string, existingId?: string): Promise<ProvisionedChannel>;
  // Reuse the text channel at `existingId` when it still exists, else create one
  // named `name` under `parentId` (a category). Returns the resolved text channel.
  ensureTextChannel(name: string, parentId: string, existingId?: string): Promise<ProvisionedChannel>;
  // Create a NEW text channel named `name` under `parentId` (when given). Used for
  // per-project session channels, which are always fresh (never reused).
  createTextChannel(name: string, parentId?: string): Promise<ProvisionedChannel>;
  // Rename an existing channel by id (used to migrate an already-provisioned control
  // channel to the current name). Best-effort at the adapter level; a missing channel
  // or a permission error resolves quietly so a rename never breaks provisioning.
  renameChannel(id: string, name: string): Promise<void>;
  // Delete a channel by id (used by /agent close to remove the session channel).
  // Best-effort at the adapter level; a missing channel is not an error.
  deleteChannel(id: string): Promise<void>;
}

// The persisted channel structure (mirrors ServerConfig.channels).
export type GuildChannels = NonNullable<ServerConfig['channels']>;

// Names for the created structure. Kept here (not in i18n) since they are Discord
// channel/category names, not localized bot messages — Discord lowercases/sanitizes
// text channel names itself, but we pass already-clean values.
const CONTROL_CATEGORY_NAME = '🤖 Agent';
const CONTROL_CHANNEL_NAME = 'session-generator';
const STATUS_CHANNEL_NAME = 'agent-status';
const SESSIONS_CATEGORY_NAME = 'Agent - Sessions';

// Idempotently create (or reuse) the guild's channel structure and persist the ids
// into servers/<guildId>.json. Re-running with an existing, still-valid structure
// reuses every channel (matched by stored id) instead of duplicating — the ids only
// change when a channel was deleted out from under us. Returns the resolved structure
// so the caller can post a summary / link the control channel.
export async function ensureGuildChannels(
  provisioner: GuildChannelProvisioner,
  configStore: ConfigStore,
): Promise<GuildChannels> {
  const guildId = provisioner.guildId;
  const server = configStore.loadServerConfig(guildId);
  const existing = server?.channels;

  // Reuse each stored id ONLY when the channel still exists; otherwise re-create it.
  const controlCategory = await provisioner.ensureCategory(
    CONTROL_CATEGORY_NAME,
    existing && provisioner.channelExists(existing.categoryId) ? existing.categoryId : undefined,
  );
  const controlChannel = await provisioner.ensureTextChannel(
    CONTROL_CHANNEL_NAME,
    controlCategory.id,
    existing && provisioner.channelExists(existing.controlChannelId) ? existing.controlChannelId : undefined,
  );
  // Migrate an already-provisioned control channel to the current name: a reused
  // channel keeps whatever name it had (e.g. an older 'agent-start'), so rename it in
  // place. Best-effort — a rename failure (missing permission) must not break the rest
  // of provisioning, so it is swallowed here (the adapter also swallows at its level).
  if (controlChannel.name !== CONTROL_CHANNEL_NAME) {
    await provisioner.renameChannel(controlChannel.id, CONTROL_CHANNEL_NAME).catch(() => {});
  }
  // The per-guild status channel (event notifications) lives under the SAME control
  // category, reusing its stored id when it still exists (mirrors controlChannelId).
  const statusChannel = await provisioner.ensureTextChannel(
    STATUS_CHANNEL_NAME,
    controlCategory.id,
    existing && existing.statusChannelId && provisioner.channelExists(existing.statusChannelId)
      ? existing.statusChannelId
      : undefined,
  );
  const sessionsCategory = await provisioner.ensureCategory(
    SESSIONS_CATEGORY_NAME,
    existing && provisioner.channelExists(existing.sessionsCategoryId) ? existing.sessionsCategoryId : undefined,
  );

  const channels: GuildChannels = {
    categoryId: controlCategory.id,
    controlChannelId: controlChannel.id,
    sessionsCategoryId: sessionsCategory.id,
    statusChannelId: statusChannel.id,
  };

  persistChannels(configStore, guildId, server, channels);
  return channels;
}

// Auto-provision a guild's channel structure without a manual /init. Called on
// ClientReady (for every existing guild) and on GuildCreate (a fresh invite), so the
// 🤖 Agent category + #session-generator control channel + Agent - Sessions category appear
// automatically. GUARDED and NON-THROWING by design: skips with a clear warning when
// the bot lacks Manage Channels, and swallows any create failure (a missing permission
// surfaces as a create error on some paths) so one bad guild never crashes the ready
// handler. Idempotent — reuses existing channels by stored id via ensureGuildChannels.
// Returns the resolved structure, or null when it could not provision.
export async function autoProvisionGuild(
  provisioner: GuildChannelProvisioner,
  configStore: ConfigStore,
  logger: Logger,
): Promise<GuildChannels | null> {
  if (!provisioner.canManageChannels()) {
    logger.warn('auto-provision skipped: missing Manage Channels permission', {
      guildId: provisioner.guildId,
    });
    return null;
  }
  try {
    const channels = await ensureGuildChannels(provisioner, configStore);
    logger.info('auto-provisioned guild channels', {
      guildId: provisioner.guildId,
      controlChannelId: channels.controlChannelId,
    });
    return channels;
  } catch (err) {
    logger.warn('auto-provision failed', {
      guildId: provisioner.guildId,
      err: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

// Create a dedicated session channel for a picked project folder, under the guild's
// sessions category (from /init) when available. The name is derived from the folder
// basename, sanitized to Discord's channel-name rules and prefixed `proj-`. Returns
// the new channel; the caller binds the session to its id.
export async function createSessionChannel(
  provisioner: GuildChannelProvisioner,
  folderPath: string,
  sessionsCategoryId?: string,
): Promise<ProvisionedChannel> {
  const name = sessionChannelName(folderPath);
  return provisioner.createTextChannel(name, sessionsCategoryId);
}

// Derive a Discord-safe session channel name from a folder path: `proj-<basename>`,
// lowercased, non-alphanumerics collapsed to '-', trimmed, and capped at Discord's
// 100-char channel-name limit. An empty/blank basename falls back to `proj-session`.
export function sessionChannelName(folderPath: string): string {
  const base = folderPath.replace(/[/\\]+$/, '').split(/[/\\]/).pop() ?? '';
  const slug = base
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  const name = slug.length > 0 ? `proj-${slug}` : 'proj-session';
  return name.slice(0, 100);
}

// Merge the resolved channel ids into servers/<guildId>.json without disturbing the
// server's other fields (auth / defaults / locale). A server file may not exist yet
// (first /init before any /config); create a minimal one carrying just the channels.
function persistChannels(
  configStore: ConfigStore,
  guildId: string,
  existing: ServerConfig | null,
  channels: GuildChannels,
): void {
  const next: ServerConfig = {
    version: existing?.version ?? 1,
    guildId,
    ...(existing?.auth ? { auth: existing.auth } : {}),
    ...(existing?.defaults ? { defaults: existing.defaults } : {}),
    ...(existing?.limits ? { limits: existing.limits } : {}),
    ...(existing?.locale ? { locale: existing.locale } : {}),
    ...(existing?.auditChannelId !== undefined ? { auditChannelId: existing.auditChannelId } : {}),
    ...(existing?.favorites ? { favorites: existing.favorites } : {}),
    channels,
  };
  configStore.saveServerConfig(next);
}
