import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';

// TODO(Phase 1): ClaudeMode — wraps query(); maps SDK msgs → AgentEvent (§5a).
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
    permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan', 'dontAsk'],
  };

  start(_ctx: ModeContext): Promise<ModeSession> {
    throw new Error('not implemented');
  }

  resume(_ctx: ModeContext, _sessionId: string): Promise<ModeSession> {
    throw new Error('not implemented');
  }

  listResumable(_ctx: ModeContext): Promise<ResumableSession[]> {
    throw new Error('not implemented');
  }
}
