import { z } from 'zod';

// AppState v2 zod schemas + inferred types. See docs/DESIGN.md §8 (state.json).
// Runtime bindings keyed by "<guildId>:<channelId>"; enables resume-on-boot.
// Unknown fields are tolerated on read and normalized (dropped) on write, since
// z.object() strips keys not in the schema.

// Permission modes (mirrors contracts.ts PermMode = the SDK's full PermissionMode
// set; §7A). Includes 'dontAsk'/'auto' so a saved Claude binding validates.
export const permModeSchema = z.enum([
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
  'dontAsk',
  'auto',
]);

export const STATE_VERSION = 2;

export const channelBindingSchema = z.object({
  guildId: z.string(),
  mode: z.enum(['claude', 'codex']),
  sessionId: z.string().nullable(),
  cwd: z.string(),
  ownerId: z.string(),
  permissionMode: permModeSchema,
  permissionProfile: z.string().nullable(),
  projectAuth: z
    .object({
      allowedRoleIds: z.array(z.string()),
      allowedUserIds: z.array(z.string()),
    })
    .optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
  archived: z.boolean(),
});

export const appStateSchema = z.object({
  version: z.number(),
  channels: z.record(z.string(), channelBindingSchema),
  scheduledCommands: z.array(z.unknown()).default([]),
});

export type AppState = z.infer<typeof appStateSchema>;
export type ChannelBindingState = z.infer<typeof channelBindingSchema>;

// A fresh, empty v2 state used when no state.json exists yet.
export function emptyState(): AppState {
  return { version: STATE_VERSION, channels: {}, scheduledCommands: [] };
}
