import type { ModeContext, ModeSession, TurnInput } from '../../core/contracts.js';

// TODO(Phase 1): spawn `codex exec [resume <id>] --json …` per turn with approval/sandbox
// flags per resolved permMode (NOT --full-auto). Verify flag names vs installed CLI in Phase 2 (§5b, §7A).
export class CodexSession implements ModeSession {
  readonly sessionId: string | null = null;

  constructor(_ctx: ModeContext) {}

  send(_turn: TurnInput): Promise<void> {
    throw new Error('not implemented');
  }

  stop(): Promise<void> {
    throw new Error('not implemented');
  }
}
