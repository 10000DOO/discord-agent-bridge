import type { ModeContext, PermissionDecision } from '../../core/contracts.js';

// TODO(Phase 1): canUseTool ↔ permission_request events; bridges SDK canUseTool to
// ctx.requestPermission and the Discord Allow/Deny buttons (§5a, §7A).
export function makeCanUseTool(_ctx: ModeContext) {
  return async (_toolName: string, _input: unknown): Promise<PermissionDecision> => {
    throw new Error('not implemented');
  };
}
