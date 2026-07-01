import type { AppState } from './schema.js';

// TODO(Phase 1): versioned JSON, atomic write (tmp + rename), ordered migrations
// (incl. v1→v2 rekey <channelId> → <guildId>:<channelId>), zod-validated. See docs/DESIGN.md §8.
export class StateStore {
  load(): Promise<AppState> {
    throw new Error('not implemented');
  }

  save(_state: AppState): Promise<void> {
    throw new Error('not implemented');
  }
}
