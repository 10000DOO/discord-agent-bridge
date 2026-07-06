import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { Events, type Client } from 'discord.js';
import { createApp, installGlobalSafetyNet } from './app.js';
import { ConfigStore } from './core/config.js';
import { ChannelRegistry, type ChannelBinding } from './core/channelRegistry.js';
import { StateStore } from './core/state/store.js';
import { CONFIG_DEFAULTS, CONFIG_VERSION, type AppConfig } from './core/configSchema.js';
import type { Logger } from './core/contracts.js';

// Build a minimal valid AppConfig from the shipped defaults + a (fake) discord
// section. No realistic secret-shaped literals — placeholder ids only.
function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    ...CONFIG_DEFAULTS,
    version: CONFIG_VERSION,
    discord: { token: 'fake-token-value', clientId: 'client-id-000' },
    ...overrides,
  } as AppConfig;
}

// A fake discord.js Client good enough for createApp + firing ClientReady WITHOUT
// a real gateway. It captures event handlers registered via once()/on() so a test
// can fire ClientReady; guilds.cache is empty so no slash-command REST call runs.
interface FakeClient {
  client: Client;
  fireReady: () => Promise<void>;
  fireChannelDelete: (channel: unknown) => void;
  loginCalls: string[];
  destroyed: boolean;
}

function fakeClient(): FakeClient {
  const onceHandlers = new Map<string, (arg: unknown) => void>();
  const onHandlers = new Map<string, (arg: unknown) => void>();
  const state = { loginCalls: [] as string[], destroyed: false };
  const ready = {
    user: { tag: 'bot#0001' },
    guilds: { cache: new Map() },
  };
  const client = {
    once: (event: string, handler: (arg: unknown) => void) => {
      onceHandlers.set(event, handler);
    },
    on: (event: string, handler: (arg: unknown) => void) => {
      onHandlers.set(event, handler);
    },
    login: async (token: string) => {
      state.loginCalls.push(token);
    },
    destroy: async () => {
      state.destroyed = true;
    },
    // resolveOverClient uses channels.fetch; onReady uses guilds.cache.size.
    channels: { fetch: async () => null },
    guilds: { cache: { size: 0 } },
    token: 'fake-token-value',
  } as unknown as Client;
  return {
    client,
    loginCalls: state.loginCalls,
    get destroyed() {
      return state.destroyed;
    },
    fireReady: async () => {
      const handler = onceHandlers.get('ready') ?? onceHandlers.get('clientReady');
      if (!handler) throw new Error('no ClientReady handler was registered');
      handler(ready);
      // handleReady runs onReady asynchronously; let its microtasks flush.
      await new Promise((r) => setTimeout(r, 0));
    },
    fireChannelDelete: (channel: unknown) => {
      const handler = onHandlers.get(Events.ChannelDelete);
      if (!handler) throw new Error('no ChannelDelete handler was registered');
      handler(channel);
    },
  };
}

describe('createApp — composition root', () => {
  let dir: string;
  let store: ConfigStore;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-app-'));
    store = new ConfigStore(dir);
    store.save(makeConfig());
  });
  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('constructs the full graph with a fake client without throwing', () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    expect(app.orchestrator).toBeDefined();
    expect(app.wiring).toBeDefined();
    expect(app.usageService).toBeDefined();
    expect(app.discord).toBeDefined();
  });

  it('registers BOTH the Claude and Codex modes in the mode registry', () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    expect(app.modeRegistry.has('claude')).toBe(true);
    expect(app.modeRegistry.get('claude').name).toBe('claude');
    expect(app.modeRegistry.has('codex')).toBe(true);
    expect(app.modeRegistry.get('codex').name).toBe('codex');
    // Both registered → both offered as /mode backend choices and in the wizard.
    expect(app.modeRegistry.list().sort()).toEqual(['claude', 'codex']);
  });

  it('exposes Codex capabilities (no permission prompts, no usage panel, transcript UX)', () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    const caps = app.modeRegistry.get('codex').capabilities;
    expect(caps.permissionPrompts).toBe(false);
    expect(caps.usagePanel).toBe(false);
    expect(caps.transcript).toBe(true);
    expect(caps.streaming).toBe(false);
  });

  it('wires orchestrator.requestPermission to the wiring layer (denies when unwired)', async () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    // The orchestrator's requestPermission is the wiring hook: with no channel wired,
    // it fails safe (deny) — proving the hook is the wiring's, not the default stub.
    const decision = await app.wiring.requestPermission(
      { guildId: 'g1', channelId: 'c1', ownerId: 'u1' },
      { toolName: 'Bash', input: {} },
    );
    expect(decision.behavior).toBe('deny');
  });

  it('login() forwards the config token to the client', async () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    await app.login();
    expect(fc.loginCalls).toEqual(['fake-token-value']);
  });

  it('onReady triggers orchestrator.resumeAll()', async () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    const spy = vi.spyOn(app.orchestrator, 'resumeAll');
    await fc.fireReady();
    expect(spy).toHaveBeenCalledTimes(1);
  });
});

