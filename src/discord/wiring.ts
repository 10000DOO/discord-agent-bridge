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
import type { ImageRenderer } from './render/segment.js';
import { chromeAvailable } from './render/chrome.js';
import type { ChromiumProvisioner } from './render/chromiumProvisioner.js';
import type { UsageSessionMeta } from './renderers/usageEmbed.js';
import { PermissionButtonsHandler, parseCustomId } from './renderers/permissionButtons.js';
import { ChannelAdapter, resolveChannelAdapter, resolveChannelResult } from './client.js';
import type { ChannelResolution, MessageChannel } from './ports.js';
import { shareDocument, type DocumentShareOptions, type ShareResult } from './documentShare.js';
import type { ConfigStore } from '../core/config.js';
import { SessionNotifier, resolveNotifications } from './notifier.js';
import { IdleWatchdog } from './idleWatchdog.js';
import { t } from './i18n.js';

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
// set (for dispose() on detach), its permission handler, the channel sink, the
// turn idle watchdog (arms on turn accept, resets on AgentEvent activity), and —
// when per-guild notifications are enabled with a resolvable status channel — the
// notifier subscription's unsubscribe (torn down alongside the renderer subscription
// on detach).
interface ChannelWiring {
  unsubscribe: () => void;
  renderers: RendererSet;
  permission: PermissionButtonsHandler;
  channel: MessageChannel;
  mode: string;
  idleWatchdog: IdleWatchdog;
  unsubscribeIdle: () => void;
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
  // Optional Grok weekly-limit poller. When present, getUsageFor('grok-build')
  // routes here; absent → unavailable (no-credentials). Claude path is unchanged.
  grokUsageService?: { isAvailable(): boolean; getUsage(): Promise<UsageResult> };
  // Optional Codex rate-limit poller (account/rateLimits/read via app-server).
  codexUsageService?: { isAvailable(): boolean; getUsage(): Promise<UsageResult> };
  logger: Logger;
  // Per-server config source, read at attach() to resolve a guild's notifications
  // settings (enabled/channelId/events). Optional so tests that do not exercise
  // notifications need not supply it; when absent, no notifier is wired.
  configStore?: ConfigStore;
  // Chromium provisioner (image render). When present, attach() resolves the browser
  // executable + install state through it so a provisioned (downloaded) Chromium is used
  // as well as a system one. Absent → detection falls back to a system Chrome only.
  imageProvisioner?: ChromiumProvisioner;
  // Append-only audit trail (§7.5). The always-allow persistence path records a
  // who/when/what entry around the GLOBAL config write. Optional so tests that do
  // not exercise always-allow need not supply it.
  auditLog?: AuditLog;
  // Resolve a channelId to a sink. Defaults to resolveChannelAdapter over the live
  // client; injectable so tests supply a fake channel without a gateway.
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
  // Resolve a channelId to a ChannelResolution (ok/gone/unavailable) so attach can tell
  // a transient failure from a permanent one. When absent, attach falls back to wrapping
  // resolveChannel as ok|unavailable — a safe default that NEVER reports 'gone', so a
  // wiring built without a result-aware resolver can never trigger a stale-binding
  // cleanup (design §11 backward-compat). App boot binds this to the live client via
  // SessionWiring.resolveResultOverClient.
  resolveChannelResult?: (channelId: string) => Promise<ChannelResolution>;
  // Delay between attach retries; injectable so tests resolve instantly instead of
  // waiting the real backoff. Defaults to a real setTimeout-backed sleep.
  sleep?: (ms: number) => Promise<void>;
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

// The outcome of an attach: 'attached' = renderers wired; 'gone' = the channel is
// permanently missing (Discord 10003 → the boot loop hard-cleans the stale binding);
// 'unavailable' = a transient failure the caller may retry later.
export type AttachOutcome = 'attached' | 'gone' | 'unavailable';

// Retry budget for attachWithRetry, applied PER stage (boot and message each get their
// own 5, design §6.0): at most MAX_ATTACH_ATTEMPTS attempts, with exponential-backoff
// delays between them (base 300ms, ×2, capped at 2.4s → 4 gaps for 5 attempts). Only an
// 'unavailable' outcome waits and retries; 'attached'/'gone' stop early. Delays are
// injected (SessionWiringDeps.sleep) so tests never actually wait.
const MAX_ATTACH_ATTEMPTS = 5;
const ATTACH_RETRY_DELAYS_MS = [300, 600, 1200, 2400];

// Default inter-retry delay: a real setTimeout. Tests inject an immediate-resolve sleep.
function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
  private readonly grokUsageService?: { isAvailable(): boolean; getUsage(): Promise<UsageResult> };
  private readonly codexUsageService?: { isAvailable(): boolean; getUsage(): Promise<UsageResult> };
  private readonly logger: Logger;
  // Mutable so app boot can bind it to the live gateway AFTER the client is
  // constructed (the client depends on the routers which depend on this wiring —
  // resolveChannel is only used at attach()/sendFile time, i.e. after login).
  private resolveChannel: (channelId: string) => Promise<MessageChannel | null>;
  // Mutable (bound after the client exists, like resolveChannel) result-aware resolver
  // that preserves the transient/permanent distinction; see setResolveChannelResult.
  private resolveChannelResult: (channelId: string) => Promise<ChannelResolution>;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly permissionTimeoutMs: number;
  private readonly auditLog?: AuditLog;
  private readonly configStore?: ConfigStore;
  private readonly imageProvisioner?: ChromiumProvisioner;
  private readonly onAlwaysAllow?: (toolName: string, ctx: AlwaysAllowContext) => void;

