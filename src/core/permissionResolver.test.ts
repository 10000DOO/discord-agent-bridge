import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { ConfigStore } from './config.js';
import { CONFIG_VERSION, type AppConfig } from './configSchema.js';
import { StateStore } from './state/store.js';
import { ChannelRegistry, type ChannelBindingInput } from './channelRegistry.js';
import { ConfigResolver } from './configResolver.js';
import { PermissionResolver } from './permissionResolver.js';

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    version: CONFIG_VERSION,
    discord: { token: 'bot-token-abc', clientId: '123456789' },
    auth: { adminRoleIds: [], executeRoleIds: [], readOnlyRoleIds: [], dmPolicy: 'deny' },
    defaults: {
      mode: 'claude',
      claudeModel: 'opus',
      permissionMode: 'default',
      permissionProfile: null,
      codexHome: '~/.codex',
      codexCliCommand: 'codex',
      codexCliVersion: null,
    },
    limits: { maxSessionsPerUser: 0, permissionTimeoutSec: 60, codexTimeoutMs: 1_800_000 },
    policy: { unknownCommand: 'confirm', allowExtraCommands: [] },
    autoAllowClaudeTools: ['Read', 'Glob', 'Grep'],
    profiles: {
      readonly: { permissionMode: 'plan', allowedTools: ['Read', 'Glob', 'Grep'], policyTier: 'read-only' },
      edit: { permissionMode: 'acceptEdits', allowedTools: ['Read', 'Edit', 'Write', 'Bash'], policyTier: 'normal' },
    },
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

describe('PermissionResolver', () => {
  let dir: string;
  let store: ConfigStore;

  function build(): { resolver: PermissionResolver; registry: ChannelRegistry } {
    const registry = new ChannelRegistry(new StateStore(dir), () => '2026-01-01T00:00:00.000Z');
    const configResolver = new ConfigResolver(store, registry);
    const resolver = new PermissionResolver(store, configResolver);
    return { resolver, registry };
  }

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-permres-'));
    store = new ConfigStore(dir);
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('default: global permissionMode + global auto-allow tools when nothing overrides', () => {
    store.save(makeConfig());
    const { resolver } = build();
    const r = resolver.resolve('g1', 'c1');
    expect(r.permMode).toBe('default');
    expect(r.profile).toBeNull();
    expect(r.allowedTools).toEqual(['Read', 'Glob', 'Grep']);
    expect(r.policyTier).toBeUndefined();
  });

  it('layers permission mode global→server→project (project wins)', () => {
    store.save(makeConfig());
    store.saveServerConfig({ version: 1, guildId: 'g1', defaults: { permissionMode: 'acceptEdits' } });
    const { resolver, registry } = build();
    // Server-only → acceptEdits.
    expect(resolver.resolve('g1', 'c9').permMode).toBe('acceptEdits');
    // Project binding wins.
    registry.set(binding({ permMode: 'plan' }));
    expect(resolver.resolve('g1', 'c1').permMode).toBe('plan');
  });

  it('a resolved profile bundles its mode, tools, and tier', () => {
    store.save(makeConfig());
    const { resolver, registry } = build();
    registry.set(binding({ profile: 'readonly' }));
    const r = resolver.resolve('g1', 'c1');
    expect(r.profile).toBe('readonly');
    expect(r.permMode).toBe('plan'); // from profile, over binding permMode 'default'
    expect(r.allowedTools).toEqual(['Read', 'Glob', 'Grep']);
    expect(r.policyTier).toBe('read-only');
  });

  it('session override permMode wins over layered value and profile', () => {
    store.save(makeConfig());
    const { resolver, registry } = build();
    registry.set(binding({ profile: 'readonly' })); // profile would give 'plan'
    const r = resolver.resolve('g1', 'c1', { permMode: 'bypassPermissions' });
    expect(r.permMode).toBe('bypassPermissions');
    // Profile still supplies the tool allowlist/tier unless the profile itself was overridden.
    expect(r.allowedTools).toEqual(['Read', 'Glob', 'Grep']);
    expect(r.profile).toBe('readonly');
  });

  it('session override can switch the profile, changing bundled tools', () => {
    store.save(makeConfig());
    const { resolver, registry } = build();
    registry.set(binding({ profile: 'readonly' }));
    const r = resolver.resolve('g1', 'c1', { profile: 'edit' });
    expect(r.profile).toBe('edit');
    expect(r.permMode).toBe('acceptEdits');
    expect(r.allowedTools).toEqual(['Read', 'Edit', 'Write', 'Bash']);
    expect(r.policyTier).toBe('normal');
  });

  it('session override can clear the profile back to layered/global tools', () => {
    store.save(makeConfig());
    const { resolver, registry } = build();
    registry.set(binding({ profile: 'readonly', permMode: 'acceptEdits' }));
    const r = resolver.resolve('g1', 'c1', { profile: null });
    expect(r.profile).toBeNull();
    // No profile → layered permMode (binding's acceptEdits) + global auto-allow tools.
    expect(r.permMode).toBe('acceptEdits');
    expect(r.allowedTools).toEqual(['Read', 'Glob', 'Grep']);
  });

  it('throws on an unknown profile name', () => {
    store.save(makeConfig());
    const { resolver, registry } = build();
    registry.set(binding({ profile: 'nope' }));
    expect(() => resolver.resolve('g1', 'c1')).toThrow(/unknown permission profile/i);
  });
});
