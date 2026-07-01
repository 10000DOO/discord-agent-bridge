import type { AgentEvent } from './contracts.js';

// TODO(Phase 1): typed pub/sub of AgentEvent per channel (§4, §6).
export type AgentEventListener = (ev: AgentEvent) => void;

export class EventBus {
  publish(_guildId: string, _channelId: string, _ev: AgentEvent): void {
    throw new Error('not implemented');
  }

  subscribe(_guildId: string, _channelId: string, _listener: AgentEventListener): () => void {
    throw new Error('not implemented');
  }
}