  private readonly channels = new Map<string, ChannelWiring>();
  // Per-channel-key in-flight attachWithRetry promise, so concurrent WHOLE retry
  // sequences (a boot retry racing a message's ensureAttached) are merged into ONE
  // (message-burst dedup, design §6.0).
  private readonly attachInFlight = new Map<string, Promise<AttachOutcome>>();
  // Per-channel-key serialization of the single-attempt critical section (attachOnce).
  // EVERY attach entry point — interactionRouter's direct attach and each
  // runAttachWithRetry attempt — chains through here so two attaches for the same channel
  // never interleave their detach→subscribe→channels.set (which would orphan the earlier
  // dispatcher's unsubscribe → EventBus leak + double render, design §11).
  private readonly attachOnceInFlight = new Map<string, Promise<AttachOutcome>>();
  // Lazily-created image renderer (tables/mermaid → PNG). Built on first use so the
  // heavy puppeteer module only loads when rendering is actually enabled + available.
  private imageRenderer: ImageRenderer | null = null;

  constructor(deps: SessionWiringDeps) {
    this.eventBus = deps.eventBus;
    this.modeRegistry = deps.modeRegistry;
    this.channelRegistry = deps.channelRegistry;
    this.usageService = deps.usageService;
    this.grokUsageService = deps.grokUsageService;
    this.codexUsageService = deps.codexUsageService;
    this.logger = deps.logger;
    this.auditLog = deps.auditLog;
    this.configStore = deps.configStore;
    this.imageProvisioner = deps.imageProvisioner;
    this.resolveChannel = deps.resolveChannel ?? (() => Promise.resolve(null));
    // Result-aware resolver: injected one wins; otherwise fall back to wrapping the
    // plain resolveChannel as ok|unavailable (read lazily so a later setResolveChannel
    // is honored, and 'gone' is never produced by the fallback — design §11).
    this.resolveChannelResult =
      deps.resolveChannelResult ?? ((channelId) => this.wrapResolveChannel(channelId));
    this.sleep = deps.sleep ?? defaultSleep;
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

  // Build the live result-aware resolver over a real gateway client (used by app boot),
  // symmetric with resolveOverClient. Preserves the transient/permanent distinction the
  // boot re-wire loop needs to decide retry-vs-cleanup.
  static resolveResultOverClient(client: Client): (channelId: string) => Promise<ChannelResolution> {
    return (channelId: string): Promise<ChannelResolution> => resolveChannelResult(client, channelId);
  }

  // Bind (or rebind) the channel resolver. App boot calls this once the gateway
  // client exists to point the wiring at the live client's channel lookup.
  setResolveChannel(resolveChannel: (channelId: string) => Promise<MessageChannel | null>): void {
    this.resolveChannel = resolveChannel;
  }

  // Bind (or rebind) the result-aware channel resolver. App boot calls this once the
  // gateway client exists, alongside setResolveChannel.
  setResolveChannelResult(resolveChannelResult: (channelId: string) => Promise<ChannelResolution>): void {
    this.resolveChannelResult = resolveChannelResult;
  }

  // Fallback wrapper: adapt a plain resolveChannel (null-or-channel) into a
  // ChannelResolution as ok|unavailable. NEVER returns 'gone', so a wiring built without
  // a result-aware resolver can never trigger a stale-binding cleanup — the conservative
  // default (design §11 backward-compat).
  private async wrapResolveChannel(channelId: string): Promise<ChannelResolution> {
    const channel = await this.resolveChannel(channelId);
    return channel ? { status: 'ok', channel } : { status: 'unavailable' };
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

  // Resolve the image renderer for a session, or null when the render branch is off
  // (config disabled or no Chrome). Lazily constructs the puppeteer-backed renderer on
  // first use (dynamic import so puppeteer never loads at boot / when disabled). Never
  // throws — any failure degrades to null (text-only).
  private async resolveImageRenderer(): Promise<ImageRenderer | null> {
    try {
      const enabled = this.configStore?.load().render?.enabled ?? true;
      if (!enabled) return null;
      // Prefer the provisioner (knows about a downloaded Chromium too); fall back to a
      // bare system-Chrome check when no provisioner is wired.
      const execPath = this.imageProvisioner?.executablePath();
      const available = this.imageProvisioner ? this.imageProvisioner.isInstalled() : chromeAvailable();
      if (!available) return null;
      if (!this.imageRenderer) {
        const { BrowserImageRenderer } = await import('./render/browserRenderer.js');
        this.imageRenderer = new BrowserImageRenderer({
          logger: this.logger,
          ...(execPath ? { executablePath: execPath } : {}),
        });
      }
      return this.imageRenderer;
    } catch (err) {
      this.logger.warn('image renderer unavailable', { err: String(err) });
      return null;
    }
  }

  // Close the lazily-built image renderer (its warm browser), if any. Called from the app's
  // shutdown path (app.destroy) so a graceful stop releases the ~100–300MB Chromium rather
  // than leaning on the idle timer / process-exit hook alone. Best-effort — never throws.
  async closeImageRenderer(): Promise<void> {
    try {
      await this.imageRenderer?.close?.();
    } catch (err) {
      this.logger.warn('image renderer close failed', { err: String(err) });
    }
  }

  // Attach renderers + permission handler for a channel that just started/resumed. A
  // SINGLE attempt, SERIALIZED per channel key: the critical section (attachOnce) chains
  // after any in-flight attach for the same channel so their detach→subscribe→channels.set
  // never interleave. The lock spans ONLY attachOnce — retry sleeps happen OUTSIDE it (in
  // runAttachWithRetry), so a retry can never self-deadlock waiting on a lock it holds.
  // On failure reports the kind ('gone' vs 'unavailable') instead of silently giving up.
  attach(guildId: string, channelId: string, mode: string): Promise<AttachOutcome> {
    const key = channelKey(guildId, channelId);
    const prev = this.attachOnceInFlight.get(key) ?? Promise.resolve<AttachOutcome>('unavailable');
    // Chain after the predecessor, swallowing its outcome/error so one attach never
    // rejects the next; run attachOnce only once the predecessor's critical section ends.
    const next = prev.catch(() => undefined).then(() => this.attachOnce(guildId, channelId, mode));
    const tracked = next.finally(() => {
      // Clear the slot only if it is still ours (a later attach may have chained on).
      if (this.attachOnceInFlight.get(key) === tracked) this.attachOnceInFlight.delete(key);
    });
    this.attachOnceInFlight.set(key, tracked);
    return next;
  }

  // The attach critical section (a single attempt). MUST run only via attach() so it is
  // serialized per channel key. Resolves the sink; on success tears down any prior
  // subscription then wires renderers + notifier; on a transient/permanent failure leaves
  // any existing wiring intact and reports the kind.
  private async attachOnce(guildId: string, channelId: string, mode: string): Promise<AttachOutcome> {
    const key = channelKey(guildId, channelId);

    const resolution = await this.resolveChannelResult(channelId);
    if (resolution.status !== 'ok') {
      // A failed resolve does NOT tear down any existing wiring: a transient blip must not
      // drop a live sink. Report the outcome so the caller retries ('unavailable') or
      // hard-cleans a stale binding ('gone').
      this.logger.warn('cannot wire renderers: channel unresolved', { guildId, channelId, status: resolution.status });
      return resolution.status;
    }
    const channel = resolution.channel;
    // Idempotent: tear down any prior subscription before re-wiring so a resume after a
    // restart does not double-render.
    this.detach(guildId, channelId);
    const binding = this.channelRegistry.get(guildId, channelId);
    const ownerId = binding?.ownerId ?? '';
    const capabilities = this.modeRegistry.get(mode).capabilities;

    // Render branch (design §7): decide at session start whether tables/mermaid become
    // PNG images. Enabled ⇔ global config render.enabled (default true) AND a browser is
    // available — a system Chrome OR a Chromium provisioned on demand via the /init and
    // /config install prompts (imageProvisioner). Absent → text-only (existing behavior).
    const renderImage = (await this.resolveImageRenderer()) ?? undefined;

    const permission = new PermissionButtonsHandler({ channel });
    const rendererSet = createDefaultRendererSet({
      channel,
      ownerId,
      guildId,
      channelId,
      ...(renderImage ? { renderImage } : {}),
      getUsage: () => this.getUsageFor(mode),
      getSessionMeta: () => this.getSessionMetaFor(guildId, channelId),
      usageTitle: usageTitleFor(mode),
      logger: this.logger,
    });
    // The dispatcher's permission renderer posts buttons via its own handler; we
    // want the SAME handler instance the router resolves against, so route the
    // permission event through our shared handler instead of the set's private one.
    const set = { ...rendererSet, permission: (ev: Extract<AgentEvent, { kind: 'permission_request' }>) => { void permission.request(ev).catch(() => {}); } };
    const dispatcher = new RendererDispatcher(set, capabilities);
    const unsubscribe = dispatcher.subscribe(this.eventBus, guildId, channelId);

    // Turn idle watchdog: armed by the message router when a turn is accepted;
    // any intermediate AgentEvent resets the timer; result/error stops it. After
    // ~3 minutes with no activity it posts a one-shot channel notice.
    const idleWatchdog = new IdleWatchdog({ channel, logger: this.logger });
    const unsubscribeIdle = this.eventBus.on(guildId, channelId, (ev) => {
      if (ev.kind === 'result' || ev.kind === 'error') idleWatchdog.stop();
      else idleWatchdog.noteActivity();
    });

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
      idleWatchdog,
      unsubscribeIdle,
      ...(unsubscribeNotifier ? { unsubscribeNotifier } : {}),
    });
    return 'attached';
  }

