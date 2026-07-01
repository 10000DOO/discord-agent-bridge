import type { ModeContext, ModeSession, TurnInput } from '../../core/contracts.js';

// TODO(Phase 1): wraps query(); consumes SDK async iterable and maps to AgentEvent (§5a).
export class ClaudeSession implements ModeSession {
  readonly sessionId: string | null = null;

  constructor(_ctx: ModeContext) {}

  send(_turn: TurnInput): Promise<void> {
    throw new Error('not implemented');
  }

  stop(): Promise<void> {
    throw new Error('not implemented');
  }
}
