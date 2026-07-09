import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { ConfigStore } from './config.js';
import { CONFIG_VERSION, type AppConfig, type ServerConfig } from './configSchema.js';
import { StateStore } from './state/store.js';
import { ChannelRegistry, type ChannelBindingInput } from './channelRegistry.js';
import { Authorizer, type AuthInput } from './auth.js';

// Zero-entropy fixture ids: no realistic secret/token shapes.
const ADMIN_ROLE = 'role-admin';
const EXEC_ROLE = 'role-exec';
const READ_ROLE = 'role-read';

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
    autoUpdate: { enabled: true },
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

describe('Authorizer', () => {
  let dir: string;
  let store: ConfigStore;

  function build(): { authz: Authorizer; registry: ChannelRegistry } {
    const registry = new ChannelRegistry(new StateStore(dir), () => '2026-01-01T00:00:00.000Z');
    const authz = new Authorizer(store, registry);
    return { authz, registry };
  }

  function input(overrides: Partial<AuthInput> = {}): AuthInput {
    return {
      userId: 'u1',
      roleIds: [],
      action: 'read',
      context: { guildId: 'g1', channelId: 'c1' },
      ...overrides,
    };
  }

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-auth-'));
    store = new ConfigStore(dir);
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('fail-secure: empty allowlists deny everyone, even for read', () => {
    store.save(makeConfig());
    const { authz } = build();
    const r = authz.authorize(input({ roleIds: [ADMIN_ROLE], action: 'read' }));
    expect(r.allowed).toBe(false);
    expect(r.reason).toMatch(/fail-secure/i);
  });

  it('admin tier is allowed every action', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, adminRoleIds: [ADMIN_ROLE] } }));
    const { authz } = build();
    for (const action of ['admin', 'drive', 'run-command', 'read'] as const) {
      const r = authz.authorize(input({ roleIds: [ADMIN_ROLE], action }));
      expect(r.allowed).toBe(true);
      expect(r.tier).toBe('admin');
    }
  });

  it('execute tier may drive and run commands but not admin', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, executeRoleIds: [EXEC_ROLE] } }));
    const { authz } = build();
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive' })).allowed).toBe(true);
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'run-command' })).allowed).toBe(true);
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'read' })).allowed).toBe(true);
    const denied = authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'admin' }));
    expect(denied.allowed).toBe(false);
    expect(denied.tier).toBe('execute');
  });

  it('read-only tier may read but not drive/run-command/admin', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, readOnlyRoleIds: [READ_ROLE] } }));
    const { authz } = build();
    expect(authz.authorize(input({ roleIds: [READ_ROLE], action: 'read' })).allowed).toBe(true);
    expect(authz.authorize(input({ roleIds: [READ_ROLE], action: 'drive' })).allowed).toBe(false);
    expect(authz.authorize(input({ roleIds: [READ_ROLE], action: 'run-command' })).allowed).toBe(false);
    expect(authz.authorize(input({ roleIds: [READ_ROLE], action: 'admin' })).allowed).toBe(false);
  });

  it('unknown/no role → denied (fail-secure)', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, executeRoleIds: [EXEC_ROLE] } }));
    const { authz } = build();
    expect(authz.authorize(input({ roleIds: [], action: 'read' })).allowed).toBe(false);
    expect(authz.authorize(input({ roleIds: ['role-stranger'], action: 'read' })).allowed).toBe(false);
  });

  it('server-level roles override/extend the global allowlist for that guild only', () => {
    // Global grants nobody execute; the server grants EXEC_ROLE.
    store.save(makeConfig());
    const server: ServerConfig = {
      version: 1,
      guildId: 'g1',
      auth: { executeRoleIds: [EXEC_ROLE] },
    };
    store.saveServerConfig(server);
    const { authz } = build();
    // In g1, the server grant applies.
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive', context: { guildId: 'g1', channelId: 'c1' } })).allowed).toBe(true);
    // In g2 (no server file) the global (empty) applies → denied.
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive', context: { guildId: 'g2', channelId: 'c1' } })).allowed).toBe(false);
  });

  it('server auth for one tier does not clear the global list of another tier', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, adminRoleIds: [ADMIN_ROLE] } }));
    store.saveServerConfig({ version: 1, guildId: 'g1', auth: { executeRoleIds: [EXEC_ROLE] } });
    const { authz } = build();
    // adminRoleIds falls through from global since the server only set executeRoleIds.
    expect(authz.authorize(input({ roleIds: [ADMIN_ROLE], action: 'admin' })).allowed).toBe(true);
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive' })).allowed).toBe(true);
  });

  it('per-project ACL narrows: a tier-cleared actor is still denied when not on the project list', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, executeRoleIds: [EXEC_ROLE] } }));
    const { authz, registry } = build();
    registry.set(binding({ projectAuth: { allowedRoleIds: ['role-project'], allowedUserIds: [] } }));
    const denied = authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive' }));
    expect(denied.allowed).toBe(false);
    expect(denied.reason).toMatch(/projectAuth/);
    expect(denied.tier).toBe('execute');
  });

  it('per-project ACL admits a matching role or a matching user', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, executeRoleIds: [EXEC_ROLE] } }));
    const { authz, registry } = build();
    registry.set(binding({ projectAuth: { allowedRoleIds: [EXEC_ROLE], allowedUserIds: [] } }));
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive' })).allowed).toBe(true);

    registry.set(binding({ projectAuth: { allowedRoleIds: ['role-other'], allowedUserIds: ['u1'] } }));
    expect(authz.authorize(input({ userId: 'u1', roleIds: [EXEC_ROLE], action: 'drive' })).allowed).toBe(true);
  });

  it('DM (no guild) is denied by default', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, adminRoleIds: [ADMIN_ROLE] } }));
    const { authz } = build();
    const r = authz.authorize(input({ roleIds: [ADMIN_ROLE], action: 'read', context: {} }));
    expect(r.allowed).toBe(false);
    expect(r.reason).toMatch(/dmPolicy=deny/);
  });

  it('DM is allowed when dmPolicy=allow and the actor clears the tier', () => {
    store.save(makeConfig({ auth: { adminRoleIds: [ADMIN_ROLE], executeRoleIds: [], readOnlyRoleIds: [], dmPolicy: 'allow' } }));
    const { authz } = build();
    expect(authz.authorize(input({ roleIds: [ADMIN_ROLE], action: 'admin', context: {} })).allowed).toBe(true);
    // Still tier-gated in a DM: a stranger is denied.
    expect(authz.authorize(input({ roleIds: [], action: 'read', context: {} })).allowed).toBe(false);
  });

  // A Discord Administrator is granted the admin tier UNCONDITIONALLY (never locked
  // out), even with a completely empty role allowlist — the fix for the /agent start
  // lockout footgun. Role tiers remain additive for non-admins.
  it('a Discord Administrator with NO configured role is authorized as admin', () => {
    store.save(makeConfig()); // empty allowlists
    const { authz } = build();
    for (const action of ['admin', 'drive', 'run-command', 'read'] as const) {
      const r = authz.authorize(input({ roleIds: [], action, isAdministrator: true }));
      expect(r.allowed).toBe(true);
      expect(r.tier).toBe('admin');
    }
  });

  it('a non-admin with no configured role is denied (deny-by-default preserved)', () => {
    store.save(makeConfig()); // empty allowlists
    const { authz } = build();
    const r = authz.authorize(input({ roleIds: [], action: 'read', isAdministrator: false }));
    expect(r.allowed).toBe(false);
    expect(r.reason).toMatch(/fail-secure/i);
  });

  it('configured role tiers still work for a non-Administrator (additive, unchanged)', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, executeRoleIds: [EXEC_ROLE] } }));
    const { authz } = build();
    // The configured execute role drives without any Administrator flag.
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'drive' })).allowed).toBe(true);
    // ...but that same execute role is NOT admin.
    expect(authz.authorize(input({ roleIds: [EXEC_ROLE], action: 'admin' })).allowed).toBe(false);
  });

  it('a Discord Administrator bypasses a narrowing per-project ACL (never locked out)', () => {
    store.save(makeConfig({ auth: { ...makeConfig().auth, executeRoleIds: [EXEC_ROLE] } }));
    const { authz, registry } = build();
    // A project ACL that lists neither the admin's role nor user would normally deny.
    registry.set(binding({ projectAuth: { allowedRoleIds: ['role-project'], allowedUserIds: [] } }));
    const r = authz.authorize(input({ roleIds: [], action: 'drive', isAdministrator: true }));
    expect(r.allowed).toBe(true);
    expect(r.tier).toBe('admin');
  });

  it('a denied DM is NOT rescued by the Administrator flag (dmPolicy stays authoritative)', () => {
    store.save(makeConfig()); // dmPolicy defaults to 'deny'
    const { authz } = build();
    const r = authz.authorize(input({ roleIds: [], action: 'read', context: {}, isAdministrator: true }));
    expect(r.allowed).toBe(false);
    expect(r.reason).toMatch(/dmPolicy=deny/);
  });
});
