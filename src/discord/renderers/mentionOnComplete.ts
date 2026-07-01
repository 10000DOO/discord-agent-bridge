import type { AgentEvent } from '../../core/contracts.js';
import type { MessageChannel } from '../ports.js';

// @mention the session owner when a turn finishes (§6, §9 step 2). On a `result`
// event, post a message that pings the owner so they are notified their turn is
// done. Pure port sink; the owner id is injected (the channel binding's ownerId).

export interface MentionOnCompleteDeps {
  channel: MessageChannel;
  ownerId: string;
}

export class MentionOnCompleteHandler {
  private readonly channel: MessageChannel;
  private readonly ownerId: string;

  constructor(deps: MentionOnCompleteDeps) {
    this.channel = deps.channel;
    this.ownerId = deps.ownerId;
  }

  async handle(_ev: Extract<AgentEvent, { kind: 'result' }>): Promise<void> {
    // No owner bound (e.g. a resumed binding missing its ownerId) → skip the mention
    // rather than post a broken `<@>` that pings no one.
    if (!this.ownerId) return;
    await this.channel.send({
      content: `<@${this.ownerId}>`,
      mentionUserIds: [this.ownerId],
    });
  }
}
