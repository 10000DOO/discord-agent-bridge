import type { ConfigStore } from './config.js';
import type { ChannelRegistry } from './channelRegistry.js';
import type { AppConfig, ServerConfig } from './configSchema.js';

// Role-tier authorization gate (§7.1). Called by BOTH the message router and the
// interaction router BEFORE anything reaches a mode (§7.1 enforcement point).
// Deny-by-default (fail-secure): an empty allowlist grants nothing.
//
// Tier capability is nested: admin ⊇ execute ⊇ read-only. Auth allowlists resolve
// global → server (servers/<guildId>.json extends/overrides global, §7.1/§8.1);
// a per-project ACL on the channel binding then NARROWS access (intersect, §8.1
// "narrower level narrows, does not widen"). DM traffic (no guild) honors dmPolicy.

export type RoleTier = 'admin' | 'execute' | 'read-only';

// The actions a router can ask about. Each maps to a MINIMUM required tier.
export type AuthAction = 'admin' | 'drive' | 'run-command' | 'read';

// Tier ranking for the ⊇ relation (higher grants everything a lower one does).
const TIER_RANK: Record<RoleTier, number> = { 'read-only': 1, execute: 2, admin: 3 };

// Minimum tier each action requires. 'drive' (start session / run turn) and
// 'run-command' (!cmd) are the execute-tier "driver" actions (§7.1); 'read'
// (status/transcript/usage) needs only read-only; 'admin' needs admin.
const ACTION_MIN_TIER: Record<AuthAction, RoleTier> = {
  admin: 'admin',
  drive: 'execute',
  'run-command': 'execute',
  read: 'read-only',
};

// The actor + what they want to do + where. roleIds are the actor's Discord role
// ids as seen at the call site. guildId absent → DM context (dmPolicy applies).
export interface AuthInput {
  userId: string;
  roleIds: string[];
  action: AuthAction;
  context: { guildId?: string; channelId?: string };
}

export interface AuthResult {
  allowed: boolean;
  reason?: string;
  tier?: RoleTier;
}

// The effective auth allowlists after layering global → server.
interface EffectiveAuth {
  adminRoleIds: string[];
  executeRoleIds: string[];
  readOnlyRoleIds: string[];
  dmPolicy: AppConfig['auth']['dmPolicy'];
}

export class Authorizer {
  constructor(
    private readonly configStore: ConfigStore,
    private readonly channelRegistry: ChannelRegistry,
  ) {}

  authorize(input: AuthInput): AuthResult {
    const { guildId, channelId } = input.context;

    // No guild → DM. Deny unless dmPolicy explicitly allows (deny-by-default, §7.1).
    if (guildId === undefined) {
      const global = this.configStore.load();
      if (global.auth.dmPolicy !== 'allow') {
        return { allowed: false, reason: 'DMs are not permitted (dmPolicy=deny).' };
      }
      // DM allowed: fall through with global-only allowlists (no server layer for DMs).
      return this.decide(this.effectiveAuth(global, null), input, undefined);
    }

    const global = this.configStore.load();
    const server = this.configStore.loadServerConfig(guildId);
    const effective = this.effectiveAuth(global, server);

    const binding =
      channelId !== undefined ? this.channelRegistry.get(guildId, channelId) : undefined;
    return this.decide(effective, input, binding?.projectAuth);
  }

  // Layer server auth over global. A server allowlist, when present, replaces that
  // tier's global list (server-scoped override, §7.1/§8.1); an absent server field
  // falls through to global. Auth NARROWING happens at the project layer, not here.
  private effectiveAuth(global: AppConfig, server: ServerConfig | null): EffectiveAuth {
    const g = global.auth;
    const s = server?.auth;
    return {
      adminRoleIds: s?.adminRoleIds ?? g.adminRoleIds,
      executeRoleIds: s?.executeRoleIds ?? g.executeRoleIds,
      readOnlyRoleIds: s?.readOnlyRoleIds ?? g.readOnlyRoleIds,
      dmPolicy: g.dmPolicy,
    };
  }

  // Resolve the actor's highest tier from the allowlists, then check it clears the
  // action's minimum tier and (if present) the per-project ACL.
  private decide(
    auth: EffectiveAuth,
    input: AuthInput,
    projectAuth: { allowedRoleIds: string[]; allowedUserIds: string[] } | undefined,
  ): AuthResult {
    const tier = this.resolveTier(auth, input.roleIds);
    if (tier === null) {
      return { allowed: false, reason: 'No authorized role for this actor (fail-secure).' };
    }

    const required = ACTION_MIN_TIER[input.action];
    if (TIER_RANK[tier] < TIER_RANK[required]) {
      return {
        allowed: false,
        reason: `Action '${input.action}' requires '${required}'; actor tier is '${tier}'.`,
        tier,
      };
    }

    // Per-project ACL narrows access: when a binding lists allowed roles/users, the
    // actor must match one of them IN ADDITION to clearing the tier check (§7.1).
    if (projectAuth) {
      const allowedByUser = projectAuth.allowedUserIds.includes(input.userId);
      const allowedByRole = input.roleIds.some((r) => projectAuth.allowedRoleIds.includes(r));
      if (!allowedByUser && !allowedByRole) {
        return {
          allowed: false,
          reason: 'Actor is not in this project’s access list (projectAuth).',
          tier,
        };
      }
    }

    return { allowed: true, tier };
  }

  // Highest tier the actor's roles grant, or null if none match (deny-by-default).
  private resolveTier(auth: EffectiveAuth, roleIds: string[]): RoleTier | null {
    const roles = new Set(roleIds);
    const has = (allow: string[]): boolean => allow.some((id) => roles.has(id));
    if (has(auth.adminRoleIds)) return 'admin';
    if (has(auth.executeRoleIds)) return 'execute';
    if (has(auth.readOnlyRoleIds)) return 'read-only';
    return null;
  }
}
