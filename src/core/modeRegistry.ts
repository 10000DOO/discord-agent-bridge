import type { AgentMode } from './contracts.js';

// TODO(Phase 1): name → AgentMode factory; single place to register modes (§4, §10).
export class ModeRegistry {
  register(_name: string, _factory: () => AgentMode): void {
    throw new Error('not implemented');
  }

  get(_name: string): AgentMode {
    throw new Error('not implemented');
  }
}
