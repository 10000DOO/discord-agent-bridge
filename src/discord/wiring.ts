import { execFile } from 'node:child_process';
import type { Client } from 'discord.js';
import type { AgentEvent, Logger, PermissionDecision } from '../core/contracts.js';
import type { EventBus } from '../core/eventBus.js';
import type { ModeRegistry } from '../core/modeRegistry.js';
import type { UsageResult, UsageService } from '../core/usageService.js';
import { codexUsageUnavailable } from '../core/usageService.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { AuditLog } from '../core/auditLog.js';
import type { PermissionRequest } from '../core/sessionOrchestrator.js';
import { RendererDispatcher, createDefaultRendererSet, type RendererSet } from './renderers/index.js';
import type { UsageSessionMeta } from './renderers/usageEmbed.js';
import { PermissionButtonsHandler, parseCustomId } from './renderers/permissionButtons.js';
import { ChannelAdapter, resolveChannelAdapter } from './client.js';
import type { MessageChannel } from './ports.js';
import type { ConfigStore } from '../core/config.js';
import { SessionNotifier, resolveNotifications } from './notifier.js';

// The deferred 7a hookups, wired live (§7A/§6/§7.5). Per active channel this owns:
//   - a RendererDispatcher subscribed to the eventBus (AgentEvents → Discord), with
//     the capability set of that channel's mode; unsubscribed on stop.
//   - a PermissionButtonsHandler: orchestrator.requestPermission posts Allow/Always/
//     Deny and the returned promise resolves when the button interaction settles.
//     The permission timeout (limits.permissionTimeoutSec) denies on expiry; a value
//     of 0 or less means "no timer, wait indefinitely" so slow responders are not
//     auto-denied.
//   - the sendFile callback (mcpFileTool → post the confined file to the channel).
//   - usage snapshot feeding the usageEmbed (Claude only; Codex → unavailable line).
//
// discord.js is confined to client.ts adapters; this module resolves a channel to
// a MessageChannel port via resolveChannelAdapter and everything else is port-level.

// One channel's live wiring: its renderer subscription unsubscribe, its renderer
// set (for dispose() on detach), its permission handler, the channel sink, and — when
// per-guild notifications are enabled with a resolvable status channel — the notifier
// subscription's unsubscribe (torn down alongside the renderer subscription on detach).
interface ChannelWiring {
  unsubscribe: () => void;
  renderers: RendererSet;
  permission: PermissionButtonsHandler;
  channel: MessageChannel;
  mode: string;
  unsubscribeNotifier?: () => void;
}

// Who/where an always-allow was granted from, so the wiring can audit the GLOBAL
// config write with the actor that triggered it (§7.5).
export interface AlwaysAllowContext {
  actorId: string;
  guildId: string;
  channelId: string;
}

export interface SessionWiringDeps {
  eventBus: EventBus;
  modeRegistry: ModeRegistry;
  channelRegistry: ChannelRegistry;
  usageService: UsageService;
  logger: Logger;
  // Per-server config source, read at attach() to resolve a guild's notifications
  // settings (enabled/channelId/events). Optional so tests that do not exercise
  // notifications need not supply it; when absent, no notifier is wired.
  configStore?: ConfigStore;
  // Append-only audit trail (§7.5). The always-allow persistence path records a
  // who/when/what entry around the GLOBAL config write. Optional so tests that do
  // not exercise always-allow need not supply it.
  auditLog?: AuditLog;
  // Resolve a channelId to a sink. Defaults to resolveChannelAdapter over the live
  // client; injectable so tests supply a fake channel without a gateway.
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
  // Permission-request timeout in seconds (config limits.permissionTimeoutSec).
  // 0 or negative → no timer, the prompt waits indefinitely for a button click.
  permissionTimeoutSec: number;
  // Persist an "always-allow" tool so future turns auto-allow it (§7A). Called
  // when a permission button resolves as `always`, with the actor/channel context
  // for the surrounding audit record. App boot wires this to the ConfigStore's
  // global autoAllowClaudeTools set. Optional so tests that do not exercise
  // always-allow need not supply it.
  onAlwaysAllow?: (toolName: string, ctx: AlwaysAllowContext) => void;
}

function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

// Current git branch of a session cwd — the same probe claude-hud runs
// (`git rev-parse --abbrev-ref HEAD`, short timeout). Resolves null on ANY
// failure (not a repo, git missing, bad cwd, timeout) so the panel simply
// omits the branch; never rejects.
function gitBranch(cwd: string): Promise<string | null> {
  return new Promise((resolve) => {
    execFile('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd, timeout: 1000 }, (err, stdout) => {
      if (err) return resolve(null);
      const branch = stdout.trim();
      resolve(branch.length > 0 ? branch : null);
    });
  });
}

