import { describe, it, expect } from 'vitest';
import { MentionOnCompleteHandler } from './mentionOnComplete.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';

// A fake channel recording every sent message.
function fakeChannel(): { channel: MessageChannel; sent: OutgoingMessage[] } {
  const sent: OutgoingMessage[] = [];
  const channel: MessageChannel = {
    async send(message) {
      sent.push(message);
      const em: EditableMessage = { id: `m${sent.length}`, async edit() {} };
      return em;
    },
    async startThread() {
      throw new Error('not used');
    },
  };
  return { channel, sent };
}

const resultEv: Extract<AgentEvent, { kind: 'result' }> = { kind: 'result', text: 'done' };

describe('MentionOnCompleteHandler', () => {
  it('mentions the owner on completion when an ownerId is bound', async () => {
    const { channel, sent } = fakeChannel();
    const handler = new MentionOnCompleteHandler({ channel, ownerId: 'owner-9' });
    await handler.handle(resultEv);
    expect(sent).toHaveLength(1);
    expect(sent[0].content).toBe('<@owner-9>');
    expect(sent[0].mentionUserIds).toEqual(['owner-9']);
  });

  it('posts NO message when the ownerId is empty (no broken <@> ping)', async () => {
    const { channel, sent } = fakeChannel();
    const handler = new MentionOnCompleteHandler({ channel, ownerId: '' });
    await handler.handle(resultEv);
    expect(sent).toHaveLength(0);
  });
});
