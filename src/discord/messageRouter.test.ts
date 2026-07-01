import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { MessageRouter, type IncomingAttachment, type IncomingMessage } from './messageRouter.js';
import type { Authorizer, AuthResult } from '../core/auth.js';
import type { ChannelRegistry, ChannelBinding } from '../core/channelRegistry.js';
import type { SendResult, SessionOrchestrator } from '../core/sessionOrchestrator.js';
import type { TurnInput } from '../core/contracts.js';
import { createLogger } from '../core/logger.js';

// A silent logger (no console noise in the test run).
const logger = createLogger('test', { level: 'error', sink: { write() {} } });

// A binding for a Claude channel rooted at `cwd`.
function binding(cwd: string, overrides: Partial<ChannelBinding> = {}): ChannelBinding {
  return {
    guildId: 'g1',
    channelId: 'c1',
    mode: 'claude',
    sessionId: 's1',
    cwd,
    ownerId: 'owner',
    permMode: 'default',
    profile: null,
    archived: false,
    createdAt: 'now',
    updatedAt: 'now',
    ...overrides,
  };
}

// A fake IncomingMessage with recording reply/react.
function fakeMessage(over: Partial<IncomingMessage> & { attachments?: IncomingAttachment[] } = {}): {
  message: IncomingMessage;
  replies: string[];
  reactions: string[];
} {
  const replies: string[] = [];
  const reactions: string[] = [];
  const attachments = over.attachments ?? [];
  const message: IncomingMessage = {
    content: over.content ?? 'hello agent',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    author: over.author ?? { id: 'u1', bot: false },
    member: over.member ?? { roles: { cache: { map: (fn) => ['role-exec'].map((id) => fn({ id })) } } },
    attachments: { values: () => attachments },
    react: async (emoji) => {
      reactions.push(emoji);
    },
    reply: async (content) => {
      replies.push(content);
    },
  };
  return { message, replies, reactions };
}

// Registry/authorizer/orchestrator test doubles.
function makeDeps(opts: {
  binding?: ChannelBinding;
  auth?: AuthResult;
  sendResult?: SendResult;
  sendThrows?: Error;
  fetchBytes?: (url: string) => Promise<Uint8Array>;
}) {
  const sent: { guildId: string; channelId: string; turn: TurnInput }[] = [];
  const channelRegistry = {
    get: (_g: string, _c: string) => opts.binding,
  } as unknown as ChannelRegistry;
  const authorizer = {
    authorize: () => opts.auth ?? { allowed: true, tier: 'execute' as const },
  } as unknown as Authorizer;
  const orchestrator = {
    send: vi.fn(async (guildId: string, channelId: string, turn: TurnInput): Promise<SendResult> => {
      if (opts.sendThrows) throw opts.sendThrows;
      sent.push({ guildId, channelId, turn });
      return opts.sendResult ?? { status: 'started', queueDepth: 1 };
    }),
  } as unknown as SessionOrchestrator;
  const router = new MessageRouter({
    authorizer,
    channelRegistry,
    orchestrator,
    logger,
    fetchBytes: opts.fetchBytes ?? (async () => new Uint8Array([1, 2, 3])),
  });
  return { router, orchestrator, sent };
}

let ws: string;
beforeEach(() => {
  ws = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dab-msg-')));
});
afterEach(() => {
  fs.rmSync(ws, { recursive: true, force: true });
});

describe('MessageRouter', () => {
  it('ignores a message in an unbound channel (no send)', async () => {
    const { router, orchestrator } = makeDeps({ binding: undefined });
    const { message } = fakeMessage();
    await router.handle(message);
    expect(orchestrator.send).not.toHaveBeenCalled();
  });

  it('ignores a bot message', async () => {
    const { router, orchestrator } = makeDeps({ binding: binding(ws) });
    const { message } = fakeMessage({ author: { id: 'bot', bot: true } });
    await router.handle(message);
    expect(orchestrator.send).not.toHaveBeenCalled();
  });

  it('denied user → no orchestrator.send, gets an ephemeral notice', async () => {
    const { router, orchestrator } = makeDeps({
      binding: binding(ws),
      auth: { allowed: false, reason: 'No authorized role for this actor (fail-secure).' },
    });
    const { message, replies } = fakeMessage();
    await router.handle(message);
    expect(orchestrator.send).not.toHaveBeenCalled();
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain('권한이 없습니다');
  });

  it('allowed user → send called with the built TurnInput; started → 💬 reaction', async () => {
    const { router, sent } = makeDeps({ binding: binding(ws) });
    const { message, reactions } = fakeMessage({ content: 'do the thing' });
    await router.handle(message);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ guildId: 'g1', channelId: 'c1', turn: { text: 'do the thing' } });
    expect(reactions).toEqual(['💬']);
  });

  it('queued send → ⏳ reaction', async () => {
    const { router } = makeDeps({ binding: binding(ws), sendResult: { status: 'queued', queueDepth: 2 } });
    const { message, reactions } = fakeMessage();
    await router.handle(message);
    expect(reactions).toEqual(['⏳']);
  });

  it('downloads an attachment INTO the workspace and passes its confined path', async () => {
    const bytes = new Uint8Array([9, 9, 9]);
    const { router, sent } = makeDeps({ binding: binding(ws), fetchBytes: async () => bytes });
    const { message } = fakeMessage({
      attachments: [{ url: 'https://cdn/x', name: 'note.txt', contentType: 'text/plain' }],
    });
    await router.handle(message);
    expect(sent).toHaveLength(1);
    const file = sent[0].turn.files?.[0];
    expect(file).toBeDefined();
    // The saved path is inside the workspace root (confinement precondition).
    const rel = path.relative(ws, file!.path);
    expect(rel.startsWith('..')).toBe(false);
    expect(path.isAbsolute(rel)).toBe(false);
    expect(fs.readFileSync(file!.path)).toEqual(Buffer.from(bytes));
    expect(file!.mime).toBe('text/plain');
  });

  it('a crafted traversal filename is reduced to a safe basename inside the workspace', async () => {
    const { router, sent } = makeDeps({ binding: binding(ws) });
    const { message } = fakeMessage({
      attachments: [{ url: 'https://cdn/evil', name: '../../etc/passwd', contentType: null }],
    });
    await router.handle(message);
    const file = sent[0].turn.files?.[0];
    expect(file).toBeDefined();
    // Written under the attachment dir, not two levels up.
    const rel = path.relative(ws, file!.path);
    expect(rel.startsWith('..')).toBe(false);
    expect(path.basename(file!.path)).toBe('passwd');
  });

  it('an orchestrator confinement/no-session throw is surfaced as a notice, not a crash', async () => {
    const { router } = makeDeps({
      binding: binding(ws),
      sendThrows: new Error('File path escapes the workspace: /etc/passwd'),
    });
    const { message, replies } = fakeMessage();
    await expect(router.handle(message)).resolves.toBeUndefined();
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain('escapes the workspace');
  });
});
