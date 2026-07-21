import { z } from 'zod';

// zod schemas + inferred types for the GLOBAL config.json and per-server
// servers/<guildId>.json. Grounded in docs/DESIGN.md §8.1 (the 3-level hierarchy).
// Unknown fields are tolerated on read; DEFAULTS fill missing fields on load.

// Permission modes accepted by backends (mirrors contracts.ts PermMode = the SDK's
// full PermissionMode set; §7A). Includes 'dontAsk'/'auto' so saving any Claude mode
// validates; Codex offers only the subset it can map (see providerCatalog).
export const permModeSchema = z.enum([
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
  'dontAsk',
  'auto',
]);

// A named permission profile (§7A). policyTier maps onto the command-policy tier.
export const profileSchema = z.object({
  permissionMode: permModeSchema,
  allowedTools: z.array(z.string()),
  policyTier: z.string(),
});

// DM handling for messages outside a guild (§7.1).
export const dmPolicySchema = z.enum(['deny', 'allow']);

// ---- GLOBAL config.json (§8.1) ----
export const configSchema = z.object({
  version: z.number(),
  discord: z.object({
    token: z.string(),
    clientId: z.string(),
  }),
  auth: z.object({
    adminRoleIds: z.array(z.string()),
    executeRoleIds: z.array(z.string()),
    readOnlyRoleIds: z.array(z.string()),
    dmPolicy: dmPolicySchema,
  }),
  defaults: z.object({
    // Backend id. z.string() (not a fixed enum) so a newly registered mode's id loads
    // without a schema edit — the ModeRegistry is the single validity gate at use sites
    // (§5). Existing "claude"/"codex"/"custom" values pass unchanged (value-compatible).
    mode: z.string(),
    claudeModel: z.string(),
    codexModel: z.string(),
    permissionMode: permModeSchema,
    permissionProfile: z.string().nullable(),
    codexHome: z.string(),
    codexCliCommand: z.string(),
    codexCliVersion: z.string().nullable(),
    // Reasoning effort per backend. Optional: an unset value defers to each mode's
    // own default (Claude SDK's EffortLevel default; Codex CLI's config.toml
    // model_reasoning_effort). The wizard / `/config` panel offer per-backend option
    // lists narrowed by the SDK's supportedEffortLevels when reported.
    claudeEffort: z.string().optional(),
    codexEffort: z.string().optional(),
  }),
  limits: z.object({
    maxSessionsPerUser: z.number(),
    permissionTimeoutSec: z.number(),
    codexTimeoutMs: z.number(),
  }),
  policy: z.object({
    unknownCommand: z.enum(['confirm', 'allow', 'deny']),
    allowExtraCommands: z.array(z.string()),
  }),
  autoAllowClaudeTools: z.array(z.string()),
  profiles: z.record(z.string(), profileSchema),
  usage: z.object({
    userAgent: z.string(),
    cacheSec: z.number(),
  }),
  audit: z.object({
    channelId: z.string().nullable(),
  }),
  // Image rendering (tables/mermaid → PNG). GLOBAL only — Chromium is a single host
  // resource shared by all guilds, so the toggle is host-wide (no per-server override).
  // Optional with a default so existing config.json files load unchanged.
  render: z
    .object({
      enabled: z.boolean(),
    })
    .optional(),
  // Chromium provisioning decision (host-wide). 'undecided' → the /init prompt may offer
  // the install button; 'declined' → never re-prompt (only /config can re-enable);
  // 'accepted' → the operator opted in. The installed state itself is NOT stored here —
  // it is detected on disk (chromiumProvisioner) to avoid drift.
  chromium: z
    .object({
      decision: z.enum(['undecided', 'accepted', 'declined']),
    })
    .optional(),
  locale: z.string(),
  logLevel: z.enum(['debug', 'info', 'warn', 'error']),
  favorites: z.array(z.string()),
  // Host-wide auto-update toggle (§8). Filled by CONFIG_DEFAULTS/applyDefaults so an
  // existing config.json without it still loads. The 24h cadence stays a constant
  // (not exposed); on/off is edited directly in config.json (no /config or wizard UI).
  autoUpdate: z.object({
    enabled: z.boolean(),
  }),
});

export type AppConfig = z.infer<typeof configSchema>;

