import * as fs from 'node:fs';
import * as path from 'node:path';
import type {
  AgentEvent,
  AuditEntry,
  Logger,
  ModeContext,
  ModeSession,
  PermissionDecision,
  SessionPermMode,
  TurnInput,
} from './contracts.js';
import type { ChannelRegistry } from './channelRegistry.js';
import type { ModeRegistry } from './modeRegistry.js';
import type { EventBus } from './eventBus.js';
import type { ConfigResolver } from './configResolver.js';
import type { PermissionResolver } from './permissionResolver.js';
import type { AuditLog } from './auditLog.js';

// The orchestrator owns the turn lifecycle for every channel (§2, §4, §9): it
// starts/resumes mode sessions, funnels user turns through a strict per-channel
// QUEUE (fixes A4 — no dropped turns), confines TurnInput file paths to the
// session workspace (§7.5 baseline), and provides the /stop + /stop-all kill
// switch. Core stays transport- and backend-agnostic: it talks to modes only
// via the AgentMode/ModeSession/ModeContext contracts and never imports the SDK
// or the Codex CLI.

// The Discord layer wires the real interactive Allow/Deny flow; until then the
// orchestrator hands each ModeContext a placeholder that denies (§9 permission
// prompts are resolved by Discord). Injectable so tests and the Discord chunk
// can substitute a real resolver.
export type PermissionRequest = { toolName: string; input: unknown };
export type RequestPermission = (
  binding: { guildId: string; channelId: string; ownerId: string },
  req: PermissionRequest,
) => Promise<PermissionDecision>;

// Default: deny, so an unwired permission prompt fails safe rather than
// auto-approving a tool the operator never saw (§7.5, deny-by-default).
const denyByDefault: RequestPermission = async () => ({
  behavior: 'deny',
  message: 'Permission prompts are not wired yet; denying by default.',
});

export interface SessionOrchestratorDeps {
  channelRegistry: ChannelRegistry;
  modeRegistry: ModeRegistry;
  eventBus: EventBus;
  configResolver: ConfigResolver;
  permissionResolver: PermissionResolver;
  auditLog: AuditLog;
  logger: Logger;
  // Wired by the Discord layer; defaults to deny-by-default (see above).
  requestPermission?: RequestPermission;
}

export interface StartParams {
  guildId: string;
  channelId: string;
  mode: string;
  cwd: string;
  ownerId: string;
  // A Claude PermMode or a Codex sandbox mode (the wizard's Codex permission step).
  permMode?: SessionPermMode;
  profile?: string | null;
  // Reasoning-effort level chosen in the wizard; threaded onto the ModeContext.
  effort?: string;
  // Model chosen in the wizard (backend-specific: a Claude model id/alias, or a Codex
  // model id when mode is 'codex'); routed onto the ModeContext by buildContext.
  model?: string;
}

// Result of a send(): whether the turn ran immediately or was queued behind a
// turn already in flight, plus its position (1-based) in the queue. The Discord
// layer uses this to tell the user "queued (#2)" vs "running".
export interface SendResult {
  status: 'started' | 'queued';
  queueDepth: number;
}

// A read-only snapshot of one live channel, exposed for the /agent stats command.
// Derived from the private `active` map; carries no ModeSession handle.
export interface ActiveChannelInfo {
  guildId: string;
  channelId: string;
  mode: string;
  cwd: string;
  ownerId: string;
  queueDepth: number;
  running: boolean;
}

// A live channel: its session, resolved metadata, and its FIFO turn queue.
interface ActiveChannel {
  guildId: string;
  channelId: string;
  mode: string;
  cwd: string;
  ownerId: string;
  permMode: SessionPermMode;
  session: ModeSession;
  // Turns waiting behind the one in flight, in arrival order.
  queue: TurnInput[];
  // A turn (running or queued) is being processed; guards against re-entrant
  // draining so turns run strictly one at a time (fixes A4).
  running: boolean;
}

