import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { ConfigStore } from './config.js';
import { CONFIG_VERSION, type AppConfig } from './configSchema.js';

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    version: CONFIG_VERSION,
    discord: { token: 'bot-token-abc', clientId: '123456789' },
    auth: { adminRoleIds: ['a1'], executeRoleIds: [], readOnlyRoleIds: [], dmPolicy: 'deny' },
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
    profiles: {},
    usage: { userAgent: 'claude-code', cacheSec: 180 },
    audit: { channelId: null },
    locale: 'ko',
    logLevel: 'info',
    favorites: [],
    ...overrides,
  };
}

describe('ConfigStore', () => {
  let dir: string;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-config-'));
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('round-trips save → load', () => {
    const store = new ConfigStore(dir);
    const config = makeConfig({ locale: 'en' });
    store.save(config);
    const loaded = store.load();
    expect(loaded).toEqual(config);
  });

  it('applies defaults for missing fields', () => {
    const store = new ConfigStore(dir);
    // Write a minimal config with only secrets present.
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      store.configPath,
      JSON.stringify({ discord: { token: 't', clientId: 'c' } }),
      'utf-8',
    );
    const loaded = store.load();
    expect(loaded.version).toBe(CONFIG_VERSION);
    expect(loaded.defaults.mode).toBe('claude');
    expect(loaded.defaults.claudeModel).toBe('opus');
    expect(loaded.limits.permissionTimeoutSec).toBe(60);
    expect(loaded.policy.unknownCommand).toBe('confirm');
    expect(loaded.autoAllowClaudeTools).toEqual(['Read', 'Glob', 'Grep']);
    expect(loaded.auth.dmPolicy).toBe('deny');
    expect(loaded.logLevel).toBe('info');
  });

  it('merges nested overrides over defaults', () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      store.configPath,
      JSON.stringify({ discord: { token: 't', clientId: 'c' }, limits: { maxSessionsPerUser: 5 } }),
      'utf-8',
    );
    const loaded = store.load();
    expect(loaded.limits.maxSessionsPerUser).toBe(5);
    // Untouched sibling still gets its default.
    expect(loaded.limits.codexTimeoutMs).toBe(1_800_000);
  });

  it('throws when the config file is absent', () => {
    const store = new ConfigStore(dir);
    expect(() => store.load()).toThrow(/not found/i);
    expect(store.exists()).toBe(false);
  });

  it('rejects a malformed config (missing secrets)', () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(store.configPath, JSON.stringify({ locale: 'ko' }), 'utf-8');
    expect(() => store.load()).toThrow();
  });

  it('surfaces a clear validation error for a malformed nested section (not silently merged)', () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(dir, { recursive: true });
    // `auth` is an array, not an object — must be rejected by zod, not merged.
    fs.writeFileSync(
      store.configPath,
      JSON.stringify({ discord: { token: 't', clientId: 'c' }, auth: ['x'] }),
      'utf-8',
    );
    expect(() => store.load()).toThrow();

    // A primitive where an object is expected is likewise rejected.
    fs.writeFileSync(
      store.configPath,
      JSON.stringify({ discord: { token: 't', clientId: 'c' }, defaults: 5 }),
      'utf-8',
    );
    expect(() => store.load()).toThrow();
  });

  it('fail-safe: a corrupt server config is ignored (falls back to global, no throw)', () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(path.dirname(store.serverConfigPath('g1')), { recursive: true });
    // Not valid JSON — a hand-edited broken file.
    fs.writeFileSync(store.serverConfigPath('g1'), '{ this is not json', 'utf-8');
    const orig = console.warn;
    const warnings: unknown[] = [];
    console.warn = (...a: unknown[]) => warnings.push(a);
    try {
      expect(store.loadServerConfig('g1')).toBeNull();
    } finally {
      console.warn = orig;
    }
    expect(warnings.length).toBe(1);

    // A well-formed JSON that fails the schema is also treated as no override.
    fs.writeFileSync(store.serverConfigPath('g1'), JSON.stringify({ version: 'nope' }), 'utf-8');
    console.warn = () => {};
    try {
      expect(store.loadServerConfig('g1')).toBeNull();
    } finally {
      console.warn = orig;
    }
  });

  it('round-trips a per-server config', () => {
    const store = new ConfigStore(dir);
    const server = {
      version: 1,
      guildId: 'g1',
      defaults: { mode: 'codex' as const, permissionMode: 'plan' as const },
    };
    store.saveServerConfig(server);
    expect(store.loadServerConfig('g1')).toEqual(server);
    expect(store.loadServerConfig('missing')).toBeNull();
  });

  const permTest = process.platform === 'win32' ? it.skip : it;
  permTest('writes config.json with 0600 permissions', () => {
    const store = new ConfigStore(dir);
    store.save(makeConfig());
    const mode = fs.statSync(store.configPath).mode & 0o777;
    expect(mode).toBe(0o600);
  });

  it('addAutoAllowClaudeTool appends a new tool and persists (idempotent)', () => {
    const store = new ConfigStore(dir);
    store.save(makeConfig());
    expect(store.addAutoAllowClaudeTool('Bash')).toBe(true);
    expect(store.load().autoAllowClaudeTools).toContain('Bash');
    // A tool already present is a no-op.
    expect(store.addAutoAllowClaudeTool('Bash')).toBe(false);
    expect(store.load().autoAllowClaudeTools.filter((t) => t === 'Bash')).toHaveLength(1);
    // Existing tools are preserved.
    expect(store.load().autoAllowClaudeTools).toEqual(expect.arrayContaining(['Read', 'Glob', 'Grep', 'Bash']));
  });
});
