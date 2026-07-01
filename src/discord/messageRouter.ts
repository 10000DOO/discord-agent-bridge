// TODO(Phase 1): message → turn (after authorize()); attachments path-confined into TurnInput (§4, §7.1, §9).
export class MessageRouter {
  handle(_message: unknown): Promise<void> {
    throw new Error('not implemented');
  }
}
