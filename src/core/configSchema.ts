import { z } from 'zod';

// zod schemas + inferred types for the GLOBAL config.json and per-server
// servers/<guildId>.json. Grounded in docs/DESIGN.md §8.1 (the 3-level hierarchy).
// Unknown fields are tolerated on read; DEFAULTS fill missing fields on load.

// Permission modes accepted by backends (mirrors contracts.ts PermMode; §7A).
export const permModeSchema = z.enum([
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
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
    mode: z.enum(['claude', 'codex']),
    claudeModel: z.string(),
    permissionMode: permModeSchema,
    permissionProfile: z.string().nullable(),
    codexHome: z.string(),
    codexCliCommand: z.string(),
    codexCliVersion: z.string().nullable(),
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
  locale: z.string(),
  logLevel: z.enum(['debug', 'info', 'warn', 'error']),
  favorites: z.array(z.string()),
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
      mode: z.enum(['claude', 'codex']),
      claudeModel: z.string(),
      permissionMode: permModeSchema,
      permissionProfile: z.string().nullable(),
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
  auditChannelId: z.string().nullable().optional(),
  favorites: z.array(z.string()).optional(),
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
    permissionMode: 'default' as const,
    permissionProfile: null,
    codexHome: '~/.codex',
    codexCliCommand: 'codex',
    codexCliVersion: null,
  },
  limits: {
    maxSessionsPerUser: 0,
    permissionTimeoutSec: 60,
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
    cacheSec: 180,
  },
  audit: {
    channelId: null,
  },
  locale: 'ko',
  logLevel: 'info' as const,
  favorites: [] as string[],
} satisfies Omit<AppConfig, 'discord'>;
