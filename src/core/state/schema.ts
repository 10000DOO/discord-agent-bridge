import { z } from 'zod';

// AppState v2 zod schemas + inferred types. See docs/DESIGN.md §8 (state.json).
// Runtime bindings keyed by "<guildId>:<channelId>"; enables resume-on-boot.
// Unknown fields are tolerated on read and normalized (dropped) on write, since
// z.object() strips keys not in the schema.

// Permission modes a SESSION binding may carry (mirrors contracts.ts SessionPermMode):
// the full Claude PermMode set (SDK's PermissionMode incl. 'dontAsk'/'auto') PLUS the
// Codex-native sandbox modes a Codex session can be started with from the wizard, so a
// saved Codex binding validates and resume-on-boot restores it.
export const permModeSchema = z.enum([
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
  'dontAsk',
  'auto',
  'read-only',
  'workspace-write',
  'danger-full-access',
]);

export const STATE_VERSION = 2;

export const channelBindingSchema = z.object({
  guildId: z.string(),
  // Backend id. z.string() (not a fixed enum) so a binding written by a build that
  // registered an extra mode still parses here — a single unknown value no longer makes
  // appStateSchema.parse reject the WHOLE channels record (which would lose every
  // binding). resumeAll() then skips only the unregistered binding via its per-binding
  // modeRegistry.get() guard (§5.3). Existing "claude"/"codex"/"custom" pass unchanged.
  mode: z.string(),
  sessionId: z.string().nullable(),
  cwd: z.string(),
  ownerId: z.string(),
  permissionMode: permModeSchema,
  permissionProfile: z.string().nullable(),
  // Wizard-chosen model (Claude id/alias or Codex id). Optional so older state.json
  // files without it still validate.
  model: z.string().optional(),
  // Reasoning effort chosen in the wizard or via /effort (Claude level or Codex level).
  // Optional so older state.json files without it still validate; restored on resume so a
  // saved effort survives restarts.
  effort: z.string().optional(),
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

// Auto-update bookkeeping (§8). lastCheckAt guards the 24h cadence across restarts;
// dismissedVersion silences a version the operator declined (a newer one re-enables it).
// A .default (like scheduledCommands) means NO version bump / migration is needed — an
// existing state.json without the field loads with the default.
export const autoUpdateStateSchema = z
  .object({
    lastCheckAt: z.number(),
    dismissedVersion: z.string().nullable(),
  })
  .default({ lastCheckAt: 0, dismissedVersion: null });

// A session-config draft captured at wizard 'done' so the "💾 save as preset" name modal
// can persist it even across a restart (the router's in-memory draft Map is otherwise lost).
// Keyed by channelKey ("<guildId>:<channelId>") in appStateSchema.presetDrafts. Fields
// mirror interactionRouter.ts PresetDraft exactly (profile is nullable).
export const presetDraftStateSchema = z.object({
  backend: z.string(),
  model: z.string().optional(),
  effort: z.string().optional(),
  permMode: z.string().optional(),
  profile: z.string().nullable().optional(),
});

export const appStateSchema = z.object({
  version: z.number(),
  channels: z.record(z.string(), channelBindingSchema),
  scheduledCommands: z.array(z.unknown()).default([]),
  autoUpdate: autoUpdateStateSchema,
  // Preset drafts backed up per channel. A .default({}) (like scheduledCommands) means NO
  // version bump / migration — an existing state.json without the field loads empty.
  presetDrafts: z.record(z.string(), presetDraftStateSchema).default({}),
});

export type AppState = z.infer<typeof appStateSchema>;
export type ChannelBindingState = z.infer<typeof channelBindingSchema>;
export type AutoUpdateState = z.infer<typeof autoUpdateStateSchema>;
export type PresetDraftState = z.infer<typeof presetDraftStateSchema>;

// A fresh, empty v2 state used when no state.json exists yet.
export function emptyState(): AppState {
  return {
    version: STATE_VERSION,
    channels: {},
    scheduledCommands: [],
    autoUpdate: { lastCheckAt: 0, dismissedVersion: null },
    presetDrafts: {},
  };
}
