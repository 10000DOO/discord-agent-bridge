import type { ModeConfigView } from './contracts.js';

// TODO(Phase 1): 3-level layering (global → server → project). See docs/DESIGN.md §8.1.
// The most specific present value wins; absent levels fall through.
// Auth allowlists at a narrower level narrow access (intersect), never widen.
export class ConfigResolver {
  resolveModeConfig(_guildId: string, _channelId: string): ModeConfigView {
    throw new Error('not implemented');
  }
}
