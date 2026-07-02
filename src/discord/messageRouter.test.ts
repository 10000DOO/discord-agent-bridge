import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { MessageRouter, type IncomingAttachment, type IncomingMessage } from './messageRouter.js';
import { Authorizer, type AuthResult } from '../core/auth.js';
import { ChannelRegistry, type ChannelBinding } from '../core/channelRegistry.js';
import { EventBus } from '../core/eventBus.js';
import type { SendResult, SessionOrchestrator } from '../core/sessionOrchestrator.js';
import type { TurnInput } from '../core/contracts.js';
import { ConfigStore } from '../core/config.js';
import { StateStore } from '../core/state/store.js';
import { CONFIG_VERSION, type AppConfig } from '../core/configSchema.js';
import { createLogger } from '../core/logger.js';

// The discord.js Administrator bit (PermissionFlagsBits.Administrator === 1<<3). The
// router defaults to this value, so a test member's permissions.has must recognize it.
const ADMIN_BIT = 1n << 3n;

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

// A fake IncomingMessage with recording reply/react/removeReaction. `reactFails`
// makes react throw (a missing Add-Reactions permission) so a test can assert the
// failure never propagates out of the router.
function fakeMessage(
  over: Partial<IncomingMessage> & {
    attachments?: IncomingAttachment[];
    reactFails?: boolean;
    withRemove?: boolean;
  } = {},
): {
  message: IncomingMessage;
  replies: string[];
  reactions: string[];
  removed: string[];
} {
  const replies: string[] = [];
  const reactions: string[] = [];
  const removed: string[] = [];
  const attachments = over.attachments ?? [];
  const message: IncomingMessage = {
    content: over.content ?? 'hello agent',
    guildId: over.guildId ?? 'g1',
    channelId: over.channelId ?? 'c1',
    author: over.author ?? { id: 'u1', bot: false },
    member: over.member ?? { roles: { cache: { map: (fn) => ['role-exec'].map((id) => fn({ id })) } } },
    attachments: { values: () => attachments },
    react: async (emoji) => {
      if (over.reactFails) throw new Error('Missing Add Reactions permission');
      reactions.push(emoji);
    },
    reply: async (content) => {
      replies.push(content);
    },
    // Present by default so completion-clearing tests can assert ⏳ was removed;
    // omit it (withRemove:false) to exercise the router's "no removeReaction" path.
    ...(over.withRemove === false
      ? {}
      : {
          removeReaction: async (emoji: string) => {
            removed.push(emoji);
          },
        }),
  };
  return { message, replies, reactions, removed };
}

// Registry/authorizer/orchestrator test doubles.
function makeDeps(opts: {
  binding?: ChannelBinding;
  auth?: AuthResult;
  sendResult?: SendResult;
  sendThrows?: Error;
  fetchBytes?: (url: string) => Promise<Uint8Array>;
  eventBus?: EventBus;
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
    ...(opts.eventBus ? { eventBus: opts.eventBus } : {}),
  });
  return { router, orchestrator, sent };
}

