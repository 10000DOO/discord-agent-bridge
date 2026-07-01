import { describe, it, expect } from 'vitest';
import {
  PermissionButtonsHandler,
  buildCustomId,
  parseCustomId,
} from './permissionButtons.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';

// A fake channel that records what was sent and hands back an editable message.
function fakeChannel() {
  const sent: OutgoingMessage[] = [];
  const edits: OutgoingMessage[] = [];
  const channel: MessageChannel = {
    async send(message) {
      sent.push(message);
      const msg: EditableMessage = {
        id: `m${sent.length}`,
        async edit(m) {
          edits.push(m);
        },
      };
      return msg;
    },
    async startThread() {
      throw new Error('not used');
    },
  };
  return { channel, sent, edits };
}

const req: Extract<AgentEvent, { kind: 'permission_request' }> = {
  kind: 'permission_request',
  id: 'abc123',
  toolName: 'Bash',
  input: { command: 'ls' },
};

describe('permissionButtons custom_id', () => {
  it('builds and parses perm:<id>:<action>', () => {
    expect(buildCustomId('abc123', 'allow')).toBe('perm:abc123:allow');
    expect(parseCustomId('perm:abc123:deny')).toEqual({ reqId: 'abc123', action: 'deny' });
  });

  it('rejects foreign or malformed ids', () => {
    expect(parseCustomId('dir:into:foo')).toBeNull();
    expect(parseCustomId('perm:abc123:bogus')).toBeNull();
    expect(parseCustomId('perm:abc123')).toBeNull();
  });
});

describe('PermissionButtonsHandler', () => {
  it('resolves the pending decision to allow on perm:<id>:allow', async () => {
    const { channel } = fakeChannel();
    const handler = new PermissionButtonsHandler({ channel });
    const pending = handler.request(req);

    const applied = await handler.resolve(buildCustomId('abc123', 'allow'));
    expect(applied).toEqual({ behavior: 'allow' });
    await expect(pending).resolves.toEqual({ behavior: 'allow' });
  });

  it('resolves to deny on perm:<id>:deny', async () => {
    const { channel } = fakeChannel();
    const handler = new PermissionButtonsHandler({ channel });
    const pending = handler.request(req);

    const applied = await handler.resolve(buildCustomId('abc123', 'deny'));
    expect(applied?.behavior).toBe('deny');
    await expect(pending).resolves.toMatchObject({ behavior: 'deny' });
  });

  it('treats always-allow as allow for the immediate decision', async () => {
    const { channel } = fakeChannel();
    const handler = new PermissionButtonsHandler({ channel });
    const pending = handler.request(req);

    await handler.resolve(buildCustomId('abc123', 'always'));
    await expect(pending).resolves.toEqual({ behavior: 'allow' });
  });

  it('is idempotent / safe for unknown or already-resolved ids', async () => {
    const { channel } = fakeChannel();
    const handler = new PermissionButtonsHandler({ channel });
    handler.request(req);
    await handler.resolve(buildCustomId('abc123', 'allow'));
    // A second resolve of the same id is a no-op.
    expect(await handler.resolve(buildCustomId('abc123', 'allow'))).toBeNull();
    // An unknown id is a no-op.
    expect(await handler.resolve(buildCustomId('zzz', 'deny'))).toBeNull();
  });

  it('posts buttons then disables them on decision', async () => {
    const { channel, sent, edits } = fakeChannel();
    const handler = new PermissionButtonsHandler({ channel });
    handler.request(req);
    // Let the buttons message finish posting so the disabling edit can target it.
    await new Promise((r) => setImmediate(r));
    expect(sent).toHaveLength(1);
    expect(sent[0].components?.[0].components).toHaveLength(3); // allow/always/deny
    await handler.resolve(buildCustomId('abc123', 'allow'));
    expect(edits).toHaveLength(1);
    expect(edits[0].components).toEqual([]); // buttons removed
  });
});
