import type { PermMode } from './contracts.js';
import type { PolicyTier } from './commandPolicy.js';

// TODO(Phase 1): permission mode + named profiles; layered global→server→project (§7A, §8).
export interface PermissionProfile {
  permissionMode: PermMode;
  allowedTools: string[];
  policyTier: PolicyTier | 'normal' | 'relaxed';
}

export interface ResolvedPermission {
  permMode: PermMode;
  profile: string | null;
  allowedTools: string[];
}

export class PermissionResolver {
  resolve(_guildId: string, _channelId: string): ResolvedPermission {
    throw new Error('not implemented');
  }
}
