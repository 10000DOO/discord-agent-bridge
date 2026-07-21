import { listSessions as realListSessions, type SDKSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';
import { ClaudeSession, type QueryFn } from './session.js';
import type { SendFileCallback } from './mcpFileTool.js';
import { CLAUDE_PERMISSION_MODES, claudeCatalog } from '../../core/providerCatalog.js';

// The signature of the SDK's listSessions() — narrowed to what listResumable uses.
// Injectable so tests pass a fake without touching the SDK or the filesystem (the
// default is the real SDK listSessions). A4D uses the same call (resume.ts:92).
export type ListSessionsFn = (options: { dir?: string; limit?: number }) => Promise<SDKSessionInfo[]>;

// The maximum resumable sessions surfaced in the resume picker (Discord select cap).
const LIST_RESUMABLE_LIMIT = 25;

// Injected once when the mode is registered (§4/§10). `queryFn` defaults to the
// real SDK query inside ClaudeSession; tests inject a fake. `sendFileFor` is wired
// by the Discord layer: it is a FACTORY that, given a session's guild+channel,
// returns the callback the in-process attach_file MCP tool uses to deliver a file
// to THAT channel. A single registered mode instance serves every channel, so the
// per-channel sink must be bound per session (start/resume) from ctx — not once at
// registration. Kept out of the mode's core so modes stay transport-agnostic.
// `listSessionsFn` defaults to the real SDK listSessions; tests inject a fake.
export interface ClaudeModeDeps {
  queryFn?: QueryFn;
  sendFileFor?: (guildId: string, channelId: string) => SendFileCallback;
  listSessionsFn?: ListSessionsFn;
}

// The Claude backend: wraps the Claude Agent SDK query() as a ModeSession and
// maps SDK messages to normalized AgentEvents (§5a). Capabilities drive which
// Discord renderers run (§6).
export class ClaudeMode implements AgentMode {
  readonly name = 'claude';

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

  constructor(deps: ClaudeModeDeps = {}) {
    this.deps = deps;
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    return new ClaudeSession(ctx, this.sessionDeps(ctx));
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    return new ClaudeSession(ctx, { ...this.sessionDeps(ctx), resumeId: sessionId });
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
  async listResumable(ctx: ModeContext): Promise<ResumableSession[]> {
    const listSessionsFn = this.deps.listSessionsFn ?? (realListSessions as ListSessionsFn);
    try {
      const sessions = await listSessionsFn({ dir: ctx.cwd, limit: LIST_RESUMABLE_LIMIT });
      return sessions.map((s) => toResumable(s, ctx.cwd));
    } catch (err) {
      ctx.logger.warn('claude listResumable failed; returning empty', { err: String(err) });
      return [];
    }
  }

  private sessionDeps(ctx: ModeContext) {
    const sendFile = this.deps.sendFileFor?.(ctx.guildId, ctx.channelId);
    return {
      ...(this.deps.queryFn !== undefined ? { queryFn: this.deps.queryFn } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
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
