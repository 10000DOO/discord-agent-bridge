// TODO(Phase 1): buttons / selects / modals dispatch. Calls authorize() before routing (§4, §7.1).
export class InteractionRouter {
  handle(_interaction: unknown): Promise<void> {
    throw new Error('not implemented');
  }
}
