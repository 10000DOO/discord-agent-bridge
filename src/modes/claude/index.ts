import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';
import { ClaudeSession, type QueryFn } from './session.js';
import type { SendFileCallback } from './mcpFileTool.js';
import { CLAUDE_PERMISSION_MODES } from '../../core/providerCatalog.js';

// Injected once when the mode is registered (§4/§10). `queryFn` defaults to the
// real SDK query inside ClaudeSession; tests inject a fake. `sendFileFor` is wired
// by the Discord layer: it is a FACTORY that, given a session's guild+channel,
// returns the callback the in-process attach_file MCP tool uses to deliver a file
// to THAT channel. A single registered mode instance serves every channel, so the
// per-channel sink must be bound per session (start/resume) from ctx — not once at
// registration. Kept out of the mode's core so modes stay transport-agnostic.
export interface ClaudeModeDeps {
  queryFn?: QueryFn;
  sendFileFor?: (guildId: string, channelId: string) => SendFileCallback;
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

  // Deferred (§9 on-demand resume). The SDK exposes session listing, but wiring a
  // reliable, project-scoped resumable list is Discord-UX work; the boot-time
  // resume path (orchestrator.resumeAll → resume(ctx, sessionId)) does not need
  // it. Returns [] until the resume UX chunk fills it in.
  async listResumable(_ctx: ModeContext): Promise<ResumableSession[]> {
    return [];
  }

  private sessionDeps(ctx: ModeContext) {
    const sendFile = this.deps.sendFileFor?.(ctx.guildId, ctx.channelId);
    return {
      ...(this.deps.queryFn !== undefined ? { queryFn: this.deps.queryFn } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
    };
  }
}