export class SessionWiring {
  private readonly eventBus: EventBus;
  private readonly modeRegistry: ModeRegistry;
  private readonly channelRegistry: ChannelRegistry;
  private readonly usageService: UsageService;
  private readonly logger: Logger;
  // Mutable so app boot can bind it to the live gateway AFTER the client is
  // constructed (the client depends on the routers which depend on this wiring —
  // resolveChannel is only used at attach()/sendFile time, i.e. after login).
  private resolveChannel: (channelId: string) => Promise<MessageChannel | null>;
  private readonly permissionTimeoutMs: number;
  private readonly auditLog?: AuditLog;
  private readonly configStore?: ConfigStore;
  private readonly onAlwaysAllow?: (toolName: string, ctx: AlwaysAllowContext) => void;

  private readonly channels = new Map<string, ChannelWiring>();

  constructor(deps: SessionWiringDeps) {
    this.eventBus = deps.eventBus;
    this.modeRegistry = deps.modeRegistry;
    this.channelRegistry = deps.channelRegistry;
    this.usageService = deps.usageService;
    this.logger = deps.logger;
    this.auditLog = deps.auditLog;
    this.configStore = deps.configStore;
    this.resolveChannel = deps.resolveChannel ?? (() => Promise.resolve(null));
    // 0 sentinel means "no timer" (infinite wait); withTimeout skips the setTimeout
    // path so a slow-to-respond operator is not auto-denied.
    this.permissionTimeoutMs = deps.permissionTimeoutSec > 0 ? deps.permissionTimeoutSec * 1000 : 0;
    this.onAlwaysAllow = deps.onAlwaysAllow;
  }

  // Build the live resolveChannel over a real gateway client (used by app boot).
  static resolveOverClient(client: Client): (channelId: string) => Promise<MessageChannel | null> {
    return (channelId: string): Promise<MessageChannel | null> =>
      resolveChannelAdapter(client, channelId) as Promise<ChannelAdapter | null>;
  }

  // Bind (or rebind) the channel resolver. App boot calls this once the gateway
  // client exists to point the wiring at the live client's channel lookup.
  setResolveChannel(resolveChannel: (channelId: string) => Promise<MessageChannel | null>): void {
    this.resolveChannel = resolveChannel;
  }

  // The orchestrator's requestPermission hook (§7.5): post the buttons on the bound
  // channel's permission handler and await the decision, denying on timeout. If the
  // channel is not wired yet (renderers not attached) fall back to deny — a prompt
  // the operator can never see must never auto-allow.
  requestPermission = async (
    binding: { guildId: string; channelId: string; ownerId: string },
    req: PermissionRequest,
  ): Promise<PermissionDecision> => {
    const wiring = this.channels.get(channelKey(binding.guildId, binding.channelId));
    if (!wiring) {
      return { behavior: 'deny', message: 'No live channel to prompt; denied.' };
    }
    // The reqId is embedded in the button custom_id `perm:<reqId>:<action>`, which
    // parseCustomId splits on ':' — so the id itself MUST NOT contain a colon.
    const id = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    const ev: Extract<AgentEvent, { kind: 'permission_request' }> = {
      kind: 'permission_request',
      id,
      toolName: req.toolName,
      input: req.input,
    };
    // Bind the prompt to the session owner (driver): only they may resolve it, so a
    // bystander in the channel cannot approve another driver's tool (§7.1/§7.5).
    const decision = wiring.permission.request(ev, binding.ownerId);
    return this.withTimeout(decision, id, wiring);
  };

