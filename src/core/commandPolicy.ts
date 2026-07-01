// TODO(Phase 1): tiered command classifier ported from CDC policy.ts, fail-secure default (§7.2).
export type PolicyTier = 'safe-read' | 'normal-mutate' | 'dangerous-mutate';

export interface PolicyResult {
  tier: PolicyTier;
  requiresConfirmation: boolean;
  reason?: string;
}

// Fix C6: unknown-command default flips to 'dangerous-mutate' requiresConfirmation
// unless explicitly allowlisted (config.json.policy.allowExtraCommands).
export function classifyCommand(_command: string): PolicyResult {
  throw new Error('not implemented');
}
