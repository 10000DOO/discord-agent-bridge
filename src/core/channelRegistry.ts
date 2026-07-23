import type { SessionPermMode } from './contracts.js';
import { StateStore } from './state/store.js';
import type { ChannelBindingState } from './state/schema.js';

// The binding "channel → { mode, sessionId, cwd, ownerId, permissionMode, ... }",
// keyed by "<guildId>:<channelId>". This is the source of truth for which channel
// runs which mode/session (§4, §8). Backed by the chunk-1 StateStore: bindings are
// loaded once on init and every mutation persists by reloading the AppState fresh and
// replacing ONLY its `channels` field via the store's atomic write. This class owns
// just `channels`; other top-level fields are never re-written from a boot snapshot.
// See docs/DESIGN.md §8 (state.json channels).

// Per-project access control carried on a binding (§7.1/§8, narrows only).
export interface ProjectAuth {
  allowedRoleIds: string[];
  allowedUserIds: string[];
}

// In-memory view of one channel binding. Uses guildId+channelId as separate
// fields (the store key is derived) and the contract's PermMode type.
export interface ChannelBinding {
  guildId: string;
  channelId: string;
  // Backend id (a registered mode.name). Plain string, not a fixed union: the
  // ModeRegistry is the single validity gate at use sites (§5), so a new backend needs
  // no edit here.
  mode: string;
  sessionId: string | null;
  cwd: string;
  ownerId: string;
  // A Claude PermMode, or a Codex sandbox mode when a Codex session was started with
  // one from the wizard (persisted so resume-on-boot restores the same choice).
  permMode: SessionPermMode;
  profile: string | null;
  // Model chosen in the wizard (a Claude model id/alias, or a Codex model id when mode
  // is 'codex'); persisted so reactivation/resume restores the same choice. Absent =
  // the resolved config default.
  model?: string;
  // Reasoning effort chosen in the wizard or via /effort (a Claude level, or a Codex level
  // when mode is 'codex'); persisted so reactivation/resume restores the same choice.
  // Absent = each backend's own default.
  effort?: string;
  projectAuth?: ProjectAuth;
  archived: boolean;
  createdAt: string;
  updatedAt: string;
}

// Fields the caller supplies when creating/replacing a binding; timestamps and
// archived default here so callers need not manage them.
export type ChannelBindingInput = Omit<
  ChannelBinding,
  'createdAt' | 'updatedAt' | 'archived'
> & { archived?: boolean };

function key(guildId: string, channelId: string): string {
  return `${guildId}:${channelId}`;
}

// state.json stores channels keyed by "<guildId>:<channelId>" and does NOT store
// channelId inside the binding, so it is recovered from the key on load.
function fromState(guildId: string, channelId: string, s: ChannelBindingState): ChannelBinding {
  return {
    guildId,
    channelId,
    mode: s.mode,
    sessionId: s.sessionId,
    cwd: s.cwd,
    ownerId: s.ownerId,
    permMode: s.permissionMode,
    profile: s.permissionProfile,
    ...(s.model !== undefined ? { model: s.model } : {}),
    ...(s.effort !== undefined ? { effort: s.effort } : {}),
    projectAuth: s.projectAuth,
    archived: s.archived,
    createdAt: s.createdAt,
    updatedAt: s.updatedAt,
  };
}

function toState(b: ChannelBinding): ChannelBindingState {
  return {
    guildId: b.guildId,
    mode: b.mode,
    sessionId: b.sessionId,
    cwd: b.cwd,
    ownerId: b.ownerId,
    permissionMode: b.permMode,
    permissionProfile: b.profile,
    ...(b.model !== undefined ? { model: b.model } : {}),
    ...(b.effort !== undefined ? { effort: b.effort } : {}),
    ...(b.projectAuth ? { projectAuth: b.projectAuth } : {}),
    createdAt: b.createdAt,
    updatedAt: b.updatedAt,
    archived: b.archived,
  };
}

export class ChannelRegistry {
  private readonly store: StateStore;
  // In-memory cache of the channels map, loaded from the store on construction
  // and kept in sync on every mutation (each mutation also persists).
  private readonly bindings = new Map<string, ChannelBinding>();

  constructor(store: StateStore, private readonly now: () => string = () => new Date().toISOString()) {
    this.store = store;
    // Boot load is used ONLY to seed the in-memory bindings; it is not held as a
    // save source. persist() reloads fresh so out-of-band writes to other top-level
    // fields are preserved (see persist()).
    const initial = store.load();
    for (const [k, binding] of Object.entries(initial.channels)) {
      const [guildId, channelId] = splitKey(k);
      this.bindings.set(k, fromState(guildId, channelId, binding));
    }
  }

  get(guildId: string, channelId: string): ChannelBinding | undefined {
    return this.bindings.get(key(guildId, channelId));
  }

  // All bindings, insertion-ordered. Callers that need only active channels
  // filter on `archived` themselves.
  list(): ChannelBinding[] {
    return [...this.bindings.values()];
  }

  // Create or replace a binding, then persist. createdAt is preserved across a
  // replace; updatedAt is refreshed on every write.
  set(input: ChannelBindingInput): ChannelBinding {
    const k = key(input.guildId, input.channelId);
    const existing = this.bindings.get(k);
    const timestamp = this.now();
    const binding: ChannelBinding = {
      ...input,
      archived: input.archived ?? existing?.archived ?? false,
      createdAt: existing?.createdAt ?? timestamp,
      updatedAt: timestamp,
    };
    this.bindings.set(k, binding);
    this.persist();
    return binding;
  }

  // Delete a binding, then persist. Returns whether one was present.
  remove(guildId: string, channelId: string): boolean {
    const existed = this.bindings.delete(key(guildId, channelId));
    if (existed) this.persist();
    return existed;
  }

  // Soft-delete: keep the binding but flag it archived (resume-on-boot skips it).
  // Returns the updated binding, or undefined if the channel is unknown.
  markArchived(guildId: string, channelId: string): ChannelBinding | undefined {
    const k = key(guildId, channelId);
    const existing = this.bindings.get(k);
    if (!existing) return undefined;
    const binding: ChannelBinding = { ...existing, archived: true, updatedAt: this.now() };
    this.bindings.set(k, binding);
    this.persist();
    return binding;
  }

  // Reload the AppState fresh, replace ONLY its `channels` with the serialized
  // in-memory map, and write it atomically. Reloading on every persist (rather than
  // re-saving a boot snapshot) is what keeps out-of-band writers to other top-level
  // fields (presetDrafts, autoUpdate, scheduledCommands) from being clobbered by a
  // stale in-memory copy. The per-call load is negligible — persist() fires only on a
  // binding change and state.json is tiny, so correctness wins over the round-trip.
  // The store validates and normalizes (unknown fields dropped) on write.
  private persist(): void {
    const fresh = this.store.load();
    const channels: Record<string, ChannelBindingState> = {};
    for (const [k, binding] of this.bindings) {
      channels[k] = toState(binding);
    }
    fresh.channels = channels;
    this.store.save(fresh);
  }
}

function splitKey(k: string): [string, string] {
  const idx = k.indexOf(':');
  if (idx < 0) return [k, ''];
  return [k.slice(0, idx), k.slice(idx + 1)];
}
