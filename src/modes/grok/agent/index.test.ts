import { describe, it, expect, vi, afterEach } from 'vitest';
import type { AgentEvent, ModeContext, ResumableSession } from '../../../core/contracts.js';
import type { AcpUpdate, GrokAcpClientOptions } from './acpClient.js';
import type { CreateGrokAcpClient } from './acpSession.js';
import { GrokBuildMode } from './index.js';
import { grokCatalog } from '../catalog.js';
import type { GrokDiscovery } from '../discovery.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

function makeCtx(cwd = '/work/proj'): { ctx: ModeContext; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  const ctx: ModeContext = {
    guildId: 'g1',
    channelId: 'c1',
    cwd,
    ownerId: 'u1',
    permMode: 'default',
    emit: (ev) => events.push(ev),
    requestPermission: async () => ({ behavior: 'deny' }),
    config: {},
    logger: nullLogger,
    audit: () => {},
  };
  return { ctx, events };
}

// A minimal fake client so start()/resume() can run one turn without a real `grok agent stdio`.
class FakeAcpClient {
  sessionNewCalls = 0;
  sessionLoadCalls: string[] = [];
  async initialize(): Promise<void> {}
  async sessionNew(): Promise<string> {
    this.sessionNewCalls++;
    return 'sess-new';
  }
  async sessionLoad(sessionId: string): Promise<void> {
    this.sessionLoadCalls.push(sessionId);
  }
  // eslint-disable-next-line require-yield
  async *prompt(): AsyncGenerator<AcpUpdate> {
    return;
  }
  onPermissionRequest(): void {}
  async close(): Promise<void> {}
  get lastPromptResult(): null {
    return null;
  }
}

function makeFactory(): { createClient: CreateGrokAcpClient; clients: FakeAcpClient[]; options: GrokAcpClientOptions[] } {
  const clients: FakeAcpClient[] = [];
  const options: GrokAcpClientOptions[] = [];
  const createClient: CreateGrokAcpClient = (opts) => {
    options.push(opts);
    const c = new FakeAcpClient();
    clients.push(c);
    return c;
  };
  return { createClient, clients, options };
}

describe('GrokBuildMode identity + capabilities', () => {
  it('is the grok-build backend with the honest ACP capabilities', () => {
    const mode = new GrokBuildMode();
    expect(mode.name).toBe('grok-build');
    expect(mode.capabilities).toEqual({
      streaming: true,
      thinking: true,
      toolThreads: true,
      permissionPrompts: true,
      progress: true,
      transcript: false,
      sessionResume: true,
      fileAttach: false,
      fileDiff: true,
      usagePanel: true,
      permissionModes: ['bypassPermissions', 'default'],
    });
    const withAttach = new GrokBuildMode({
      sendFileFor: () => async () => 'ok',
      attachGateway: {
        baseUrl: 'http://127.0.0.1:0',
        whenReady: async () => {},
        register() {},
        unregister() {},
        close: async () => {},
      },
    });
    expect(withAttach.capabilities.fileAttach).toBe(true);
  });

  it('reuses the grok catalog (same model/permission/effort vocabulary)', () => {
    expect(new GrokBuildMode().catalog).toBe(grokCatalog);
  });
});

describe('GrokBuildMode.start / resume', () => {
  it('start() builds a fresh session whose first turn calls session/new', async () => {
    const { createClient, clients } = makeFactory();
    const session = await new GrokBuildMode({ createClient }).start(makeCtx().ctx);
    expect(session.sessionId).toBeNull();
    await session.send({ text: 'hi' });
    expect(clients[0]?.sessionNewCalls).toBe(1);
    expect(clients[0]?.sessionLoadCalls).toEqual([]);
    expect(session.sessionId).toBe('sess-new');
  });

  it('resume() binds the id upfront and continues via session/load', async () => {
    const { createClient, clients } = makeFactory();
    const session = await new GrokBuildMode({ createClient }).resume(makeCtx().ctx, 'sess-r');
    expect(session.sessionId).toBe('sess-r');
    await session.send({ text: 'continue' });
    expect(clients[0]?.sessionLoadCalls).toEqual(['sess-r']);
    expect(clients[0]?.sessionNewCalls).toBe(0);
  });
});

describe('GrokBuildMode.listResumable', () => {
  const savedGrokHome = process.env.GROK_HOME;
  afterEach(() => {
    if (savedGrokHome === undefined) delete process.env.GROK_HOME;
    else process.env.GROK_HOME = savedGrokHome;
  });

  it('delegates to GrokDiscovery with the resolved grok home and the browsed cwd (GROK_HOME unset)', async () => {
    delete process.env.GROK_HOME;
    const listResumable = vi.fn<(grokHome: string, cwd?: string) => Promise<ResumableSession[]>>(
      async () => [{ sessionId: 's1', cwd: '/work' }],
    );
    const fakeDiscovery = { listResumable } as unknown as GrokDiscovery;
    const sessions = await new GrokBuildMode({ discovery: fakeDiscovery }).listResumable(makeCtx('/work/proj').ctx);

    expect(sessions).toEqual([{ sessionId: 's1', cwd: '/work' }]);
    const os = await import('node:os');
    const path = await import('node:path');
    expect(listResumable.mock.calls[0]?.[0]).toBe(path.join(os.homedir(), '.grok'));
    expect(listResumable.mock.calls[0]?.[1]).toBe('/work/proj');
  });

  it('honors GROK_HOME when set', async () => {
    process.env.GROK_HOME = '/custom/grok/home';
    const listResumable = vi.fn<(grokHome: string, cwd?: string) => Promise<ResumableSession[]>>(async () => []);
    const fakeDiscovery = { listResumable } as unknown as GrokDiscovery;
    await new GrokBuildMode({ discovery: fakeDiscovery }).listResumable(makeCtx().ctx);
    expect(listResumable.mock.calls[0]?.[0]).toBe('/custom/grok/home');
  });
});
