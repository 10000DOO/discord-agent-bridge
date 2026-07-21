import { isCodexSandboxMode } from '../../core/providerCatalog.js';
import type { PermMode } from '../../core/contracts.js';

// Map a session permission mode (Claude PermMode OR Codex sandbox mode) onto the
// app-server thread/start params. Replaces the exec-era CLI flag builder (permModeArgs).

export interface ThreadPolicy {
  approvalPolicy: 'never' | 'on-request';
  sandbox: 'read-only' | 'workspace-write' | 'danger-full-access';
}

export function resolveThreadPolicy(permMode: string): ThreadPolicy {
  if (isCodexSandboxMode(permMode)) {
    switch (permMode) {
      case 'read-only':
        return { approvalPolicy: 'on-request', sandbox: 'read-only' };
      case 'danger-full-access':
        return { approvalPolicy: 'never', sandbox: 'danger-full-access' };
      case 'workspace-write':
      default:
        return { approvalPolicy: 'on-request', sandbox: 'workspace-write' };
    }
  }

  switch (permMode as PermMode) {
    case 'acceptEdits':
      return { approvalPolicy: 'never', sandbox: 'workspace-write' };
    case 'bypassPermissions':
      return { approvalPolicy: 'never', sandbox: 'danger-full-access' };
    case 'plan':
      return { approvalPolicy: 'on-request', sandbox: 'read-only' };
    case 'default':
    default:
      return { approvalPolicy: 'on-request', sandbox: 'workspace-write' };
  }
}

// True when the policy auto-approves (no Discord Allow/Deny needed).
export function isAutoApprovePolicy(policy: ThreadPolicy): boolean {
  return policy.approvalPolicy === 'never';
}