  // Attach with a finite, injected-delay retry (design §6/§6.1): wraps a single attach,
  // stopping early on 'attached' or 'gone' (retrying a deleted channel is pointless) and
  // retrying ONLY 'unavailable', up to MAX_ATTACH_ATTEMPTS with ATTACH_RETRY_DELAYS_MS
  // backoff between attempts. Boot and message(lazy) paths share this. A per-channel-key
  // in-flight guard makes concurrent callers share ONE retry sequence so a boot retry and
  // a message's ensureAttached cannot double-attach and orphan each other's subscription.
  attachWithRetry(guildId: string, channelId: string, mode: string): Promise<AttachOutcome> {
    const key = channelKey(guildId, channelId);
    const existing = this.attachInFlight.get(key);
    if (existing) return existing;
    const run = this.runAttachWithRetry(guildId, channelId, mode).finally(() => {
      this.attachInFlight.delete(key);
    });
    this.attachInFlight.set(key, run);
    return run;
  }

  private async runAttachWithRetry(guildId: string, channelId: string, mode: string): Promise<AttachOutcome> {
    let outcome: AttachOutcome = 'unavailable';
    for (let attempt = 0; attempt < MAX_ATTACH_ATTEMPTS; attempt++) {
      outcome = await this.attach(guildId, channelId, mode);
      if (outcome !== 'unavailable') return outcome; // 'attached'/'gone' → stop early
      // Delay before the next attempt; indices 0..3 are the 4 gaps between 5 attempts,
      // so no delay follows the final attempt.
      if (attempt < ATTACH_RETRY_DELAYS_MS.length) await this.sleep(ATTACH_RETRY_DELAYS_MS[attempt]);
    }
    return outcome; // exhausted: 'unavailable' — binding preserved, caller may retry later
  }

