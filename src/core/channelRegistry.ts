import type { PermMode } from './contracts.js';

// guildId+channelId → binding. See docs/DESIGN.md §4, §8 (state.json channels).
export interface ChannelBinding {
  guildId: string;
  channelId: string;
  mode: string;
  sessionId: string | null;
  cwd: string;
  ownerId: string;
  permMode: PermMode;
  profile: string | null;
}

// TODO(Phase 1): guildId+channelId → binding lookup/mutation, backed by state store (§4, §8).
export class ChannelRegistry {
  get(_guildId: string, _channelId: string): ChannelBinding | undefined {
    throw new Error('not implemented');
  }

  set(_binding: ChannelBinding): void {
    throw new Error('not implemented');
  }
}
