import type { SessionPermMode } from './contracts.js';
import { StateStore } from './state/store.js';
import type { AppState, ChannelBindingState } from './state/schema.js';

// The binding "channel → { mode, sessionId, cwd, ownerId, permissionMode, ... }",
// keyed by "<guildId>:<channelId>". This is the source of truth for which channel
// runs which mode/session (§4, §8). Backed by the chunk-1 StateStore: the whole
// AppState is loaded once on init and every mutation is persisted through the
// store's atomic write. See docs/DESIGN.md §8 (state.json channels).

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
  mode: 'claude' | 'codex';
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
  // The full AppState loaded once at construction and held as the in-memory
  // source of truth. persist() mutates only its `channels` and re-saves it, so
  // non-channel top-level fields (e.g. scheduledCommands) are preserved without a
  // reload-then-clobber round-trip on every mutation.
  private readonly state: AppState;

  constructor(store: StateStore, private readonly now: () => string = () => new Date().toISOString()) {
    this.store = store;
    this.state = store.load();
    for (const [k, binding] of Object.entries(this.state.channels)) {
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

  // Serialize the in-memory map into the held AppState's `channels` and write it
  // atomically. The held state is the source of truth, so non-channel fields
  // (e.g. scheduledCommands) are preserved without reloading from disk. The store
  // validates and normalizes (unknown fields dropped) on write.
  private persist(): void {
    const channels: Record<string, ChannelBindingState> = {};
    for (const [k, binding] of this.bindings) {
      channels[k] = toState(binding);
    }
    this.state.channels = channels;
    this.store.save(this.state);
  }
}

function splitKey(k: string): [string, string] {
  const idx = k.indexOf(':');
  if (idx < 0) return [k, ''];
  return [k.slice(0, idx), k.slice(idx + 1)];
}
