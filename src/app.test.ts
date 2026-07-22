import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { DiscordAPIError, Events, type Client } from 'discord.js';
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

// The AutoUpdater's boot check (fired from onReady) would otherwise hit the npm registry.
// Inject a non-OK fetch so fetchLatestVersion resolves to null: no network, no prompt.
const noNetworkFetch = (async () => new Response('nope', { status: 404 })) as unknown as typeof fetch;

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

function fakeClient(opts: { channelsFetch?: (id: string) => Promise<unknown> } = {}): FakeClient {
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
    // resolveOverClient / resolveResultOverClient use channels.fetch; onReady uses
    // guilds.cache.size. A test can override the fetch to script a boot re-wire outcome.
    channels: { fetch: opts.channelsFetch ?? (async () => null) },
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
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    expect(app.orchestrator).toBeDefined();
    expect(app.wiring).toBeDefined();
    expect(app.usageService).toBeDefined();
    expect(app.discord).toBeDefined();
  });

  it('registers the Claude, Codex, Grok Build, and Custom modes in the mode registry', () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    expect(app.modeRegistry.has('claude')).toBe(true);
    expect(app.modeRegistry.get('claude').name).toBe('claude');
    expect(app.modeRegistry.has('codex')).toBe(true);
    expect(app.modeRegistry.get('codex').name).toBe('codex');
    expect(app.modeRegistry.has('grok-build')).toBe(true);
    expect(app.modeRegistry.get('grok-build').name).toBe('grok-build');
    expect(app.modeRegistry.has('grok')).toBe(false);
    expect(app.modeRegistry.has('grok-agent')).toBe(false);
    expect(app.modeRegistry.has('custom')).toBe(true);
    expect(app.modeRegistry.get('custom').name).toBe('custom');
    // All registered → offered as /mode backend choices and in the wizard.
    expect(app.modeRegistry.list().sort()).toEqual(['claude', 'codex', 'custom', 'grok-build']);
  });

  it('every registered mode exposes a catalog (per-backend UI vocabulary, §6)', () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    for (const name of app.modeRegistry.list()) {
      expect(app.modeRegistry.get(name).catalog).toBeDefined();
    }
    // Claude/custom share the Claude vocabulary; Codex uses its own sandbox permission terms.
    expect(app.modeRegistry.get('claude').catalog.permissionChoices().map((c) => c.value)).toContain('bypassPermissions');
    expect(app.modeRegistry.get('codex').catalog.permissionChoices().map((c) => c.value)).toEqual([
      'read-only',
      'workspace-write',
      'danger-full-access',
    ]);
  });

  it('exposes Codex app-server phase-2 capabilities (streaming + tools + thinking + usage + attach)', () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    const caps = app.modeRegistry.get('codex').capabilities;
    expect(caps.permissionPrompts).toBe(true);
    expect(caps.toolThreads).toBe(true);
    expect(caps.thinking).toBe(true);
    expect(caps.usagePanel).toBe(true);
    expect(caps.fileDiff).toBe(true);
    expect(caps.fileAttach).toBe(true); // sendFileFor wired in createApp
    expect(caps.transcript).toBe(false);
    expect(caps.streaming).toBe(true);
    const grokCaps = app.modeRegistry.get('grok-build').capabilities;
    expect(grokCaps.fileAttach).toBe(true);
    expect(grokCaps.fileDiff).toBe(true);
  });

  it('wires orchestrator.requestPermission to the wiring layer (denies when unwired)', async () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
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
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    await app.login();
    expect(fc.loginCalls).toEqual(['fake-token-value']);
  });

  it('onReady triggers orchestrator.resumeAll()', async () => {
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    const spy = vi.spyOn(app.orchestrator, 'resumeAll');
    await fc.fireReady();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('warns at boot when config.defaults.mode is not a registered backend (§5.4)', () => {
    const fc = fakeClient();
    const warnings: { message: string; meta: unknown[] }[] = [];
    const logger: Logger = {
      debug: () => {},
      info: () => {},
      warn: (message: string, ...meta: unknown[]) => warnings.push({ message, meta }),
      error: () => {},
    };
    const config = makeConfig({ defaults: { ...CONFIG_DEFAULTS.defaults, mode: 'gemini' } });
    createApp({ config, configStore: store, client: fc.client, fetchFn: noNetworkFetch, logger });
    const hit = warnings.find((w) => w.message.includes('defaults.mode is not a registered backend'));
    expect(hit).toBeDefined();
    expect(hit?.meta[0]).toMatchObject({ mode: 'gemini' });
  });

  it('does not warn about defaults.mode for a registered backend', () => {
    const fc = fakeClient();
    const warnings: string[] = [];
    const logger: Logger = {
      debug: () => {},
      info: () => {},
      warn: (message: string) => warnings.push(message),
      error: () => {},
    };
    const config = makeConfig({ defaults: { ...CONFIG_DEFAULTS.defaults, mode: 'codex' } });
    createApp({ config, configStore: store, client: fc.client, fetchFn: noNetworkFetch, logger });
    expect(warnings.some((m) => m.includes('defaults.mode is not a registered backend'))).toBe(false);
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
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
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
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
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
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    fc.fireChannelDelete({ id: 'c-arch', guildId: 'g1', isDMBased: () => false });
    await settle();

    expect(stopSpy).not.toHaveBeenCalled();
    expect(detachSpy).not.toHaveBeenCalled();
  });
});

