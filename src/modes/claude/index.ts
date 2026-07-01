import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';
import { ClaudeSession, type QueryFn } from './session.js';
import type { SendFileCallback } from './mcpFileTool.js';

// Injected once when the mode is registered (§4/§10). `queryFn` defaults to the
// real SDK query inside ClaudeSession; tests inject a fake. `sendFile` is wired
// by the Discord layer so the in-process attach_file MCP tool can deliver a file
// to the channel — kept out of the mode so modes stay transport-agnostic.
export interface ClaudeModeDeps {
  queryFn?: QueryFn;
  sendFile?: SendFileCallback;
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
    permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
  };

  private readonly deps: ClaudeModeDeps;

  constructor(deps: ClaudeModeDeps = {}) {
    this.deps = deps;
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    return new ClaudeSession(ctx, this.sessionDeps());
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    return new ClaudeSession(ctx, { ...this.sessionDeps(), resumeId: sessionId });
  }

  // Deferred (§9 on-demand resume). The SDK exposes session listing, but wiring a
  // reliable, project-scoped resumable list is Discord-UX work; the boot-time
  // resume path (orchestrator.resumeAll → resume(ctx, sessionId)) does not need
  // it. Returns [] until the resume UX chunk fills it in.
  async listResumable(_ctx: ModeContext): Promise<ResumableSession[]> {
    return [];
  }

  private sessionDeps() {
    return {
      ...(this.deps.queryFn !== undefined ? { queryFn: this.deps.queryFn } : {}),
      ...(this.deps.sendFile !== undefined ? { sendFile: this.deps.sendFile } : {}),
    };
  }
}
