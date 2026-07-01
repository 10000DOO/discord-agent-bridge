// TODO(Phase 1): gateway client + intents (§4).
export class DiscordClient {
  login(_token: string): Promise<void> {
    throw new Error('not implemented');
  }

  destroy(): Promise<void> {
    throw new Error('not implemented');
  }
}
