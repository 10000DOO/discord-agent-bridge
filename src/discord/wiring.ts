import type { Client } from 'discord.js';
import type { AgentEvent, Logger, PermissionDecision } from '../core/contracts.js';
import type { EventBus } from '../core/eventBus.js';
import type { ModeRegistry } from '../core/modeRegistry.js';
import type { UsageResult, UsageService } from '../core/usageService.js';
import { codexUsageUnavailable } from '../core/usageService.js';
import type { ChannelRegistry } from '../core/channelRegistry.js';
import type { PermissionRequest } from '../core/sessionOrchestrator.js';
import { RendererDispatcher, createDefaultRendererSet } from './renderers/index.js';
import { PermissionButtonsHandler, parseCustomId } from './renderers/permissionButtons.js';
import { ChannelAdapter, resolveChannelAdapter } from './client.js';
import type { MessageChannel } from './ports.js';

// The deferred 7a hookups, wired live (§7A/§6/§7.5). Per active channel this owns:
//   - a RendererDispatcher subscribed to the eventBus (AgentEvents → Discord), with
//     the capability set of that channel's mode; unsubscribed on stop.
//   - a PermissionButtonsHandler: orchestrator.requestPermission posts Allow/Always/
//     Deny and the returned promise resolves when the button interaction settles.
//     The permission timeout (limits.permissionTimeoutSec) denies on expiry.
//   - the sendFile callback (mcpFileTool → post the confined file to the channel).
//   - usage snapshot feeding the usageEmbed (Claude only; Codex → unavailable line).
//
// discord.js is confined to client.ts adapters; this module resolves a channel to
// a MessageChannel port via resolveChannelAdapter and everything else is port-level.

// One channel's live wiring: its renderer subscription unsubscribe, its permission
// handler, and the channel sink.
interface ChannelWiring {
  unsubscribe: () => void;
  permission: PermissionButtonsHandler;
  channel: MessageChannel;
  mode: string;
}

export interface SessionWiringDeps {
  eventBus: EventBus;
  modeRegistry: ModeRegistry;
  channelRegistry: ChannelRegistry;
  usageService: UsageService;
  logger: Logger;
  // Resolve a channelId to a sink. Defaults to resolveChannelAdapter over the live
  // client; injectable so tests supply a fake channel without a gateway.
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
  // Permission-request timeout in seconds (config limits.permissionTimeoutSec).
  permissionTimeoutSec: number;
  // Persist an "always-allow" tool so future turns auto-allow it (§7A). Called
  // when a permission button resolves as `always`. App boot wires this to the
  // ConfigStore's global autoAllowClaudeTools set (see app.ts persistAlwaysAllow).
  // Optional so tests that do not exercise always-allow need not supply it.
  onAlwaysAllow?: (toolName: string) => void;
}

function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
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
  private readonly onAlwaysAllow?: (toolName: string) => void;

  private readonly channels = new Map<string, ChannelWiring>();
  // Latest usage snapshot, refreshed lazily; fed into the usage embed synchronously.
  private lastUsage: UsageResult | null = null;

  constructor(deps: SessionWiringDeps) {
    this.eventBus = deps.eventBus;
    this.modeRegistry = deps.modeRegistry;
    this.channelRegistry = deps.channelRegistry;
    this.usageService = deps.usageService;
    this.logger = deps.logger;
    this.resolveChannel = deps.resolveChannel ?? (() => Promise.resolve(null));
    this.permissionTimeoutMs = Math.max(1, deps.permissionTimeoutSec) * 1000;
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
    const decision = wiring.permission.request(ev);
    return this.withTimeout(decision, id, wiring);
  };

  // Resolve a `perm:<reqId>:<action>` button for a channel. Returns the applied
  // decision, or null when the id is foreign/unknown (safe on any interaction).
  async resolvePermission(
    guildId: string,
    channelId: string,
    customId: string,
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
    const decision = await wiring.permission.resolve(customId);
    if (alwaysTool && decision?.behavior === 'allow') {
      try {
        this.onAlwaysAllow?.(alwaysTool);
      } catch (err) {
        // Persisting the always-allow set is best-effort; a config write failure
        // must not break the interaction (the turn is already allowed).
        this.logger.warn('failed to persist always-allow tool', { tool: alwaysTool, err: String(err) });
      }
    }
    return decision;
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
      getUsage: () => this.usageSnapshotFor(mode),
    });
    // The dispatcher's permission renderer posts buttons via its own handler; we
    // want the SAME handler instance the router resolves against, so route the
    // permission event through our shared handler instead of the set's private one.
    const set = { ...rendererSet, permission: (ev: Extract<AgentEvent, { kind: 'permission_request' }>) => { void permission.request(ev).catch(() => {}); } };
    const dispatcher = new RendererDispatcher(set, capabilities);
    const unsubscribe = dispatcher.subscribe(this.eventBus, guildId, channelId);

    this.channels.set(key, { unsubscribe, permission, channel, mode });
    // Kick a usage refresh so the first usage embed has data (Claude only).
    if (capabilities.usagePanel) void this.refreshUsage();
  }

  // Tear down a channel's renderer subscription on stop/close.
  detach(guildId: string, channelId: string): void {
    const key = channelKey(guildId, channelId);
    const wiring = this.channels.get(key);
    if (!wiring) return;
    wiring.unsubscribe();
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

  // Refresh the cached usage snapshot (Claude OAuth usage). Best-effort; never throws.
  private async refreshUsage(): Promise<void> {
    try {
      this.lastUsage = await this.usageService.getUsage();
    } catch (err) {
      this.logger.warn('usage refresh failed', { err: String(err) });
    }
  }

  // Usage feed for the embed: Codex is structurally unavailable; Claude uses the
  // last poll snapshot (may be null until the first refresh completes).
  private usageSnapshotFor(mode: string): UsageResult | null {
    if (this.modeRegistry.has(mode) && !this.modeRegistry.get(mode).capabilities.usagePanel) {
      return codexUsageUnavailable();
    }
    return this.lastUsage;
  }

  // Race the decision against the permission timeout. On timeout, resolve the
  // pending prompt as deny (via a synthetic deny custom_id) and return deny.
  private withTimeout(
    decision: Promise<PermissionDecision>,
    reqId: string,
    wiring: ChannelWiring,
  ): Promise<PermissionDecision> {
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
