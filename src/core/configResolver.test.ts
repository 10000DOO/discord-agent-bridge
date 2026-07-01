import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { ConfigStore } from './config.js';
import { CONFIG_VERSION, type AppConfig, type ServerConfig } from './configSchema.js';
import { StateStore } from './state/store.js';
import { ChannelRegistry, type ChannelBindingInput } from './channelRegistry.js';
import { ConfigResolver } from './configResolver.js';

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    version: CONFIG_VERSION,
    discord: { token: 'bot-token-abc', clientId: '123456789' },
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
    autoAllowClaudeTools: ['Read', 'Glob', 'Grep'],
    profiles: {},
    usage: { userAgent: 'claude-code', cacheSec: 180 },
    audit: { channelId: null },
    locale: 'ko',
    logLevel: 'info',
    favorites: [],
    ...overrides,
  };
}

function binding(overrides: Partial<ChannelBindingInput> = {}): ChannelBindingInput {
  return {
    guildId: 'g1',
    channelId: 'c1',
    mode: 'claude',
    sessionId: null,
    cwd: '/abs/workspace',
    ownerId: 'u1',
    permMode: 'default',
    profile: null,
    ...overrides,
  };
}

describe('ConfigResolver', () => {
  let dir: string;
  let store: ConfigStore;

  function build(): { resolver: ConfigResolver; registry: ChannelRegistry } {
    const registry = new ChannelRegistry(new StateStore(dir), () => '2026-01-01T00:00:00.000Z');
    const resolver = new ConfigResolver(store, registry);
    return { resolver, registry };
  }

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-cfgres-'));
    store = new ConfigStore(dir);
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('global-only: returns global defaults when no server/project layers exist', () => {
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, claudeModel: 'sonnet', permissionMode: 'plan' } }));
    const { resolver } = build();
    const r = resolver.resolve('g1', 'c1');
    expect(r.claudeModel).toBe('sonnet');
    expect(r.permissionMode).toBe('plan');
    expect(r.mode).toBe('claude');
    expect(r.limits.permissionTimeoutSec).toBe(60);
  });

  it('server overrides global; unset server fields fall through', () => {
    store.save(makeConfig());
    const server: ServerConfig = {
      version: 1,
      guildId: 'g1',
      defaults: { mode: 'codex', permissionMode: 'acceptEdits' },
      // claudeModel intentionally unset → falls through to global 'opus'.
    };
    store.saveServerConfig(server);
    const { resolver } = build();
    const r = resolver.resolve('g1', 'c1');
    expect(r.mode).toBe('codex');
    expect(r.permissionMode).toBe('acceptEdits');
    expect(r.claudeModel).toBe('opus'); // fell through from global
  });

  it('server-scoped: another guild is unaffected by g1 server overrides', () => {
    store.save(makeConfig());
    store.saveServerConfig({ version: 1, guildId: 'g1', defaults: { mode: 'codex' } });
    const { resolver } = build();
    expect(resolver.resolve('g1', 'c1').mode).toBe('codex');
    expect(resolver.resolve('g2', 'c1').mode).toBe('claude'); // global default
  });

  it('project (channel binding) overrides server and global', () => {
    store.save(makeConfig());
    store.saveServerConfig({
      version: 1,
      guildId: 'g1',
      defaults: { mode: 'codex', permissionMode: 'acceptEdits', permissionProfile: 'server-prof' },
    });
    const { resolver, registry } = build();
    registry.set(binding({ mode: 'claude', permMode: 'plan', profile: 'proj-prof' }));
    const r = resolver.resolve('g1', 'c1');
    expect(r.mode).toBe('claude'); // project wins over server 'codex'
    expect(r.permissionMode).toBe('plan'); // project wins over server 'acceptEdits'
    expect(r.permissionProfile).toBe('proj-prof'); // project wins over server 'server-prof'
  });

  it('deep-merges nested limits: project/server fields override, siblings fall through', () => {
    store.save(makeConfig());
    store.saveServerConfig({ version: 1, guildId: 'g1', limits: { maxSessionsPerUser: 3 } });
    const { resolver } = build();
    const r = resolver.resolve('g1', 'c1');
    expect(r.limits.maxSessionsPerUser).toBe(3); // server override
    expect(r.limits.permissionTimeoutSec).toBe(60); // global sibling fell through
    expect(r.limits.codexTimeoutMs).toBe(1_800_000); // global sibling fell through
  });

  it('missing project level falls through to server; missing server falls through to global', () => {
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, permissionMode: 'default' } }));
    store.saveServerConfig({ version: 1, guildId: 'g1', defaults: { permissionMode: 'plan' } });
    const { resolver } = build();
    // No channel binding for c1 → server 'plan' applies.
    expect(resolver.resolve('g1', 'c1').permissionMode).toBe('plan');
    // No server for g3 and no binding → global 'default' applies.
    expect(resolver.resolve('g3', 'c9').permissionMode).toBe('default');
  });

  it('resolveModeConfig narrows to the mode-facing view', () => {
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, claudeModel: 'haiku' } }));
    const { resolver } = build();
    const view = resolver.resolveModeConfig('g1', 'c1');
    expect(view.model).toBe('haiku');
    expect(view.codexHome).toBe('~/.codex');
    expect(view.permissionTimeoutSec).toBe(60);
    expect(view.codexTimeoutMs).toBe(1_800_000);
  });
});
