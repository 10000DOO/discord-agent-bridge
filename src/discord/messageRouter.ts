import * as fs from 'node:fs';
import * as path from 'node:path';
import type { AgentEvent, TurnInput } from '../core/contracts.js';
import type { Logger } from '../core/contracts.js';
import type { Authorizer } from '../core/auth.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { EventBus } from '../core/eventBus.js';
import type { SessionOrchestrator } from '../core/sessionOrchestrator.js';
import { t } from './i18n.js';

// MessageCreate → TurnInput (§4, §7.1, §9 step 2). The client already drops bot
// messages; this router:
//   1. looks up the channel binding (key guildId:channelId); no binding → ignore.
//   2. calls authorize({action:'drive'}) FIRST — a denied user never reaches the
//      mode; they get an ephemeral notice and nothing is sent (fixes A1).
//   3. downloads attachments INTO the session workspace (confined) and builds the
//      TurnInput; the orchestrator re-validates confinement as defense in depth.
//   4. orchestrator.send(...) and reacts ⏳ on the user's message to signal "the AI
//      is preparing a response". The reaction is CLEARED when that channel's turn
//      finishes: on the session's `result` event the ⏳ is removed and ✅ added; on
//      an `error` event ⏳ is removed and ❌ added. The clear is wired via a one-shot
//      EventBus listener for the channel (the same bus the renderers subscribe to),
//      so the indicator tracks the actual turn lifecycle, not just acceptance.
//
// discord.js is NOT imported here as a value: the router accepts a narrow
// IncomingMessage shape that the real discord.js Message satisfies structurally,
// so unit tests drive it with a fake. Isolating the type keeps the seam thin.

// Directory (relative to the session cwd) attachments are downloaded into. Staying
// under cwd means the orchestrator's realpath confinement accepts them.
const ATTACHMENT_DIR = '.dab-attachments';

// The narrow view of a discord.js Message the router reads. The real Message
// satisfies this; tests pass a plain object.
export interface IncomingAttachment {
  url: string;
  name: string | null;
  contentType?: string | null;
}

export interface IncomingMessage {
  content: string;
  guildId: string | null;
  channelId: string;
  author: { id: string; bot: boolean };
  // The acting member's role ids (from message.member.roles.cache.map(r => r.id))
  // plus their Administrator permission bit. Absent in DMs; the router treats that as
  // no roles (deny by fail-secure auth). `permissions.has` is the discord.js
  // GuildMember.permissions PermissionsBitField; the client passes the Administrator
  // bit so a server admin can drive a session by messaging, never locked out (§7.1).
  member: {
    roles: { cache: { map: (fn: (r: { id: string }) => string) => string[] } };
    permissions?: { has: (bit: bigint) => boolean };
  } | null;
  attachments: { values: () => Iterable<IncomingAttachment> };
  // Add a subtle reaction to signal the AI is preparing a response. Best-effort; a
  // failure is swallowed so a missing Add-Reactions permission never breaks a turn.
  react: (emoji: string) => Promise<unknown>;
  // Remove one of the BOT's own reactions from this message (used to clear ⏳ on
  // completion). Optional so a test double need not implement it; the client.ts
  // adapter maps it onto message.reactions. Best-effort — a failure is swallowed.
  removeReaction?: (emoji: string) => Promise<unknown>;
  // Ephemeral notice back to the actor. In a real channel this posts a normal
  // reply (channels have no true ephemeral); tests assert it was called.
  reply: (content: string) => Promise<unknown>;
}

// Fetches attachment bytes; injectable so tests avoid the network. Defaults to
// global fetch → ArrayBuffer.
export type FetchBytes = (url: string) => Promise<Uint8Array>;

