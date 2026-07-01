import type { AgentEvent, Capabilities } from '../../core/contracts.js';

// TODO(Phase 1): subscribe the channel's AgentEvent stream; for each event invoke the matching
// renderer ONLY IF the mode's capability flag is set. Renderers never touch a backend (§6).
export class RendererDispatcher {
  dispatch(_ev: AgentEvent, _capabilities: Capabilities): void {
    throw new Error('not implemented');
  }
}