  // Resolve a `perm:<reqId>:<action>` button for a channel. `actorId` is the Discord
  // user who clicked; the prompt is bound to the session owner, so an actor other
  // than the owner is ignored (resolve returns null, prompt stays pending). Returns
  // the applied decision, or null when the id is foreign/unknown or the actor is not
  // the approver (safe on any interaction).
  async resolvePermission(
    guildId: string,
    channelId: string,
    customId: string,
    actorId?: string,
  ): Promise<PermissionDecision | null> {
    const wiring = this.channels.get(channelKey(guildId, channelId));
    if (!wiring) return null;
    // When the action is "always-allow", read the tool name BEFORE resolve()
    // removes the pending entry, then persist it into the config auto-allow set so
    // future turns skip the prompt (§7A). resolve() itself still settles the turn's
    // decision as a plain allow (permissionButtons.resolve).
    const parsed = parseCustomId(customId);
    const alwaysTool =
      parsed?.action === 'always' ? wiring.permission.peekToolName(parsed.reqId) : null;
    const decision = await wiring.permission.resolve(customId, actorId);
    if (alwaysTool && decision?.behavior === 'allow') {
      // Audit the GLOBAL always-allow write (§7.5) around the persistence: record
      // the actor, tool, and channel so the who/when/what of an always-allow is
      // durable even though the config write itself is best-effort. The audit and
      // the persist are independently guarded so neither failure breaks the turn
      // (already allowed) nor the other side effect.
      this.auditAlwaysAllow(actorId ?? '', guildId, channelId, alwaysTool);
      try {
        this.onAlwaysAllow?.(alwaysTool, { actorId: actorId ?? '', guildId, channelId });
      } catch (err) {
        // Persisting the always-allow set is best-effort; a config write failure
        // must not break the interaction (the turn is already allowed).
        this.logger.warn('failed to persist always-allow tool', { tool: alwaysTool, err: String(err) });
      }
    }
    return decision;
  }

  // Record an always-allow grant to the audit trail. Best-effort: AuditLog.record
  // never throws, but the whole call is still guarded so an absent/failing audit
  // sink never breaks the interaction.
  private auditAlwaysAllow(actorId: string, guildId: string, channelId: string, tool: string): void {
    if (!this.auditLog) return;
    try {
      this.auditLog.record({
        actorId,
        roleTier: 'execute',
        guildId,
        channelId,
        action: 'always-allow',
        tool,
        status: 'allowed',
      });
    } catch (err) {
      this.logger.warn('failed to audit always-allow', { tool, err: String(err) });
    }
  }

  // Attach renderers + permission handler for a channel that just started/resumed.
  // Idempotent: re-attaching first tears down any prior subscription so a resume
  // after a restart does not double-render.
  async attach(guildId: string, channelId: string, mode: string): Promise<void> {
    const key = channelKey(guildId, channelId);
    this.detach(guildId, channelId);

    const channel = await this.resolveChannel(channelId);
    if (!channel) {
      this.logger.warn('cannot wire renderers: channel unresolved', { guildId, channelId });
      return;
    }
    const binding = this.channelRegistry.get(guildId, channelId);
    const ownerId = binding?.ownerId ?? '';
    const capabilities = this.modeRegistry.get(mode).capabilities;

    const permission = new PermissionButtonsHandler({ channel });
    const rendererSet = createDefaultRendererSet({
      channel,
      ownerId,
      getUsage: () => this.getUsageFor(mode),
      getSessionMeta: () => this.getSessionMetaFor(guildId, channelId),
      logger: this.logger,
    });
    // The dispatcher's permission renderer posts buttons via its own handler; we
    // want the SAME handler instance the router resolves against, so route the
    // permission event through our shared handler instead of the set's private one.
    const set = { ...rendererSet, permission: (ev: Extract<AgentEvent, { kind: 'permission_request' }>) => { void permission.request(ev).catch(() => {}); } };
    const dispatcher = new RendererDispatcher(set, capabilities);
    const unsubscribe = dispatcher.subscribe(this.eventBus, guildId, channelId);

    // When per-guild notifications are enabled and a status channel resolves, also
    // subscribe a notifier that forwards this session's key events (result/error;
    // tool_use if enabled) to that status channel as compact summary lines. Skipped
    // when disabled, no resolvable status channel, or the session channel IS the
    // status channel (self-echo). Best-effort: a resolve failure never breaks attach.
    const unsubscribeNotifier = await this.attachNotifier(guildId, channelId, mode);

    this.channels.set(key, {
      unsubscribe,
      renderers: set,
      permission,
      channel,
      mode,
      ...(unsubscribeNotifier ? { unsubscribeNotifier } : {}),
    });
  }