describe('createApp — boot re-wire robustness (§6/§7)', () => {
  let dir: string;
  let store: ConfigStore;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-app-rewire-'));
    store = new ConfigStore(dir);
    store.save(makeConfig());
  });
  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

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

  // A real DiscordAPIError(10003) — the single permanent "channel is gone" signal.
  function djs10003(): DiscordAPIError {
    return new DiscordAPIError({ code: 10003, message: 'Unknown Channel' }, 10003, 404, 'GET', 'https://x', {
      files: [],
      body: {},
    });
  }

  it('boot: a 10003 fetch hard-cleans the stale binding (detach + stop), end-to-end', async () => {
    seedBinding();
    const fc = fakeClient({ channelsFetch: async () => { throw djs10003(); } });
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    // Isolate the attach loop: keep resumeAll from spawning real sessions.
    vi.spyOn(app.orchestrator, 'resumeAll').mockResolvedValue(undefined);
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    await fc.fireReady();
    await settle();

    // The whole chain ran: fetch → resolveChannelResult(gone) → attachWithRetry(gone,
    // 1 attempt, no delay) → handleChannelGone → detach + stop.
    expect(detachSpy).toHaveBeenCalledWith('g1', 'c-bound');
    expect(stopSpy).toHaveBeenCalledWith('g1', 'c-bound');
  });

  it('boot: a transient failure preserves the binding (no detach/stop)', async () => {
    seedBinding();
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    vi.spyOn(app.orchestrator, 'resumeAll').mockResolvedValue(undefined);
    // Stub the retry to report exhaustion without waiting the real backoff.
    vi.spyOn(app.wiring, 'attachWithRetry').mockResolvedValue('unavailable');
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    await fc.fireReady();
    await settle();

    expect(stopSpy).not.toHaveBeenCalled();
    expect(detachSpy).not.toHaveBeenCalled();
  });

  it('boot: parallel attach — a gone channel is cleaned without blocking a healthy one', async () => {
    seedBinding({ channelId: 'c-gone' });
    seedBinding({ channelId: 'c-ok' });
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    vi.spyOn(app.orchestrator, 'resumeAll').mockResolvedValue(undefined);
    const attachSpy = vi
      .spyOn(app.wiring, 'attachWithRetry')
      .mockImplementation(async (_guildId, channelId) => (channelId === 'c-gone' ? 'gone' : 'attached'));
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    await fc.fireReady();
    await settle();

    // Both channels were attempted (allSettled fans out); only the gone one is cleaned.
    expect(attachSpy).toHaveBeenCalledWith('g1', 'c-gone', 'claude');
    expect(attachSpy).toHaveBeenCalledWith('g1', 'c-ok', 'claude');
    expect(detachSpy).toHaveBeenCalledWith('g1', 'c-gone');
    expect(stopSpy).toHaveBeenCalledWith('g1', 'c-gone');
    expect(stopSpy).not.toHaveBeenCalledWith('g1', 'c-ok');
  });

  it('boot: a throwing attachWithRetry does not kill boot; other channels still attach (allSettled)', async () => {
    seedBinding({ channelId: 'c-throws' });
    seedBinding({ channelId: 'c-ok' });
    const fc = fakeClient();
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    vi.spyOn(app.orchestrator, 'resumeAll').mockResolvedValue(undefined);
    const attachSpy = vi.spyOn(app.wiring, 'attachWithRetry').mockImplementation(async (_guildId, channelId) => {
      if (channelId === 'c-throws') throw new Error('attach blew up');
      return 'attached';
    });

    // Promise.allSettled isolates the rejection: the ready handler must not reject.
    await expect(fc.fireReady()).resolves.toBeUndefined();
    await settle();

    expect(attachSpy).toHaveBeenCalledWith('g1', 'c-throws', 'claude');
    expect(attachSpy).toHaveBeenCalledWith('g1', 'c-ok', 'claude');
  });

  it('onChannelDelete and a boot 10003 take the same cleanup path (shared handleChannelGone)', async () => {
    seedBinding();
    const fc = fakeClient({ channelsFetch: async () => { throw djs10003(); } });
    const app = createApp({ config: makeConfig(), configStore: store, client: fc.client, fetchFn: noNetworkFetch });
    vi.spyOn(app.orchestrator, 'resumeAll').mockResolvedValue(undefined);
    const stopSpy = vi.spyOn(app.orchestrator, 'stop').mockResolvedValue(undefined);
    const detachSpy = vi.spyOn(app.wiring, 'detach').mockImplementation(() => {});

    // Path 1: the boot re-wire hits 10003 → one cleanup.
    await fc.fireReady();
    await settle();
    expect(stopSpy).toHaveBeenCalledTimes(1);
    expect(detachSpy).toHaveBeenCalledTimes(1);

    // Path 2: a live ChannelDelete for the same channel → identical cleanup call.
    fc.fireChannelDelete({ id: 'c-bound', guildId: 'g1', isDMBased: () => false });
    await settle();
    expect(stopSpy).toHaveBeenCalledTimes(2);
    expect(detachSpy).toHaveBeenCalledTimes(2);
    expect(stopSpy).toHaveBeenNthCalledWith(1, 'g1', 'c-bound');
    expect(stopSpy).toHaveBeenNthCalledWith(2, 'g1', 'c-bound');
    expect(detachSpy).toHaveBeenNthCalledWith(1, 'g1', 'c-bound');
    expect(detachSpy).toHaveBeenNthCalledWith(2, 'g1', 'c-bound');
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