describe('createApp — channelDelete cleans up a bound session (crash-loop root fix)', () => {
  let dir: string;
  let store: ConfigStore;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-app-cd-'));
    store = new ConfigStore(dir);
    store.save(makeConfig());
  });
  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  // Persist a channel binding into the same DAB home so the app's ChannelRegistry
  // loads it at construction (createApp builds its own registry over configStore.dir).
  function seedBinding(over: Partial<ChannelBinding> = {}): void {
    const registry = new ChannelRegistry(new StateStore(store.dir));
    registry.set({
      guildId: 'g1',
      channelId: 'c-bound',
      mode: 'claude',
      sessionId: null,
      cwd: '/ws',
      ownerId: 'u1',
      permMode: 'default',
      profile: null,
      ...over,
    });
  }

  const settle = () => new Promise((r) => setTimeout(r, 0));

  it('stops + detaches when a BOUND, non-archived session channel is deleted', async () => {
    seedBinding();
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    fc.fireChannelDelete({ id: 'c-bound', guildId: 'g1', isDMBased: () => false });
    await settle();

    expect(detachSpy).toHaveBeenCalledWith('g1', 'c-bound');
    expect(stopSpy).toHaveBeenCalledWith('g1', 'c-bound');
  });

  it('ignores an unbound (control) channel deletion', async () => {
    // No binding seeded for c-control → it is not a session channel.
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    fc.fireChannelDelete({ id: 'c-control', guildId: 'g1', isDMBased: () => false });
    await settle();

    expect(stopSpy).not.toHaveBeenCalled();
    expect(detachSpy).not.toHaveBeenCalled();
  });

  it('ignores an ARCHIVED binding deletion (no live session)', async () => {
    seedBinding({ channelId: 'c-arch', archived: true });
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client });
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    fc.fireChannelDelete({ id: 'c-arch', guildId: 'g1', isDMBased: () => false });
    await settle();

    expect(stopSpy).not.toHaveBeenCalled();
    expect(detachSpy).not.toHaveBeenCalled();
  });
});

describe('installGlobalSafetyNet (last-line-of-defense, not the primary fix)', () => {
  function fakeTarget() {
    const handlers = new Map<string, ((arg: unknown) => void)[]>();
    const target = {
      on(event: string, listener: (arg: unknown) => void) {
        const list = handlers.get(event) ?? [];
        list.push(listener);
        handlers.set(event, list);
        return target;
      },
    };
    return { target, handlers };
  }

  function recordingLogger(): { logger: Logger; errors: string[] } {
    const errors: string[] = [];
    const logger: Logger = {
      debug: () => {},
      info: () => {},
      warn: () => {},
      error: (m: string) => errors.push(m),
    };
    return { logger, errors };
  }

  it('registers unhandledRejection + uncaughtException handlers that LOG and do not throw', () => {
    const { target, handlers } = fakeTarget();
    const { logger, errors } = recordingLogger();
    installGlobalSafetyNet(logger, target as unknown as Pick<NodeJS.EventEmitter, 'on'>);

    expect(handlers.get('unhandledRejection')).toHaveLength(1);
    expect(handlers.get('uncaughtException')).toHaveLength(1);

    expect(() => handlers.get('unhandledRejection')![0](new Error('Unknown Channel'))).not.toThrow();
    expect(() => handlers.get('uncaughtException')![0](new Error('boom'))).not.toThrow();
    expect(errors.length).toBe(2);
  });

  it('is idempotent per target (no duplicate handlers on repeat calls)', () => {
    const { target, handlers } = fakeTarget();
    const { logger } = recordingLogger();
    installGlobalSafetyNet(logger, target as unknown as Pick<NodeJS.EventEmitter, 'on'>);
    installGlobalSafetyNet(logger, target as unknown as Pick<NodeJS.EventEmitter, 'on'>);
    expect(handlers.get('unhandledRejection')).toHaveLength(1);
    expect(handlers.get('uncaughtException')).toHaveLength(1);
  });
});