  // Resolve the guild's notifications config + status channel and, when enabled with a
  // resolvable status channel that is NOT this session channel, subscribe a SessionNotifier
  // to this channel's event stream. Returns the notifier's unsubscribe, or null when no
  // notifier was wired. Never throws — a resolve/config error just skips notifications.
  private async attachNotifier(guildId: string, channelId: string, mode: string): Promise<(() => void) | null> {
    if (!this.configStore) return null;
    try {
      const server = this.configStore.loadServerConfig(guildId);
      const notifications = resolveNotifications(server);
      if (!notifications.enabled || !notifications.channelId) return null;
      // Self-echo guard: never forward a channel's events into itself.
      if (notifications.channelId === channelId) return null;
      const statusChannel = await this.resolveChannel(notifications.channelId);
      if (!statusChannel) return null;
      const notifier = new SessionNotifier({
        statusChannel,
        sessionChannelId: channelId,
        events: notifications.events,
        getUsage: () => this.getUsageFor(mode),
      });
      return notifier.subscribe(this.eventBus, guildId, channelId);
    } catch (err) {
      this.logger.warn('failed to wire notifier', { guildId, channelId, err: String(err) });
      return null;
    }
  }

  // Tear down a channel's renderer subscription on stop/close. Unsubscribe first so
  // no new event can arm a renderer, THEN dispose the renderer set so any already-
  // armed stream/thinking debounce timer is cancelled — a /stop mid-stream must not
  // fire a late send/edit or orphan a "Responding…" embed (§6).
  detach(guildId: string, channelId: string): void {
    const key = channelKey(guildId, channelId);
    const wiring = this.channels.get(key);
    if (!wiring) return;
    wiring.unsubscribe();
    // Tear down the notifier subscription too (if one was wired), so a stopped session
    // stops forwarding events to the status channel.
    wiring.unsubscribeNotifier?.();
    try {
      wiring.renderers.dispose?.();
    } catch (err) {
      this.logger.warn('renderer dispose failed on detach', { guildId, channelId, err: String(err) });
    }
    this.channels.delete(key);
  }

  // The sendFile callback for a channel's mcpFileTool: post the confined file to the
  // bound channel. Bound per channel at start time.
  sendFileFor(guildId: string, channelId: string): (absPath: string, filename?: string) => Promise<string> {
    return async (absPath: string, filename?: string): Promise<string> => {
      const wiring = this.channels.get(channelKey(guildId, channelId));
      if (!wiring) throw new Error('Channel is not wired; cannot send file.');
      await wiring.channel.send({ files: [{ path: absPath, ...(filename ? { name: filename } : {}) }] });
      return `Sent ${filename ?? absPath} to the channel.`;
    };
  }

  // Session facts for the usage panel header/footer, read fresh at render time
  // (once per turn) so a permission-mode switch or branch change shows up on the
  // next panel. Never throws: a missing binding yields null and a git failure
  // (not a repo, no git, timeout) just omits the branch.
  private async getSessionMetaFor(guildId: string, channelId: string): Promise<UsageSessionMeta | null> {
    const binding = this.channelRegistry.get(guildId, channelId);
    if (!binding) return null;
    const meta: UsageSessionMeta = {
      ...(binding.cwd ? { cwd: binding.cwd } : {}),
      ...(binding.permMode ? { permMode: binding.permMode } : {}),
      ...(binding.createdAt ? { createdAt: binding.createdAt } : {}),
    };
    const branch = binding.cwd ? await gitBranch(binding.cwd) : null;
    if (branch) meta.gitBranch = branch;
    return meta;
  }

  // Usage feed for the embed/notifier, read fresh per turn: Codex is structurally
  // unavailable; Claude reads UsageService.getUsage() directly (its TTL cache coalesces
  // rapid re-reads). getUsage() never throws by contract, so this needs no try/catch.
  private getUsageFor(mode: string): Promise<UsageResult> {
    if (this.modeRegistry.has(mode) && !this.modeRegistry.get(mode).capabilities.usagePanel) {
      return Promise.resolve(codexUsageUnavailable());
    }
    return this.usageService.getUsage();
  }

  // Race the decision against the permission timeout. On timeout, resolve the
  // pending prompt as deny (via a synthetic deny custom_id) and return deny.
  // permissionTimeoutMs === 0 means "no timer": pass the decision through untouched
  // so the prompt waits indefinitely for a button click.
  private withTimeout(
    decision: Promise<PermissionDecision>,
    reqId: string,
    wiring: ChannelWiring,
  ): Promise<PermissionDecision> {
    if (this.permissionTimeoutMs === 0) return decision;
    return new Promise<PermissionDecision>((resolve) => {
      const timer = setTimeout(() => {
        void wiring.permission.resolve(`perm:${reqId}:deny`).catch(() => {});
        resolve({ behavior: 'deny', message: 'Permission request timed out; denied.' });
      }, this.permissionTimeoutMs);
      void decision.then((d) => {
        clearTimeout(timer);
        resolve(d);
      });
    });
  }
}