const defaultFetchBytes: FetchBytes = async (url) => {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`attachment download failed: ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
};

export interface MessageRouterDeps {
  authorizer: Authorizer;
  channelRegistry: ChannelRegistry;
  orchestrator: SessionOrchestrator;
  // The per-channel AgentEvent stream. The router subscribes a one-shot listener
  // per accepted turn to CLEAR the ⏳ indicator when the channel's turn finishes
  // (result → ✅, error → ❌). Optional so a test that only checks the initial
  // reaction need not supply it; when absent, ⏳ is added but never auto-cleared.
  eventBus?: EventBus;
  logger: Logger;
  fetchBytes?: FetchBytes;
  // The Discord Administrator permission bit (discord.js PermissionFlagsBits.
  // Administrator). Injected so the router stays discord.js-free: it checks the
  // acting member's permissions.has(bit) to grant the admin tier to server admins.
  // App boot wires it from discord.js; defaults to the well-known value (1<<3).
  administratorBit?: bigint;
  // Called after orchestrator.send accepts a turn (running or queued). App boot
  // wires this to SessionWiring.armIdleWatchdog so a ~3 min idle notice can fire
  // if the agent goes silent. Optional so existing tests need not supply it.
  onTurnAccepted?: (guildId: string, channelId: string) => void;
}

// Reaction emoji lifecycle: ⏳ while the AI is preparing a response (added when the
// turn is accepted, whether it runs immediately or is queued), then CLEARED on
// completion — replaced by ✅ on a successful `result` or ❌ on an `error`.
const REACT_WORKING = '⏳';
const REACT_DONE = '✅';
const REACT_ERROR = '❌';

// The Discord Administrator permission bit (PermissionFlagsBits.Administrator === 1<<3).
// Used as the default so a caller need not inject it; app boot passes the discord.js
// constant explicitly to stay authoritative if the value ever changes.
const ADMINISTRATOR_BIT = 1n << 3n;

export class MessageRouter {
  private readonly authorizer: Authorizer;
  private readonly channelRegistry: ChannelRegistry;
  private readonly orchestrator: SessionOrchestrator;
  private readonly eventBus?: EventBus;
  private readonly logger: Logger;
  private readonly fetchBytes: FetchBytes;
  private readonly administratorBit: bigint;
  private readonly onTurnAccepted?: (guildId: string, channelId: string) => void;

  constructor(deps: MessageRouterDeps) {
    this.authorizer = deps.authorizer;
    this.channelRegistry = deps.channelRegistry;
    this.orchestrator = deps.orchestrator;
    this.eventBus = deps.eventBus;
    this.logger = deps.logger;
    this.fetchBytes = deps.fetchBytes ?? defaultFetchBytes;
    this.administratorBit = deps.administratorBit ?? ADMINISTRATOR_BIT;
    this.onTurnAccepted = deps.onTurnAccepted;
  }

  async handle(message: IncomingMessage): Promise<void> {
    if (message.author.bot) return; // defensive: client already filters bots
    const { guildId, channelId } = message;
    if (guildId === null) return; // DMs are not channel-bound sessions here

    // Only messages in a channel bound to an active session are turns.
    const binding = this.channelRegistry.get(guildId, channelId);
    if (!binding || binding.archived) return;

    // AUTH GATE (§7.1) — before anything reaches the mode.
    const roleIds = message.member ? message.member.roles.cache.map((r) => r.id) : [];
    // A server admin can drive a session by messaging even with an empty role config
    // (never locked out): read the Administrator bit off the member's permissions. A
    // read failure or absent permissions → not an admin (fail-secure).
    const isAdministrator = this.memberIsAdministrator(message.member);
    const decision = this.authorizer.authorize({
      userId: message.author.id,
      roleIds,
      action: 'drive',
      context: { guildId, channelId },
      ...(isAdministrator ? { isAdministrator: true } : {}),
    });
    if (!decision.allowed) {
      await safe(message.reply(t('auth.denied', { reason: decision.reason ?? '' })));
      return;
    }

    // Build the TurnInput: text + attachments confined into the workspace.
    let files: TurnInput['files'];
    try {
      files = await this.downloadAttachments(binding.cwd, [...message.attachments.values()]);
    } catch (err) {
      this.logger.error('attachment download failed', { guildId, channelId, err: String(err) });
      await safe(message.reply(t('cmd.error', { error: String(err) })));
      return;
    }

    const turn: TurnInput = { text: message.content, ...(files && files.length > 0 ? { files } : {}) };

    try {
      await this.orchestrator.send(guildId, channelId, turn);
    } catch (err) {
      // The orchestrator throws on no-session or a confinement violation; surface it.
      await safe(message.reply(t('cmd.error', { error: String(err) })));
      return;
    }

    // The turn was accepted (running now or queued behind one in flight): arm the
    // idle watchdog (if wired), signal "the AI is preparing a response" with ⏳,
    // then arm a one-shot listener to clear it when the channel's turn finishes.
    this.onTurnAccepted?.(guildId, channelId);
    await safe(message.react(REACT_WORKING));
    this.armCompletionIndicator(guildId, channelId, message);
  }

  // Subscribe a one-shot EventBus listener for the channel that clears the ⏳ working
  // indicator on the turn's terminal event: a `result` swaps ⏳→✅, an `error` swaps
  // ⏳→❌. It unsubscribes itself after the first terminal event so it tracks exactly
  // one turn's message. No eventBus wired → the ⏳ simply stays (best-effort UX). All
  // reaction ops go through safe() so a missing Manage-Messages/Add-Reactions
  // permission never breaks the turn.
  private armCompletionIndicator(guildId: string, channelId: string, message: IncomingMessage): void {
    if (!this.eventBus) return;
    const unsubscribe = this.eventBus.on(guildId, channelId, (ev: AgentEvent) => {
      if (ev.kind !== 'result' && ev.kind !== 'error') return;
      unsubscribe();
      void this.clearWorkingIndicator(message, ev.kind === 'result' ? REACT_DONE : REACT_ERROR);
    });
  }

  // Remove the ⏳ working reaction and add the terminal one (✅/❌). Best-effort:
  // removeReaction may be absent (a bare test double) or fail (missing permission);
  // either way the terminal reaction is still attempted and nothing is thrown.
  private async clearWorkingIndicator(message: IncomingMessage, terminal: string): Promise<void> {
    if (message.removeReaction) await safe(message.removeReaction(REACT_WORKING));
    await safe(message.react(terminal));
  }

  // True when the acting member holds the Discord Administrator permission. Reads the
  // bit off member.permissions (a discord.js PermissionsBitField). Any absent field or
  // read error → false (fail-secure): a bad permissions shape must never grant admin.
  private memberIsAdministrator(member: IncomingMessage['member']): boolean {
    try {
      const perms = member?.permissions;
      return perms !== undefined && perms.has(this.administratorBit);
    } catch {
      return false;
    }
  }

  // Download each attachment under cwd/.dab-attachments so the orchestrator's
  // realpath confinement accepts it. The attachment dir is realpath-confined to the
  // workspace BEFORE any write (mirroring fileDownload): a pre-planted symlink at
  // cwd/.dab-attachments pointing outside the workspace is rejected, so attacker
  // bytes can never be redirected outside cwd. The per-file destination is confined
  // too, so a resolved name can never escape the confined dir either.
  private async downloadAttachments(
    cwd: string,
    attachments: IncomingAttachment[],
  ): Promise<TurnInput['files']> {
    if (attachments.length === 0) return undefined;
    const root = realpathOrResolve(cwd);
    const dir = confineWithin(root, path.join(root, ATTACHMENT_DIR));
    fs.mkdirSync(dir, { recursive: true });
    // Re-confine the dir AFTER mkdir: if it (or an ancestor) is a symlink out of the
    // workspace, its realpath now resolves and must still be inside the root.
    confineWithin(root, dir);
    const files: NonNullable<TurnInput['files']> = [];
    for (const att of attachments) {
      const name = sanitizeName(att.name ?? 'attachment');
      const dest = confineWithin(root, path.join(dir, name));
      const bytes = await this.fetchBytes(att.url);
      fs.writeFileSync(dest, bytes);
      files.push({ path: dest, ...(att.contentType ? { mime: att.contentType } : {}) });
    }
    return files;
  }
}

// Realpath a path, falling back to the realpath of its deepest existing ancestor
// joined with the non-existent tail — so confinement holds for paths that do not
// exist yet while still resolving symlinks in the part that does. (Same approach as
// fileDownload.realpathOrResolve; duplicated locally to keep this a self-contained
// router without a cross-file helper import.)
function realpathOrResolve(target: string): string {
  const abs = path.resolve(target);
  let existing = abs;
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break;
    tail.unshift(path.basename(existing));
    existing = parent;
  }
  try {
    const realExisting = fs.realpathSync(existing);
    return tail.length > 0 ? path.join(realExisting, ...tail) : realExisting;
  } catch {
    return abs;
  }
}

// Realpath-confine `candidate` to `root`; return the resolved path or throw when it
// escapes. `root` is expected to already be realpath-resolved.
function confineWithin(root: string, candidate: string): string {
  const resolved = realpathOrResolve(candidate);
  const rel = path.relative(root, resolved);
  if (rel !== '' && (rel.startsWith('..') || path.isAbsolute(rel))) {
    throw new Error(`Attachment path escapes the workspace: ${candidate}`);
  }
  return resolved;
}

// Reduce a Discord attachment filename to a safe basename (no path separators, no
// traversal) so a crafted name cannot write outside the attachment directory.
function sanitizeName(name: string): string {
  const base = path.basename(name).replace(/[/\\]/g, '_');
  return base.length > 0 && base !== '.' && base !== '..' ? base : 'attachment';
}

// Swallow a best-effort side-effect (reaction / reply) so a missing permission or
// transient error never propagates out of the router.
async function safe(p: Promise<unknown>): Promise<void> {
  try {
    await p;
  } catch {
    // best-effort
  }
}