// Flush the microtask queue enough times for the fire-and-forget completion clear
// (removeReaction → safe → react → safe) to settle before asserting.
async function flush(): Promise<void> {
  for (let i = 0; i < 6; i++) await Promise.resolve();
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

  it('allowed user → send called with the built TurnInput; accepted turn → ⏳ reaction', async () => {
    const { router, sent } = makeDeps({ binding: binding(ws) });
    const { message, reactions } = fakeMessage({ content: 'do the thing' });
    await router.handle(message);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ guildId: 'g1', channelId: 'c1', turn: { text: 'do the thing' } });
    expect(reactions).toEqual(['⏳']);
  });

  it('queued send → still ⏳ reaction (the AI is preparing a response)', async () => {
    const { router } = makeDeps({ binding: binding(ws), sendResult: { status: 'queued', queueDepth: 2 } });
    const { message, reactions } = fakeMessage();
    await router.handle(message);
    expect(reactions).toEqual(['⏳']);
  });

  it('clears ⏳ and adds ✅ when the channel emits a result event', async () => {
    const eventBus = new EventBus();
    const { router } = makeDeps({ binding: binding(ws), eventBus });
    const { message, reactions, removed } = fakeMessage();
    await router.handle(message);
    expect(reactions).toEqual(['⏳']); // working indicator on, not yet cleared

    // The session's turn finishes for this channel.
    eventBus.emit('g1', 'c1', { kind: 'result', text: 'done' });
    await flush();

    expect(removed).toEqual(['⏳']); // working reaction removed
    expect(reactions).toEqual(['⏳', '✅']); // done reaction added
  });

  it('clears ⏳ and adds ❌ when the channel emits an error event', async () => {
    const eventBus = new EventBus();
    const { router } = makeDeps({ binding: binding(ws), eventBus });
    const { message, reactions, removed } = fakeMessage();
    await router.handle(message);

    eventBus.emit('g1', 'c1', { kind: 'error', message: 'boom', retryable: true });
    await flush();

    expect(removed).toEqual(['⏳']);
    expect(reactions).toEqual(['⏳', '❌']);
  });

  it('clears the indicator only ONCE (one-shot): a second result does not re-clear', async () => {
    const eventBus = new EventBus();
    const { router } = makeDeps({ binding: binding(ws), eventBus });
    const { message, reactions, removed } = fakeMessage();
    await router.handle(message);

    eventBus.emit('g1', 'c1', { kind: 'result', text: 'first' });
    await flush();
    eventBus.emit('g1', 'c1', { kind: 'result', text: 'second' });
    await flush();

    expect(removed).toEqual(['⏳']); // removed exactly once
    expect(reactions).toEqual(['⏳', '✅']); // ✅ added exactly once
  });

  it('a non-terminal event (text delta) does NOT clear the indicator', async () => {
    const eventBus = new EventBus();
    const { router } = makeDeps({ binding: binding(ws), eventBus });
    const { message, reactions, removed } = fakeMessage();
    await router.handle(message);

    eventBus.emit('g1', 'c1', { kind: 'text', text: 'partial…', delta: true });
    await flush();

    expect(removed).toEqual([]); // still working
    expect(reactions).toEqual(['⏳']);
  });

  it('a reaction failure never throws (missing Add-Reactions permission)', async () => {
    const eventBus = new EventBus();
    const { router } = makeDeps({ binding: binding(ws), eventBus });
    const { message } = fakeMessage({ reactFails: true });
    // Adding ⏳ throws inside the router; it must be swallowed by safe().
    await expect(router.handle(message)).resolves.toBeUndefined();
    // The completion path also swallows the react failure.
    expect(() => eventBus.emit('g1', 'c1', { kind: 'result', text: 'done' })).not.toThrow();
    await flush();
  });

  it('clears without removeReaction present (bare message): still adds ✅', async () => {
    const eventBus = new EventBus();
    const { router } = makeDeps({ binding: binding(ws), eventBus });
    const { message, reactions } = fakeMessage({ withRemove: false });
    await router.handle(message);
    eventBus.emit('g1', 'c1', { kind: 'result', text: 'done' });
    await flush();
    // No removeReaction to call, but the terminal ✅ is still added.
    expect(reactions).toEqual(['⏳', '✅']);
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

  it('rejects an attachment dir that escapes the workspace (pre-planted symlink)', async () => {
    // Plant a symlink at cwd/.dab-attachments → an OUTSIDE directory. Writing an
    // attachment through it would redirect attacker bytes outside the workspace, so
    // the router must reject before writing.
    const outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dab-outside-')));
    try {
      fs.symlinkSync(outside, path.join(ws, '.dab-attachments'), 'dir');
    } catch {
      // If the platform forbids symlinks, skip — the confinement is still exercised
      // by the traversal-name test above.
      return;
    }

    const { router, orchestrator } = makeDeps({ binding: binding(ws) });
    const { message, replies } = fakeMessage({
      attachments: [{ url: 'https://cdn/x', name: 'evil.txt', contentType: 'text/plain' }],
    });
    await router.handle(message);

    // No turn was sent (the download failed the confinement check) and the actor
    // got a notice; nothing was written into the outside directory.
    expect(orchestrator.send).not.toHaveBeenCalled();
    expect(replies.some((r) => r.includes('escapes the workspace'))).toBe(true);
    expect(fs.readdirSync(outside)).toHaveLength(0);

    fs.rmSync(outside, { recursive: true, force: true });
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

// A server Administrator can DRIVE a session by messaging even with an EMPTY role
// allowlist (the fix for the /agent start lockout footgun), while a non-admin with no
// role stays denied. Uses a REAL Authorizer over a temp config so the admin-tier grant
// is exercised end-to-end through the router's isAdministrator plumbing.
describe('MessageRouter Administrator authorization', () => {
  let home: string;

  function writeEmptyConfig(dir: string): void {
    const config: AppConfig = {
      version: CONFIG_VERSION,
      discord: { token: 'x', clientId: 'cid' },
      auth: { adminRoleIds: [], executeRoleIds: [], readOnlyRoleIds: [], dmPolicy: 'deny' },
      defaults: {
        mode: 'claude',
        claudeModel: 'opus',
        codexModel: '',
        permissionMode: 'default',
        permissionProfile: null,
        codexHome: '~/.codex',
        codexCliCommand: 'codex',
        codexCliVersion: null,
      },
      limits: { maxSessionsPerUser: 0, permissionTimeoutSec: 60, codexTimeoutMs: 1_800_000 },
      policy: { unknownCommand: 'confirm', allowExtraCommands: [] },
      autoAllowClaudeTools: ['Read'],
      profiles: {},
      usage: { userAgent: 'claude-code', cacheSec: 180 },
      audit: { channelId: null },
      locale: 'ko',
      logLevel: 'info',
      favorites: [],
    };
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify(config));
  }

  // A member whose permissions.has(bit) is true iff the requested bit is Administrator.
  const adminMember = {
    roles: { cache: { map: (fn: (r: { id: string }) => string) => [].map(fn) } },
    permissions: { has: (bit: bigint) => bit === ADMIN_BIT },
  };

  function realDeps(): { router: MessageRouter; sent: unknown[] } {
    const store = new ConfigStore(home);
    const registry = new ChannelRegistry(new StateStore(home), () => '2026-01-01T00:00:00.000Z');
    // Bind the channel so the message is treated as a turn.
    registry.set({ guildId: 'g1', channelId: 'c1', mode: 'claude', sessionId: 's1', cwd: ws, ownerId: 'owner', permMode: 'default', profile: null });
    const authorizer = new Authorizer(store, registry);
    const sent: unknown[] = [];
    const orchestrator = {
      send: vi.fn(async (guildId: string, channelId: string, turn: TurnInput): Promise<SendResult> => {
        sent.push({ guildId, channelId, turn });
        return { status: 'started', queueDepth: 1 };
      }),
    } as unknown as SessionOrchestrator;
    const router = new MessageRouter({ authorizer, channelRegistry: registry, orchestrator, logger });
    return { router, sent };
  }

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-msg-admin-'));
    writeEmptyConfig(home);
  });
  afterEach(() => {
    fs.rmSync(home, { recursive: true, force: true });
  });

  it('an Administrator can drive even with an empty role config', async () => {
    const { router, sent } = realDeps();
    const { message, replies } = fakeMessage({ member: adminMember });
    await router.handle(message);
    expect(sent).toHaveLength(1);
    expect(replies).toHaveLength(0); // no denial notice
  });

  it('a non-admin with no role is denied (deny-by-default preserved)', async () => {
    const { router, sent } = realDeps();
    const nonAdminMember = {
      roles: { cache: { map: (fn: (r: { id: string }) => string) => [].map(fn) } },
      permissions: { has: () => false },
    };
    const { message, replies } = fakeMessage({ member: nonAdminMember });
    await router.handle(message);
    expect(sent).toHaveLength(0);
    expect(replies).toHaveLength(1);
    expect(replies[0]).toContain('권한이 없습니다');
  });
});
