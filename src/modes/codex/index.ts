import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';

// TODO(Phase 1): CodexMode — one-shot `codex exec --json` per turn (§5b).
export class CodexMode implements AgentMode {
  readonly name = 'codex';

  readonly capabilities: Capabilities = {
    streaming: false,
    thinking: false,
    toolThreads: false,
    permissionPrompts: false,
    progress: true,
    transcript: true,
    sessionResume: true,
    fileAttach: false,
    fileDiff: false,
    usagePanel: false,
    // Mapped to Codex approval/sandbox flags; Phase-2-verified (§5b, §7A).
    permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
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
