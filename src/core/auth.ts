// TODO(Phase 1): role-TIER gate + per-project ACL, evolved from CDC authorizeCommand (§7.1).
export type RoleTier = 'admin' | 'execute' | 'read-only';

export interface AuthResult {
  allowed: boolean;
  tier: RoleTier | null;
  reason?: string;
}

export interface AuthTarget {
  guildId: string;
  channelId: string;
}

// One function authorize(member, action, {guildId, channelId}) → {allowed, tier, reason}.
// Empty allowlist = deny all (fail-secure).
export function authorize(_memberId: string, _action: string, _target: AuthTarget): AuthResult {
  throw new Error('not implemented');
}
