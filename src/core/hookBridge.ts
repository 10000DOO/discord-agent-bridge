// TODO(Phase 1): local loopback-only, token-guarded endpoint receiving agent-hook events
// → emits into the originating channel's renderer stream. See docs/DESIGN.md §7.6.
export class HookBridge {
  start(): Promise<void> {
    throw new Error('not implemented');
  }

  stop(): Promise<void> {
    throw new Error('not implemented');
  }
}
