import { listSessions as realListSessions, type Options, type SDKSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';
import { ClaudeSession, type QueryFn } from './session.js';
import type { SendFileCallback, ShareDocumentCallback } from './mcpFileTool.js';
import { CLAUDE_PERMISSION_MODES, claudeCatalog } from '../../core/providerCatalog.js';
import {
  ClaudeSidecarClient,
  resolveClaudeSidecarSpawn,
} from './sidecarClient.js';

// The signature of the SDK's listSessions() — narrowed to what listResumable uses.
// Injectable so tests pass a fake without touching the SDK or the filesystem (the
// default is the real SDK listSessions). A4D uses the same call (resume.ts:92).
export type ListSessionsFn = (options: { dir?: string; limit?: number }) => Promise<SDKSessionInfo[]>;

// The maximum resumable sessions surfaced in the resume picker (Discord select cap).
const LIST_RESUMABLE_LIMIT = 25;

// Optional start/resume prep: adjust ctx (e.g. model from shell env) and/or supply
// Options.env for the SDK subprocess. Used by the `custom` backend.
export type ClaudeSessionPrep = {
  ctx?: ModeContext;
  env?: Options['env'];
};

// Injected once when the mode is registered (§4/§10). `queryFn` defaults to the
// real SDK query inside ClaudeSession; tests inject a fake. `sendFileFor` is wired
// by the Discord layer: it is a FACTORY that, given a session's guild+channel,
// returns the callback the in-process attach_file MCP tool uses to deliver a file
// to THAT channel. A single registered mode instance serves every channel, so the
// per-channel sink must be bound per session (start/resume) from ctx — not once at
// registration. Kept out of the mode's core so modes stay transport-agnostic.
// `listSessionsFn` defaults to the real SDK listSessions; tests inject a fake.
//
// Sidecar (W7, opt-in via DAB_CLAUDE_SIDECAR=1 / useSidecar): start/resume/list go
// through ClaudeSidecarClient. Prefer injecting one shared `sidecarClient` for
// claude + custom so both modes share a single multi-session sidecar process.
export interface ClaudeModeDeps {
  queryFn?: QueryFn;
  sendFileFor?: (guildId: string, channelId: string) => SendFileCallback;
  // Sibling factory to sendFileFor: given a session's guild+channel, returns the
  // callback the in-process share_document MCP tool uses to post a workspace markdown
  // file into a Discord thread for THAT channel. Bound per session, same as sendFileFor.
  shareDocumentFor?: (guildId: string, channelId: string) => ShareDocumentCallback;
  listSessionsFn?: ListSessionsFn;
  /** Mode id (default 'claude'). Use 'custom' for shell-env backend. */
  name?: string;
  /** Optional prep before start/resume; may adjust ctx (model) and supply env. */
  prepareSession?: (ctx: ModeContext) => ClaudeSessionPrep | void;
  /**
   * When true, sessions are opened via the Claude sidecar client instead of
   * in-process ClaudeSession. Default false (in-process). App sets this from
   * DAB_CLAUDE_SIDECAR=1.
   */
  useSidecar?: boolean;
  /**
   * Shared long-lived sidecar client (one process, multi-session). When omitted
   * and useSidecar is true, ClaudeMode lazily spawns its own client.
   */
  sidecarClient?: ClaudeSidecarClient;
}

// The Claude backend: wraps the Claude Agent SDK query() as a ModeSession and
// maps SDK messages to normalized AgentEvents (§5a). Capabilities drive which
// Discord renderers run (§6). With useSidecar, ModeSession is a SidecarModeSession.
export class ClaudeMode implements AgentMode {
  readonly name: string;

  readonly capabilities: Capabilities = {
    streaming: true,
    thinking: true,
    toolThreads: true,
    permissionPrompts: true,
    progress: false,
    transcript: false,
    sessionResume: true,
    fileAttach: true,
    fileDiff: true,
    usagePanel: true,
    // Full SDK-synced set (incl. dontAsk/auto) from the central catalog; passed
    // natively to the SDK's permissionMode (see session.ts toSdkPermissionMode).
    permissionModes: [...CLAUDE_PERMISSION_MODES],
  };

  // Claude's model/permission/effort vocabulary for the Discord UI (§6). The wizard,
  // /config and /effort read this instead of branching on the backend id.
  readonly catalog = claudeCatalog;

  private readonly deps: ClaudeModeDeps;
  /** Lazily created only when useSidecar and no shared client was injected. */
  private ownedSidecar: ClaudeSidecarClient | null = null;

  constructor(deps: ClaudeModeDeps = {}) {
    this.deps = deps;
    this.name = deps.name ?? 'claude';
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    const { ctx: sessionCtx, env } = this.applyPrep(ctx);
    if (this.deps.useSidecar) {
      return this.openViaSidecar(sessionCtx, { env });
    }
    return new ClaudeSession(sessionCtx, {
      ...this.sessionDeps(ctx),
      ...(env !== undefined ? { env } : {}),
    });
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    const { ctx: sessionCtx, env } = this.applyPrep(ctx);
    if (this.deps.useSidecar) {
      return this.openViaSidecar(sessionCtx, { env, resumeId: sessionId });
    }
    return new ClaudeSession(sessionCtx, {
      ...this.sessionDeps(ctx),
      ...(env !== undefined ? { env } : {}),
      resumeId: sessionId,
    });
  }

  // List resumable Claude sessions for the resume UX (§9). Reads the SDK's
  // listSessions({ dir }) — the same call A4D's /resume uses (resume.ts:92) — scoped
  // to the session's cwd, and maps each SDKSessionInfo onto a ResumableSession:
  //   sessionId ← sessionId
  //   cwd       ← the session's recorded cwd, falling back to ctx.cwd
  //   label     ← the display summary (custom title / auto-summary / first prompt)
  //   updatedAt ← lastModified (ms epoch) rendered as an ISO timestamp
  // Guarded with try/catch → [] on any failure: listSessions may be unavailable
  // (older SDK, no local store) and a resume list is never load-bearing.
  // With useSidecar and no injected listSessionsFn, list goes through the sidecar
  // (sessions.list). An explicit listSessionsFn always wins (tests / overrides).
  async listResumable(ctx: ModeContext): Promise<ResumableSession[]> {
    if (this.deps.listSessionsFn) {
      return this.listViaFn(ctx, this.deps.listSessionsFn);
    }
    if (this.deps.useSidecar) {
      try {
        return await this.sidecar().sessionsList(ctx.cwd, LIST_RESUMABLE_LIMIT);
      } catch (err) {
        ctx.logger.warn(`${this.name} listResumable (sidecar) failed; returning empty`, {
          err: String(err),
        });
        return [];
      }
    }
    return this.listViaFn(ctx, realListSessions as ListSessionsFn);
  }

  private async listViaFn(ctx: ModeContext, listSessionsFn: ListSessionsFn): Promise<ResumableSession[]> {
    try {
      const sessions = await listSessionsFn({ dir: ctx.cwd, limit: LIST_RESUMABLE_LIMIT });
      return sessions.map((s) => toResumable(s, ctx.cwd));
    } catch (err) {
      ctx.logger.warn(`${this.name} listResumable failed; returning empty`, { err: String(err) });
      return [];
    }
  }

  private async openViaSidecar(
    sessionCtx: ModeContext,
    opts: { env?: Options['env']; resumeId?: string },
  ): Promise<ModeSession> {
    const envOverlay =
      opts.env !== undefined
        ? (opts.env as Record<string, string | undefined>)
        : undefined;
    // Per-channel Discord sinks for reverse RPC host.file.attach / host.file.share.
    const sendFile = this.deps.sendFileFor?.(sessionCtx.guildId, sessionCtx.channelId);
    const shareDocument = this.deps.shareDocumentFor?.(
      sessionCtx.guildId,
      sessionCtx.channelId,
    );
    return this.sidecar().openModeSession(sessionCtx, {
      ...(opts.resumeId !== undefined ? { resumeId: opts.resumeId } : {}),
      ...(envOverlay !== undefined ? { env: envOverlay } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
      ...(shareDocument !== undefined ? { shareDocument } : {}),
    });
  }

  private sidecar(): ClaudeSidecarClient {
    if (this.deps.sidecarClient) return this.deps.sidecarClient;
    if (!this.ownedSidecar) {
      const spawn = resolveClaudeSidecarSpawn();
      this.ownedSidecar = new ClaudeSidecarClient({
        spawnCommand: spawn.command,
        spawnArgs: spawn.args,
      });
    }
    return this.ownedSidecar;
  }

  private applyPrep(ctx: ModeContext): { ctx: ModeContext; env?: Options['env'] } {
    const prep = this.deps.prepareSession?.(ctx);
    return {
      ctx: prep?.ctx ?? ctx,
      ...(prep?.env !== undefined ? { env: prep.env } : {}),
    };
  }

  private sessionDeps(ctx: ModeContext) {
    const sendFile = this.deps.sendFileFor?.(ctx.guildId, ctx.channelId);
    const shareDocument = this.deps.shareDocumentFor?.(ctx.guildId, ctx.channelId);
    return {
      ...(this.deps.queryFn !== undefined ? { queryFn: this.deps.queryFn } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
      ...(shareDocument !== undefined ? { shareDocument } : {}),
    };
  }
}

// Map one SDKSessionInfo onto the backend-agnostic ResumableSession. `cwd` falls
// back to the browsed directory when the session did not record one; `label` uses
// the SDK's display summary when non-empty; `updatedAt` is the lastModified epoch
// rendered as ISO (only when it is a finite timestamp).
function toResumable(info: SDKSessionInfo, fallbackCwd: string): ResumableSession {
  const session: ResumableSession = {
    sessionId: info.sessionId,
    cwd: info.cwd && info.cwd.length > 0 ? info.cwd : fallbackCwd,
  };
  const label = info.summary && info.summary.length > 0 ? info.summary : info.firstPrompt;
  if (label && label.length > 0) session.label = label;
  if (Number.isFinite(info.lastModified)) session.updatedAt = new Date(info.lastModified).toISOString();
  return session;
}
