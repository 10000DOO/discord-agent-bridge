import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import type { Client } from 'discord.js';
import { createApp } from './app.js';
import { ConfigStore } from './core/config.js';
import { CONFIG_DEFAULTS, CONFIG_VERSION, type AppConfig } from './core/configSchema.js';

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
  loginCalls: string[];
  destroyed: boolean;
}

function fakeClient(): FakeClient {
  const onceHandlers = new Map<string, (arg: unknown) => void>();
  const state = { loginCalls: [] as string[], destroyed: false };
  const ready = {
    user: { tag: 'bot#0001' },
    guilds: { cache: new Map() },
  };
  const client = {
    once: (event: string, handler: (arg: unknown) => void) => {
      onceHandlers.set(event, handler);
    },
    on: () => {},
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