  // Ensure a channel's renderers are attached before a turn runs (message lazy path).
  // Already attached → 'attached' no-op (spends no retry budget). Otherwise delegate to
  // attachWithRetry, giving EACH message its own fresh ≤5 budget (design §6.0 self-heal).
  ensureAttached(guildId: string, channelId: string, mode: string): Promise<AttachOutcome> {
    if (this.isAttached(guildId, channelId)) return Promise.resolve('attached');
    return this.attachWithRetry(guildId, channelId, mode);
  }

  // True when this channel currently has a live renderer wiring.
  isAttached(guildId: string, channelId: string): boolean {
    return this.channels.has(channelKey(guildId, channelId));
  }

  // Arm the channel's idle watchdog for a newly accepted turn. No-op when the
  // channel is not wired (session not attached yet / already detached).
  armIdleWatchdog(guildId: string, channelId: string): void {
    this.channels.get(channelKey(guildId, channelId))?.idleWatchdog.arm();
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
    // Stop idle-watch bus listener + cancel any armed timer so a mid-turn detach
    // never posts a late "no activity" notice into a torn-down channel.
    wiring.unsubscribeIdle();
    wiring.idleWatchdog.stop();
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

  // The shareDocumentFor callback for a channel's /doc slash + share_document tools:
  // post a markdown file from the session workspace into a document thread. Mirrors
  // sendFileFor — bound per channel, it resolves the SAME wired MessageChannel and the
  // binding's cwd, merges the GLOBAL documentShare config (render's `?? DEFAULT` idiom),
  // and funnels through the documentShare core. The image renderer is resolved
  // per-invocation the SAME way attach() does — resolveImageRenderer is gated by
  // config.render.enabled (default true) AND browser availability; null → undefined →
  // the core's plain chunkMessage text fallback (design §7 / D9). No binding / no wired
  // channel → an UNCODED ShareResult failure (distinct from the core's five coded
  // rejections) so the edge can tell "no live session" apart from a rejected path.
  shareDocumentFor(guildId: string, channelId: string): (path: string) => Promise<ShareResult> {
    return async (path: string): Promise<ShareResult> => {
      const binding = this.channelRegistry.get(guildId, channelId);
      const wiring = this.channels.get(channelKey(guildId, channelId));
      if (!binding || !wiring) return { ok: false };
      const ds = this.configStore?.load().documentShare;
      const options: DocumentShareOptions = {
        maxBytes: ds?.maxBytes ?? 524288,
        bodyMode: ds?.bodyMode ?? 'preview',
        previewMaxChars: ds?.previewMaxChars ?? 8000,
        extensions: ds?.extensions ?? ['.md', '.markdown'],
      };
      const renderImage = (await this.resolveImageRenderer()) ?? undefined;
      return shareDocument({ channel: wiring.channel, cwd: binding.cwd, path, options, renderImage });
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

  // Usage feed for the embed/notifier, read fresh per turn:
  //   - capability usagePanel=false → unavailable
  //   - codex → CodexUsageService (account/rateLimits/read)
  //   - grok-build → GrokUsageService (weekly credits)
  //   - claude / custom → Claude UsageService
  // getUsage() never throws by contract, so this needs no try/catch.
  private getUsageFor(mode: string): Promise<UsageResult> {
    if (this.modeRegistry.has(mode) && !this.modeRegistry.get(mode).capabilities.usagePanel) {
      return Promise.resolve(codexUsageUnavailable());
    }
    if (mode === 'codex') {
      return this.codexUsageService?.getUsage() ?? Promise.resolve(codexUsageUnavailable());
    }
    if (mode === 'grok-build') {
      return this.grokUsageService?.getUsage() ?? Promise.resolve({ available: false, reason: 'no-credentials' });
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

// Mode → usage panel title. Codex has no rate-limit feed but still posts a
// context-% panel, so it needs its own title rather than falling through to Claude.
function usageTitleFor(mode: string): string {
  if (mode === 'grok-build') return t('usage.title.grok');
  if (mode === 'codex') return t('usage.title.codex');
  return t('usage.title');
}