function channelKey(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

export class SessionOrchestrator {
  private readonly channelRegistry: ChannelRegistry;
  private readonly modeRegistry: ModeRegistry;
  private readonly eventBus: EventBus;
  private readonly configResolver: ConfigResolver;
  private readonly permissionResolver: PermissionResolver;
  private readonly auditLog: AuditLog;
  private readonly logger: Logger;
  private readonly requestPermission: RequestPermission;

  // Live sessions keyed by "<guildId>:<channelId>". This is the in-memory
  // counterpart to the persisted ChannelRegistry binding; resumeAll() rebuilds
  // it on boot (fixes A2).
  private readonly active = new Map<string, ActiveChannel>();

  constructor(deps: SessionOrchestratorDeps) {
    this.channelRegistry = deps.channelRegistry;
    this.modeRegistry = deps.modeRegistry;
    this.eventBus = deps.eventBus;
    this.configResolver = deps.configResolver;
    this.permissionResolver = deps.permissionResolver;
    this.auditLog = deps.auditLog;
    this.logger = deps.logger;
    this.requestPermission = deps.requestPermission ?? denyByDefault;
  }

  // §9 step 1. Resolve effective config + permission, start a fresh mode
  // session, persist the binding, and track it live. Returns the ModeSession.
  async start(params: StartParams): Promise<ModeSession> {
    const { guildId, channelId, mode, cwd, ownerId } = params;
    const perm = this.permissionResolver.resolve(guildId, channelId, {
      ...(params.permMode !== undefined ? { permMode: params.permMode } : {}),
      ...(params.profile !== undefined ? { profile: params.profile } : {}),
    });

    const agentMode = this.modeRegistry.get(mode);
    const ctx = this.buildContext({
      guildId,
      channelId,
      cwd,
      ownerId,
      mode,
      permMode: perm.permMode,
      allowedTools: perm.allowedTools,
      ...(params.effort !== undefined ? { effort: params.effort } : {}),
      ...(params.model !== undefined ? { model: params.model } : {}),
    });
    const session = await agentMode.start(ctx);

    // Persist the binding (source of truth for resume-on-boot) then track live.
    // projectAuth is binding-resident access control (not a start-time parameter), so
    // set()'s REPLACE semantics must not drop it when a binding already exists — e.g.
    // send()'s on-demand reactivation restarting a persisted channel.
    const existing = this.channelRegistry.get(guildId, channelId);
    this.channelRegistry.set({
      guildId,
      channelId,
      mode: mode as 'claude' | 'codex',
      sessionId: session.sessionId,
      cwd,
      ownerId,
      permMode: perm.permMode,
      profile: perm.profile,
      ...(params.model !== undefined ? { model: params.model } : {}),
      ...(existing?.projectAuth !== undefined ? { projectAuth: existing.projectAuth } : {}),
    });
    this.active.set(channelKey(guildId, channelId), {
      guildId,
      channelId,
      mode,
      cwd,
      ownerId,
      permMode: perm.permMode,
      session,
      queue: [],
      running: false,
    });

    this.auditLog.record({
      actorId: ownerId,
      roleTier: 'execute',
      guildId,
      channelId,
      action: 'start',
      mode,
      permMode: perm.permMode,
      cwd,
      status: 'ok',
    });
    this.logger.info('session started', { guildId, channelId, mode, cwd });
    return session;
  }

  // §9 on-demand resume. Rebind a channel to an EXISTING backend session id (chosen
  // in the resume UX), mirroring start() but calling agentMode.resume(ctx, sessionId)
  // instead of start(ctx). Resolves the layered config + permission, persists the
  // binding (source of truth for resume-on-boot), tracks it live, and audits. Used by
  // the Discord layer's "Resume Session" flow (distinct from resumeAll(), which
  // rebinds every persisted channel on boot). Returns the ModeSession.
  async resume(params: StartParams, sessionId: string): Promise<ModeSession> {
    const { guildId, channelId, mode, cwd, ownerId } = params;
    const perm = this.permissionResolver.resolve(guildId, channelId, {
      ...(params.permMode !== undefined ? { permMode: params.permMode } : {}),
      ...(params.profile !== undefined ? { profile: params.profile } : {}),
    });

    const agentMode = this.modeRegistry.get(mode);
    const ctx = this.buildContext({
      guildId,
      channelId,
      cwd,
      ownerId,
      mode,
      permMode: perm.permMode,
      allowedTools: perm.allowedTools,
      ...(params.effort !== undefined ? { effort: params.effort } : {}),
      ...(params.model !== undefined ? { model: params.model } : {}),
    });
    const session = await agentMode.resume(ctx, sessionId);

    // Carry existing binding-resident projectAuth across the REPLACE (see start()).
    const existing = this.channelRegistry.get(guildId, channelId);
    this.channelRegistry.set({
      guildId,
      channelId,
      mode: mode as 'claude' | 'codex',
      sessionId: session.sessionId ?? sessionId,
      cwd,
      ownerId,
      permMode: perm.permMode,
      profile: perm.profile,
      ...(params.model !== undefined ? { model: params.model } : {}),
      ...(existing?.projectAuth !== undefined ? { projectAuth: existing.projectAuth } : {}),
    });
    this.active.set(channelKey(guildId, channelId), {
      guildId,
      channelId,
      mode,
      cwd,
      ownerId,
      permMode: perm.permMode,
      session,
      queue: [],
      running: false,
    });

    this.auditLog.record({
      actorId: ownerId,
      roleTier: 'execute',
      guildId,
      channelId,
      action: 'resume',
      mode,
      permMode: perm.permMode,
      cwd,
      status: 'ok',
    });
    this.logger.info('session resumed', { guildId, channelId, mode, sessionId });
    return session;
  }

  // §9 step 2. Enqueue a user turn. If a turn is already in flight for this
  // channel it is queued (never dropped, fixing A4) and processed strictly in
  // arrival order once the current turn completes. Files are realpath-confined
  // to the session workspace before the turn reaches the mode (§7.5); a turn
  // whose file escapes the workspace is rejected outright (an error event is
  // emitted and the turn is not sent).
  async send(guildId: string, channelId: string, turn: TurnInput): Promise<SendResult> {
    const key = channelKey(guildId, channelId);
    let channel = this.active.get(key);
    if (!channel) {
      // On-demand reactivation: a persisted, non-archived binding whose live
      // session was dropped (bot restart between resumeAll() and the first
      // turn, or resumeAll() itself skipped this channel because sessionId=null
      // and no catalog match existed) should transparently come back on the
      // next turn instead of forcing the operator to re-run /agent start.
      const binding = this.channelRegistry.get(guildId, channelId);
      if (!binding || binding.archived) {
        throw new Error(`No active session for channel ${key}. Run /agent start first.`);
      }
      this.logger.info('reactivating channel on demand', {
        guildId,
        channelId,
        mode: binding.mode,
        hasSessionId: binding.sessionId !== null,
      });
      const params: StartParams = {
        guildId,
        channelId,
        mode: binding.mode,
        cwd: binding.cwd,
        ownerId: binding.ownerId,
        permMode: binding.permMode,
        ...(binding.profile !== null ? { profile: binding.profile } : {}),
        ...(binding.model !== undefined ? { model: binding.model } : {}),
      };
      try {
        if (binding.sessionId !== null) {
          await this.resume(params, binding.sessionId);
        } else {
          await this.start(params);
        }
      } catch (err) {
        this.logger.error('reactivation failed', {
          guildId,
          channelId,
          err: String(err),
        });
        throw new Error(`No active session for channel ${key}. Run /agent start first.`);
      }
      channel = this.active.get(key);
      if (!channel) {
        throw new Error(`No active session for channel ${key}. Run /agent start first.`);
      }
    }

    const violation = this.findConfinementViolation(channel.cwd, turn);
    if (violation) {
      this.emit(guildId, channelId, {
        kind: 'error',
        message: `File path escapes the workspace and was rejected: ${violation}`,
        retryable: false,
      });
      this.auditLog.record({
        actorId: channel.ownerId,
        roleTier: 'execute',
        guildId,
        channelId,
        action: 'turn',
        mode: channel.mode,
        permMode: channel.permMode,
        cwd: channel.cwd,
        outcome: `path confinement rejected: ${violation}`,
        status: 'denied',
      });
      throw new Error(`File path escapes the workspace: ${violation}`);
    }

    channel.queue.push(turn);
    const wasIdle = !channel.running;
    // If a turn is in flight we simply leave ours queued; the running drain
    // loop will pick it up in order. Otherwise we kick off the drain.
    if (wasIdle) {
      // Fire-and-forget: the drain loop owns error handling and audit per turn.
      void this.drain(key);
    }
    return {
      status: wasIdle ? 'started' : 'queued',
      queueDepth: channel.queue.length,
    };
  }

  // §9 step 5 / §7.5 kill switch. Abort the running session, drain (clear) the
  // channel's queue, hard-delete the persisted binding, and drop the live
  // tracking. Audited. NOTE: this is a hard delete (not an archive flag) so the
  // channel is gone from state.json — a subsequent send() on the same channel
  // must go through /agent start again. The `archived` flag remains in the
  // schema + resumeAll() filter to stay backward-compatible with older
  // state.json files that still carry archived:true entries.
  async stop(guildId: string, channelId: string): Promise<void> {
    const key = channelKey(guildId, channelId);
    const channel = this.active.get(key);
    if (!channel) return;

    channel.queue.length = 0;
    try {
      await channel.session.stop();
    } catch (err) {
      this.logger.error('session stop failed', { guildId, channelId, err: String(err) });
    }
    this.active.delete(key);
    this.channelRegistry.remove(guildId, channelId);

    this.auditLog.record({
      actorId: channel.ownerId,
      roleTier: 'execute',
      guildId,
      channelId,
      action: 'stop',
      mode: channel.mode,
      permMode: channel.permMode,
      cwd: channel.cwd,
      status: 'ok',
    });
    this.logger.info('session stopped', { guildId, channelId });
  }

  // Cancel ONLY the turn in flight for a channel, KEEPING the session and its binding
  // alive so the same channel continues the conversation on the next message (the
  // terminal-`claude` ESC; distinct from stop()'s hard delete). Clears the queue so a
  // waiting turn does not auto-start after the interrupt (matters for Codex, whose
  // queued turns spawn fresh children; Claude's queue is normally empty and the mode
  // additionally drops its own prompt buffer). Unlike stop() it NEVER touches `active`
  // or the ChannelRegistry — that preservation is the whole point. Returns true when a
  // live session existed (interrupt attempted), false when there was nothing to
  // interrupt so the caller can say "no running task". Backend-neutral: a future
  // /interrupt command can reuse it unchanged.
  async interrupt(guildId: string, channelId: string): Promise<boolean> {
    const key = channelKey(guildId, channelId);
    const channel = this.active.get(key);
    if (!channel) return false;
    channel.queue.length = 0;
    try {
      await channel.session.interrupt?.();
    } catch (err) {
      this.logger.error('interrupt failed', { guildId, channelId, err: String(err) });
    }
    this.auditLog.record({
      actorId: channel.ownerId,
      roleTier: 'execute',
      guildId,
      channelId,
      action: 'interrupt',
      mode: channel.mode,
      permMode: channel.permMode,
      cwd: channel.cwd,
      status: 'ok',
    });
    this.logger.info('session interrupted', { guildId, channelId });
    return true;
  }

  // §7.5 admin kill switch. Stop every active session across all guilds. The
  // tier check happens at the router; the orchestrator just executes. Each stop
  // is isolated so one failure does not abort the rest.
  async stopAll(): Promise<void> {
    const keys = [...this.active.keys()];
    for (const key of keys) {
      const channel = this.active.get(key);
      if (!channel) continue;
      await this.stop(channel.guildId, channel.channelId);
    }
    this.logger.info('all sessions stopped', { count: keys.length });
  }

  // Read-only view of the live sessions for a guild (for /agent stats). Derived from
  // the private `active` map; returns plain snapshots with no session handle so the
  // Discord layer cannot mutate live state.
  listActive(guildId: string): ActiveChannelInfo[] {
    const out: ActiveChannelInfo[] = [];
    for (const channel of this.active.values()) {
      if (channel.guildId !== guildId) continue;
      out.push({
        guildId: channel.guildId,
        channelId: channel.channelId,
        mode: channel.mode,
        cwd: channel.cwd,
        ownerId: channel.ownerId,
        queueDepth: channel.queue.length,
        running: channel.running,
      });
    }
    return out;
  }

  // §9 step 4 (fixes A2). Boot recovery: re-bind every non-archived channel from
  // persisted state via mode.resume(ctx, sessionId). A mode/session that fails
  // to resume is logged and skipped so one bad binding never crashes boot.
  async resumeAll(): Promise<void> {
    const bindings = this.channelRegistry.list().filter((b) => !b.archived);
    let resumed = 0;
    for (const binding of bindings) {
      const { guildId, channelId, mode, cwd, ownerId, permMode, sessionId } = binding;
      try {
        const agentMode = this.modeRegistry.get(mode);
        // Re-resolve the layered tool allowlist for the resumed channel (no live
        // session override on boot — the persisted profile/mode drive it) so a
        // resumed session gets the same allowlist a fresh start() would.
        const perm = this.permissionResolver.resolve(guildId, channelId);
        const ctx = this.buildContext({
          guildId,
          channelId,
          cwd,
          ownerId,
          mode,
          permMode,
          allowedTools: perm.allowedTools,
          ...(binding.model !== undefined ? { model: binding.model } : {}),
        });
        // A binding with no backend sessionId cannot be resumed against a
        // specific id. Skip it here — the next user turn will hit send()'s
        // on-demand reactivation path, which start()s a fresh session for the
        // channel. Do NOT try to auto-recover an id from the mode's catalog by
        // matching cwd: that couples an arbitrary Claude/Codex session on the
        // host to this channel just because their cwds happen to match, which
        // is wrong when multiple channels share a workspace or when unrelated
        // sessions exist. resumeWizard / interactionRouter still use
        // AgentMode.listResumable for the interactive resume UX.
        if (sessionId === null) {
          this.logger.info('skipping resume: no sessionId; will fresh-start on next turn', {
            guildId,
            channelId,
            mode,
          });
          continue;
        }
        const session = await agentMode.resume(ctx, sessionId);
        this.active.set(channelKey(guildId, channelId), {
          guildId,
          channelId,
          mode,
          cwd,
          ownerId,
          permMode,
          session,
          queue: [],
          running: false,
        });
        this.auditLog.record({
          actorId: ownerId,
          roleTier: 'execute',
          guildId,
          channelId,
          action: 'resume',
          mode,
          permMode,
          cwd,
          status: 'ok',
        });
        resumed++;
      } catch (err) {
        // Tolerate a mode/session that fails to resume: log + skip, never crash.
        this.logger.error('resume failed; skipping channel', {
          guildId,
          channelId,
          mode,
          err: String(err),
        });
      }
    }
    this.logger.info('resume-on-boot complete', { resumed, total: bindings.length });
  }

  // Drain a channel's queue one turn at a time, strictly in FIFO order. Marked
  // running for the whole drain so a concurrent send() cannot start a second
  // drain (single-threaded JS + this flag = no interleaving). Each turn is
  // audited; a send() failure is surfaced as an error event but does not stop
  // the queue (the next turn still runs).
  private async drain(key: string): Promise<void> {
    const channel = this.active.get(key);
    if (!channel || channel.running) return;
    channel.running = true;
    try {
      while (channel.queue.length > 0) {
        const turn = channel.queue.shift() as TurnInput;
        try {
          await channel.session.send(turn);
          this.auditLog.record({
            actorId: channel.ownerId,
            roleTier: 'execute',
            guildId: channel.guildId,
            channelId: channel.channelId,
            action: 'turn',
            mode: channel.mode,
            permMode: channel.permMode,
            cwd: channel.cwd,
            status: 'ok',
          });
        } catch (err) {
          this.logger.error('turn failed', {
            guildId: channel.guildId,
            channelId: channel.channelId,
            err: String(err),
          });
          this.emit(channel.guildId, channel.channelId, {
            kind: 'error',
            message: `Turn failed: ${String(err)}`,
            retryable: true,
          });
          this.auditLog.record({
            actorId: channel.ownerId,
            roleTier: 'execute',
            guildId: channel.guildId,
            channelId: channel.channelId,
            action: 'turn',
            mode: channel.mode,
            permMode: channel.permMode,
            cwd: channel.cwd,
            outcome: String(err),
            status: 'error',
          });
        }
      }
    } finally {
      channel.running = false;
    }
  }

  // Build the ModeContext handed to a mode's start()/resume(): emit → EventBus,
  // requestPermission → the injectable resolver, config → the resolved layered
  // view, audit → AuditLog. guildId/channelId/cwd/ownerId/permMode are carried.
  // The resolved tool allowlist (from PermissionResolver: the global auto-allow
  // set, narrowed by any active profile) is threaded onto the config view so the
  // Claude mode reads the layered allowlist instead of re-hardcoding one (A8).
  private buildContext(args: {
    guildId: string;
    channelId: string;
    cwd: string;
    ownerId: string;
    mode: string;
    permMode: SessionPermMode;
    allowedTools: string[];
    effort?: string;
    model?: string;
  }): ModeContext {
    const { guildId, channelId, cwd, ownerId, permMode, allowedTools, effort } = args;
    const modeConfig = this.configResolver.resolveModeConfig(guildId, channelId);
    modeConfig.allowedTools = allowedTools;
    modeConfig.autoAllowClaudeTools = allowedTools;
    // Per-backend model routing: each backend reads a different field — Codex reads
    // config.codexModel (never ctx.model, which carries the Claude model), while the
    // Claude mode reads ctx.model, fed by the modeConfig.model spread below. A wizard
    // pick therefore overrides the matching config field; absent/empty keeps the
    // resolved config default.
    if (args.model !== undefined && args.model.length > 0) {
      if (args.mode === 'codex') {
        modeConfig.codexModel = args.model;
      } else {
        modeConfig.model = args.model;
      }
    }
    return {
      guildId,
      channelId,
      cwd,
      ownerId,
      ...(modeConfig.model !== undefined ? { model: modeConfig.model } : {}),
      ...(effort !== undefined && effort.length > 0 ? { effort } : {}),
      permMode,
      emit: (ev: AgentEvent) => this.emit(guildId, channelId, ev),
      requestPermission: (req) => this.requestPermission({ guildId, channelId, ownerId }, req),
      config: modeConfig,
      logger: this.logger,
      audit: (entry: AuditEntry) => {
        this.auditLog.record(entry);
      },
      // A mode calls this the first time it captures a real backend sessionId
      // (Claude system/init, Codex first turn result). Persist immediately so a
      // channel that was saved with sessionId=null (start() persisted BEFORE the
      // id was known) gets its id written and can resume across restarts.
      onSessionIdReady: (sessionId: string) => {
        const binding = this.channelRegistry.get(guildId, channelId);
        if (!binding || binding.archived) return;
        if (binding.sessionId === sessionId) return;
        this.channelRegistry.set({
          guildId,
          channelId,
          mode: binding.mode,
          sessionId,
          cwd: binding.cwd,
          ownerId: binding.ownerId,
          permMode: binding.permMode,
          profile: binding.profile,
          ...(binding.projectAuth !== undefined ? { projectAuth: binding.projectAuth } : {}),
          // Carry the persisted model forward — set() REPLACES the binding, so
          // omitting it here would silently drop the wizard's model the moment
          // the backend sessionId arrives.
          ...(binding.model !== undefined ? { model: binding.model } : {}),
        });
        this.logger.info('registry updated with backend sessionId', {
          guildId,
          channelId,
          sessionId,
        });
      },
    };
  }

  // Build a MINIMAL read-only ModeContext for a mode's listResumable (resume UX): it
  // carries the browsed cwd + the mode's resolved config view (codexHome etc.) + the
  // logger, but its emit/requestPermission/audit are inert no-ops — listResumable only
  // reads cwd/config/logger and must never start a session or emit events. Not bound to
  // a live channel (no guildId/channelId semantics beyond placeholders): nothing is
  // persisted or tracked. Used by the Discord layer's resume flow before any channel is
  // created for the resumed session.
  buildListContext(mode: string, cwd: string): ModeContext {
    const modeConfig = this.configResolver.resolveModeConfig('', '');
    return {
      guildId: '',
      channelId: '',
      cwd,
      ownerId: '',
      ...(modeConfig.model !== undefined ? { model: modeConfig.model } : {}),
      permMode: 'default',
      emit: () => {},
      requestPermission: async () => ({ behavior: 'deny' as const }),
      config: modeConfig,
      logger: this.logger,
      audit: () => {},
    };
  }

  private emit(guildId: string, channelId: string, ev: AgentEvent): void {
    this.eventBus.emit(guildId, channelId, ev);
  }

  // Return the first TurnInput file whose realpath escapes the workspace root,
  // or null if every file is confined. Resolves symlinks by realpath-ing the
  // deepest existing ancestor of each path (a file need not exist yet), so a
  // symlink pointing outside the workspace is caught, not just a literal `..`.
  // NOTE: this is a pre-filter only and is subject to TOCTOU (a tail component
  // could be swapped for a symlink after this check). The authoritative guard
  // belongs at the mode's file-open site (Phase 2); do not treat this as the
  // sole confinement enforcement.
  private findConfinementViolation(cwd: string, turn: TurnInput): string | null {
    if (!turn.files || turn.files.length === 0) return null;
    const root = realpathOrResolve(cwd);
    for (const file of turn.files) {
      const resolved = realpathOrResolve(path.resolve(cwd, file.path));
      if (!isWithin(root, resolved)) return file.path;
    }
    return null;
  }
}

// Realpath a path, falling back to the realpath of its deepest existing ancestor
// joined with the non-existent tail — so confinement holds for paths that do not
// exist yet while still resolving symlinks in the part that does.
function realpathOrResolve(target: string): string {
  const abs = path.resolve(target);
  let existing = abs;
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break; // reached the filesystem root
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

// True when `child` is the same as, or nested under, `root`. Uses path.relative
// so it is not fooled by shared string prefixes (e.g. /ws vs /ws-evil).
function isWithin(root: string, child: string): boolean {
  const rel = path.relative(root, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
