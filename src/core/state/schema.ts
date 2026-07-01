import { z } from 'zod';

// TODO(Phase 1): AppState types + zod validation. See docs/DESIGN.md §8 (state.json).
// Unknown fields tolerated on read, normalized on write.

export const channelBindingSchema = z.object({
  guildId: z.string(),
  mode: z.enum(['claude', 'codex']),
  sessionId: z.string().nullable(),
  cwd: z.string(),
  ownerId: z.string(),
  permissionMode: z.string(),
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