// ---- per-server servers/<guildId>.json (§8.1) — all overrides optional ----
export const serverConfigSchema = z.object({
  version: z.number(),
  guildId: z.string(),
  auth: z
    .object({
      adminRoleIds: z.array(z.string()),
      executeRoleIds: z.array(z.string()),
      readOnlyRoleIds: z.array(z.string()),
    })
    .partial()
    .optional(),
  defaults: z
    .object({
      // z.string() (not a fixed enum) — see the global defaults.mode note above.
      mode: z.string(),
      claudeModel: z.string(),
      codexModel: z.string(),
      permissionMode: permModeSchema,
      permissionProfile: z.string().nullable(),
      codexHome: z.string(),
      claudeEffort: z.string(),
      codexEffort: z.string(),
    })
    .partial()
    .optional(),
  limits: z
    .object({
      maxSessionsPerUser: z.number(),
      permissionTimeoutSec: z.number(),
      codexTimeoutMs: z.number(),
    })
    .partial()
    .optional(),
  // Per-guild UI language (§8.1 locale can now be set per-server in /config; global
  // config.locale remains the process-wide default the i18n catalog reads at boot).
  locale: z.string().optional(),
  auditChannelId: z.string().nullable().optional(),
  favorites: z.array(z.string()).optional(),
  // A4D-style channel structure created by /init and persisted here so it can be
  // reused (idempotent re-init) and so /agent start knows where to put new session
  // channels. Absent until /init runs. controlChannelId is where the session-start UI
  // lives; sessionsCategoryId parents auto-created per-project session channels.
  channels: z
    .object({
      categoryId: z.string(),
      controlChannelId: z.string(),
      sessionsCategoryId: z.string(),
      statusChannelId: z.string().nullable(),
    })
    .optional(),
  // Per-guild event notifications: forward key agent events (result/error, optionally
  // tool_use) from every session channel to ONE status channel as compact summary
  // lines. All fields optional; resolution defaults are applied in code where read
  // (enabled=true; channelId falls back to channels.statusChannelId; events =
  // {result:true, error:true, toolUse:false}). See discord/notifier.ts.
  notifications: z
    .object({
      enabled: z.boolean().optional(),
      channelId: z.string().nullable().optional(),
      events: z
        .object({
          result: z.boolean().optional(),
          error: z.boolean().optional(),
          toolUse: z.boolean().optional(),
        })
        .optional(),
    })
    .optional(),
});

export type ServerConfig = z.infer<typeof serverConfigSchema>;

// Current config schema version.
export const CONFIG_VERSION = 2;

// DEFAULTS applied for any field missing from a loaded config.json (§8.1).
// Secrets (discord.token/clientId) have no default — they must be present.
export const CONFIG_DEFAULTS = {
  version: CONFIG_VERSION,
  auth: {
    adminRoleIds: [] as string[],
    executeRoleIds: [] as string[],
    readOnlyRoleIds: [] as string[],
    dmPolicy: 'deny' as const,
  },
  defaults: {
    mode: 'claude' as const,
    claudeModel: 'opus',
    // Empty → the CodexMode omits `-m`, so `codex` uses its own config.toml default
    // model (operator-configured). Set a value here to force a specific Codex model.
    codexModel: '',
    permissionMode: 'default' as const,
    permissionProfile: null,
    codexHome: '~/.codex',
    codexCliCommand: 'codex',
    codexCliVersion: null,
  },
  limits: {
    maxSessionsPerUser: 0,
    // 0 → no timer, the Allow/Always/Deny prompt waits indefinitely for a click
    // (see wiring.ts withTimeout). Prevents auto-deny on slow responders.
    permissionTimeoutSec: 0,
    codexTimeoutMs: 1_800_000,
  },
  policy: {
    unknownCommand: 'confirm' as const,
    allowExtraCommands: [] as string[],
  },
  autoAllowClaudeTools: ['Read', 'Glob', 'Grep'],
  profiles: {} as Record<string, z.infer<typeof profileSchema>>,
  usage: {
    userAgent: 'claude-code',
    cacheSec: 15,
  },
  audit: {
    channelId: null,
  },
  render: {
    enabled: true,
  },
  chromium: {
    decision: 'undecided' as const,
  },
  locale: 'ko',
  logLevel: 'info' as const,
  favorites: [] as string[],
  // Auto-update is ON by default; disable by setting "autoUpdate": { "enabled": false }
  // in config.json (documented; no in-app toggle — §14).
  autoUpdate: { enabled: true },
} satisfies Omit<AppConfig, 'discord'>;
