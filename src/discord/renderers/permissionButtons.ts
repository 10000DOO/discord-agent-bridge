import type { AgentEvent } from '../../core/contracts.js';

// TODO(Phase 1): Allow / Always-Allow / Deny / Details buttons for permission_request;
// the button interaction resolves the pending PermissionDecision (custom_id perm:<reqId>:<action>).
// Cap: permissionPrompts (§6, §5a).
export function renderPermissionButtons(_ev: Extract<AgentEvent, { kind: 'permission_request' }>): void {
  throw new Error('not implemented');
}
