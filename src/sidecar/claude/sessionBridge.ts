// Bridges protocol methods onto ClaudeSession / listSessions.
// Reuses existing ClaudeSession — no reimplementation of SDK mapping.

import type {
  AgentEvent,
  Logger,
  ModeContext,
  ModeSession,
  PermissionDecision,
  ResumableSession,
  SessionPermMode,
} from '../../core/contracts.js';
import { ClaudeSession, type ClaudeSessionDeps } from '../../modes/claude/session.js';
import type { ListSessionsFn } from '../../modes/claude/index.js';
import type { ShareResult } from '../../discord/documentShare.js';
import { listSessions as realListSessions, type Options, type SDKSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import type {
  SessionResumeParams,
  SessionStartParams,
  SessionsListResult,
} from './protocol.js';
import { event, notify, type Envelope } from './protocol.js';

const DEFAULT_LIST_LIMIT = 25;

// Injectable session factory so tests can avoid the real Claude Agent SDK.
export type SessionFactory = (
  ctx: ModeContext,
  deps: ClaudeSessionDeps,
) => ModeSession;

export type WriteEnvelope = (env: Envelope) => void;

/** Sidecar → Host reverse RPC (host.file.*). Injected by SidecarServer. */
export type RequestHost = (
  method: string,
  params?: Record<string, unknown>,
  session?: string,
) => Promise<unknown>;

export interface SessionBridgeDeps {
  write: WriteEnvelope;
  /** Reverse RPC to the host process; when set, sendFile/shareDocument are wired. */
  requestHost?: RequestHost;
  createSession?: SessionFactory;
  listSessionsFn?: ListSessionsFn;
  logger?: Logger;
}

interface PendingPermission {
  resolve: (decision: PermissionDecision) => void;
}

interface LiveSession {
  handle: string;
  session: ModeSession;
  pendingPermissions: Map<string, PendingPermission>;
  permSeq: number;
}

const nullLogger: Logger = {
  debug() {},
  info() {},
  warn() {},
  error() {},
};

function defaultCreateSession(ctx: ModeContext, deps: ClaudeSessionDeps): ModeSession {
  return new ClaudeSession(ctx, deps);
}

function toResumable(info: SDKSessionInfo, fallbackCwd: string): ResumableSession {
  const session: ResumableSession = {
    sessionId: info.sessionId,
    cwd: info.cwd && info.cwd.length > 0 ? info.cwd : fallbackCwd,
  };
  const label = info.summary && info.summary.length > 0 ? info.summary : info.firstPrompt;
  if (label && label.length > 0) session.label = label;
  if (Number.isFinite(info.lastModified)) {
    session.updatedAt = new Date(info.lastModified).toISOString();
  }
  return session;
}

export class SessionBridge {
  private readonly sessions = new Map<string, LiveSession>();
  private handleSeq = 0;
  private readonly write: WriteEnvelope;
  private readonly requestHost: RequestHost | undefined;
  private readonly createSession: SessionFactory;
  private readonly listSessionsFn: ListSessionsFn;
  private readonly logger: Logger;

  constructor(deps: SessionBridgeDeps) {
    this.write = deps.write;
    this.requestHost = deps.requestHost;
    this.createSession = deps.createSession ?? defaultCreateSession;
    this.listSessionsFn = deps.listSessionsFn ?? (realListSessions as ListSessionsFn);
    this.logger = deps.logger ?? nullLogger;
  }

  async start(params: SessionStartParams): Promise<{ session: string; backendSessionId: string | null }> {
    return this.openSession(params);
  }

  async resume(
    params: SessionResumeParams,
  ): Promise<{ session: string; backendSessionId: string | null }> {
    return this.openSession(params, params.backendSessionId);
  }

  private openSession(
    params: SessionStartParams,
    resumeId?: string,
  ): { session: string; backendSessionId: string | null } {
    const handle = `s-${++this.handleSeq}`;
    const live: LiveSession = {
      handle,
      session: null as unknown as ModeSession,
      pendingPermissions: new Map(),
      permSeq: 0,
    };

    const ctx = this.buildContext(params, live);
    // Always wire sendFile (and shareDocument) when reverse RPC is available so
    // MCP tools register even if the host later rejects an unwired channel.
    const requestHost = this.requestHost;
    const sessionDeps: ClaudeSessionDeps = {
      ...(resumeId !== undefined ? { resumeId } : {}),
      ...(params.env !== undefined ? { env: params.env as Options['env'] } : {}),
      ...(requestHost
        ? {
            sendFile: async (absPath: string, filename?: string) => {
              const result = (await requestHost(
                'host.file.attach',
                {
                  path: absPath,
                  ...(filename !== undefined ? { name: filename } : {}),
                },
                handle,
              )) as { ok?: boolean; message?: string } | undefined;
              if (result && typeof result.message === 'string') return result.message;
              return 'Sent file.';
            },
            shareDocument: async (docPath: string) => {
              const result = await requestHost(
                'host.file.share',
                { path: docPath },
                handle,
              );
              return result as ShareResult;
            },
          }
        : {}),
    };
    live.session = this.createSession(ctx, sessionDeps);
    this.sessions.set(handle, live);

    // Resume may already know the backend id; start leaves it null until init.
    const backendSessionId =
      resumeId !== undefined
        ? resumeId
        : live.session.sessionId;
    return { session: handle, backendSessionId };
  }

  private buildContext(params: SessionStartParams, live: LiveSession): ModeContext {
    const handle = live.handle;
    return {
      guildId: params.guildId,
      channelId: params.channelId,
      cwd: params.cwd,
      ownerId: params.ownerId ?? '',
      ...(params.model !== undefined ? { model: params.model } : {}),
      ...(params.effort !== undefined ? { effort: params.effort } : {}),
      permMode: params.permMode as SessionPermMode,
      emit: (ev: AgentEvent) => {
        this.write(event(handle, ev));
      },
      // Protocol §5: emit permission_request, wait for session.permission.
      requestPermission: (req) => {
        const id = `p-${++live.permSeq}`;
        this.write(
          event(handle, {
            kind: 'permission_request',
            id,
            toolName: req.toolName,
            input: req.input,
          }),
        );
        return new Promise<PermissionDecision>((resolve) => {
          live.pendingPermissions.set(id, { resolve });
        });
      },
      config: {
        ...(params.config?.allowedTools !== undefined
          ? { allowedTools: params.config.allowedTools }
          : {}),
        ...(params.config?.autoAllowClaudeTools !== undefined
          ? { autoAllowClaudeTools: params.config.autoAllowClaudeTools }
          : {}),
        ...(params.config?.permissionTimeoutSec !== undefined
          ? { permissionTimeoutSec: params.config.permissionTimeoutSec }
          : {}),
      },
      logger: this.logger,
      audit: () => {},
      onSessionIdReady: (backendSessionId) => {
        this.write(
          notify('session.backend_id', { backendSessionId }, handle),
        );
      },
    };
  }

  async send(
    handle: string,
    text: string,
    files?: { path: string; mime?: string }[],
  ): Promise<void> {
    const live = this.require(handle);
    await live.session.send({
      text,
      ...(files !== undefined ? { files } : {}),
    });
  }

  async stop(handle: string): Promise<void> {
    const live = this.sessions.get(handle);
    if (!live) return;
    this.sessions.delete(handle);
    // Reject any in-flight permission waits so canUseTool does not hang.
    for (const [, p] of live.pendingPermissions) {
      p.resolve({ behavior: 'deny', message: 'Session stopped.' });
    }
    live.pendingPermissions.clear();
    await live.session.stop();
  }

  async interrupt(handle: string): Promise<void> {
    const live = this.require(handle);
    if (typeof live.session.interrupt !== 'function') {
      const err = new Error('interrupt not supported') as Error & { code: string };
      err.code = 'unsupported';
      throw err;
    }
    await live.session.interrupt();
  }

  async setModel(handle: string, model?: string): Promise<void> {
    const live = this.require(handle);
    if (typeof live.session.setModel !== 'function') {
      const err = new Error('setModel not supported') as Error & { code: string };
      err.code = 'unsupported';
      throw err;
    }
    await live.session.setModel(model);
  }

  async setEffort(handle: string, effort?: string): Promise<void> {
    const live = this.require(handle);
    if (typeof live.session.setEffort !== 'function') {
      const err = new Error('setEffort not supported') as Error & { code: string };
      err.code = 'unsupported';
      throw err;
    }
    await live.session.setEffort(effort);
  }

  resolvePermission(
    handle: string,
    requestId: string,
    decision: PermissionDecision,
  ): void {
    const live = this.require(handle);
    const pending = live.pendingPermissions.get(requestId);
    if (!pending) {
      const err = new Error(`unknown permission request: ${requestId}`) as Error & {
        code: string;
      };
      err.code = 'invalid_request';
      throw err;
    }
    live.pendingPermissions.delete(requestId);
    pending.resolve(decision);
  }

  async listSessions(cwd: string, limit = DEFAULT_LIST_LIMIT): Promise<SessionsListResult> {
    try {
      const sessions = await this.listSessionsFn({ dir: cwd, limit });
      return { sessions: sessions.map((s) => toResumable(s, cwd)) };
    } catch (err) {
      this.logger.warn('sessions.list failed; returning empty', { err: String(err) });
      return { sessions: [] };
    }
  }

  async stopAll(): Promise<void> {
    const handles = [...this.sessions.keys()];
    await Promise.all(handles.map((h) => this.stop(h)));
  }

  has(handle: string): boolean {
    return this.sessions.has(handle);
  }

  private require(handle: string): LiveSession {
    const live = this.sessions.get(handle);
    if (!live) {
      const err = new Error(`unknown session: ${handle}`) as Error & { code: string };
      err.code = 'unknown_session';
      throw err;
    }
    return live;
  }
}
