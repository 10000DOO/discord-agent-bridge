import type { SessionPermMode } from './contracts.js';
import type { ConfigStore } from './config.js';
import type { ConfigResolver } from './configResolver.js';

// Resolve the effective permission MODE + profile for a channel by the same
// global→server→project layering as ConfigResolver (§7A/§8), with a per-session
// override on top. See docs/DESIGN.md §7A.
//
// Order of precedence (later wins):
//   1. layered defaults (global → server → project binding) via ConfigResolver
//   2. if a named profile resolves, its bundled permissionMode/allowedTools/tier
//   3. an explicit per-session override (mode and/or profile set live via /mode)

// Raw policy tiers (formerly commandPolicy.ts). §8.1 profiles may also use
// 'read-only' | 'normal' | 'relaxed' aliases — see ProfilePolicyTier.
export type PolicyTier = 'safe-read' | 'normal-mutate' | 'dangerous-mutate';

// The tier a profile maps onto. §8.1 profiles use 'read-only' | 'normal' |
// 'relaxed'; a profile may also name a raw PolicyTier.
export type ProfilePolicyTier = PolicyTier | 'read-only' | 'normal' | 'relaxed';

export interface ResolvedPermission {
  // A Claude PermMode from the layered config/profile, OR a Codex sandbox mode when the
  // wizard/override supplied one (only a codex session ever receives such a value).
  permMode: SessionPermMode;
  profile: string | null;
  allowedTools: string[];
  // Present only when the resolved profile declares a policy tier.
  policyTier?: ProfilePolicyTier;
}

// Live, per-session overrides applied on top of the layered defaults. Any field
// left undefined falls through to the layered value.
export interface SessionOverride {
  permMode?: SessionPermMode;
  profile?: string | null;
}

export class PermissionResolver {
  constructor(
    private readonly configStore: ConfigStore,
    private readonly configResolver: ConfigResolver,
  ) {}

  resolve(
    guildId: string,
    channelId: string,
    override?: SessionOverride,
  ): ResolvedPermission {
    const config = this.configStore.load();
    const layered = this.configResolver.resolve(guildId, channelId);

    // Profile: session override wins, else layered value. `null` explicitly
    // clears the profile; `undefined` falls through.
    const profileName =
      override && 'profile' in override ? (override.profile ?? null) : layered.permissionProfile;

    // Base permission mode from the layered defaults; the global auto-allow set
    // is the default tool allowlist when no profile narrows it. Widened to
    // SessionPermMode so a per-session override may carry a Codex sandbox mode.
    let permMode: SessionPermMode = layered.permissionMode;
    let allowedTools: string[] = [...config.autoAllowClaudeTools];
    let policyTier: ProfilePolicyTier | undefined;

    // A named profile bundles mode + tools + tier (§7A). Applied over the base.
    if (profileName) {
      const profile = config.profiles[profileName];
      if (!profile) {
        throw new Error(`Unknown permission profile '${profileName}'.`);
      }
      permMode = profile.permissionMode;
      allowedTools = [...profile.allowedTools];
      policyTier = profile.policyTier as ProfilePolicyTier;
    }

    // A directly-set per-session permission mode wins over everything, including
    // a profile's bundled mode (the operator explicitly overrode it via /mode).
    if (override?.permMode !== undefined) {
      permMode = override.permMode;
    }

    return {
      permMode,
      profile: profileName,
      allowedTools,
      ...(policyTier ? { policyTier } : {}),
    };
  }
}
