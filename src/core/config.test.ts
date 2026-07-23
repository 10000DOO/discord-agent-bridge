import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { ConfigStore } from './config.js';
import { CONFIG_VERSION, presetSchema, serverConfigSchema, type AppConfig } from './configSchema.js';

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    version: CONFIG_VERSION,
    discord: { token: 'bot-token-abc', clientId: '123456789' },
    auth: { adminRoleIds: ['a1'], executeRoleIds: [], readOnlyRoleIds: [], dmPolicy: 'deny' },
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
    render: { enabled: true },
    documentShare: {
      maxBytes: 524288,
      bodyMode: 'preview',
      previewMaxChars: 8000,
      extensions: ['.md', '.markdown'],
    },
    chromium: { decision: 'undecided' as const },
    locale: 'ko',
    logLevel: 'info',
    favorites: [],
    autoUpdate: { enabled: true },
    ...overrides,
  };
}

describe('presetSchema', () => {
  it('parses with only the required name/backend', () => {
    expect(presetSchema.parse({ name: 'p1', backend: 'claude' })).toEqual({ name: 'p1', backend: 'claude' });
  });

  it('accepts a Codex sandbox permMode via loose z.string() (a strict enum would reject it)', () => {
    const p = presetSchema.parse({ name: 'p1', backend: 'codex', permMode: 'workspace-write' });
    expect(p.permMode).toBe('workspace-write');
  });

  it('accepts an explicit null profile (raw mode) and optional model/effort', () => {
    const p = presetSchema.parse({ name: 'p1', backend: 'claude', model: 'opus', effort: 'high', profile: null });
    expect(p).toEqual({ name: 'p1', backend: 'claude', model: 'opus', effort: 'high', profile: null });
  });
});

describe('serverConfigSchema.presets', () => {
  it('preserves presets through parse (a z.object() would otherwise strip an undeclared key)', () => {
    const parsed = serverConfigSchema.parse({
      version: CONFIG_VERSION,
      guildId: 'g1',
      presets: [{ name: 'p1', backend: 'claude', model: 'opus' }],
    });
    expect(parsed.presets).toEqual([{ name: 'p1', backend: 'claude', model: 'opus' }]);
  });

  it('leaves presets undefined when absent', () => {
    const parsed = serverConfigSchema.parse({ version: CONFIG_VERSION, guildId: 'g1' });
    expect(parsed.presets).toBeUndefined();
  });
});

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
    expect(loaded.limits.permissionTimeoutSec).toBe(0);
    expect(loaded.policy.unknownCommand).toBe('confirm');
    expect(loaded.autoAllowClaudeTools).toEqual(['Read', 'Glob', 'Grep']);
    expect(loaded.auth.dmPolicy).toBe('deny');
    expect(loaded.logLevel).toBe('info');
    // Auto-update defaults ON, filled for a config.json that predates the field.
    expect(loaded.autoUpdate).toEqual({ enabled: true });
  });

  it('loads any defaults.mode string (registry is the validity gate, §5)', () => {
    const store = new ConfigStore(dir);
    // A backend id not in the old enum must load unchanged: the ModeRegistry — not the
    // schema — decides validity at use sites, and existing "claude"/"codex"/"custom"
    // files stay value-compatible (no version bump). Use a non-migrated fake id so this
    // stays independent of the grok → grok-build alias rewrite.
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, mode: 'future-backend' } }));
    expect(store.load().defaults.mode).toBe('future-backend');
    // A legacy enum value still round-trips.
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, mode: 'codex' } }));
    expect(store.load().defaults.mode).toBe('codex');
  });

  it('migrates retired grok / grok-agent defaults.mode to grok-build on load', () => {
    const store = new ConfigStore(dir);
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, mode: 'grok' } }));
    expect(store.load().defaults.mode).toBe('grok-build');
    store.save(makeConfig({ defaults: { ...makeConfig().defaults, mode: 'grok-agent' } }));
    expect(store.load().defaults.mode).toBe('grok-build');
  });

  it('preserves an explicit autoUpdate.enabled=false (backward-compatible)', () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      store.configPath,
      JSON.stringify({ discord: { token: 't', clientId: 'c' }, autoUpdate: { enabled: false } }),
      'utf-8',
    );
    expect(store.load().autoUpdate.enabled).toBe(false);
  });

  it('backfills render/chromium defaults for an older config that omits both keys', () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(dir, { recursive: true });
    // A pre-feature config.json: valid, but written before render/chromium existed.
    fs.writeFileSync(
      store.configPath,
      JSON.stringify({ discord: { token: 't', clientId: 'c' } }),
      'utf-8',
    );
    const loaded = store.load();
    expect(loaded.render).toEqual({ enabled: true });
    expect(loaded.chromium).toEqual({ decision: 'undecided' });
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

  it('migrates retired grok / grok-agent server defaults.mode to grok-build on load', () => {
    const store = new ConfigStore(dir);
    store.saveServerConfig({
      version: 1,
      guildId: 'g1',
      defaults: { mode: 'grok' },
    });
    expect(store.loadServerConfig('g1')?.defaults?.mode).toBe('grok-build');

    store.saveServerConfig({
      version: 1,
      guildId: 'g1',
      defaults: { mode: 'grok-agent' },
    });
    expect(store.loadServerConfig('g1')?.defaults?.mode).toBe('grok-build');
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

  it('addServerPreset appends a preset and preserves existing top-level server fields', () => {
    const store = new ConfigStore(dir);
    store.saveServerConfig({
      version: CONFIG_VERSION,
      guildId: 'g1',
      auth: { adminRoleIds: ['a1'] },
      defaults: { mode: 'codex' },
      locale: 'en',
    });
    store.addServerPreset('g1', { name: 'p1', backend: 'claude', model: 'opus' });
    const loaded = store.loadServerConfig('g1');
    expect(loaded?.presets).toEqual([{ name: 'p1', backend: 'claude', model: 'opus' }]);
    // Unrelated top-level fields survive the patch.
    expect(loaded?.auth?.adminRoleIds).toEqual(['a1']);
    expect(loaded?.defaults?.mode).toBe('codex');
    expect(loaded?.locale).toBe('en');
  });

  it('addServerPreset overwrites a same-name preset (name is the unique key)', () => {
    const store = new ConfigStore(dir);
    store.addServerPreset('g1', { name: 'p1', backend: 'claude', model: 'opus' });
    store.addServerPreset('g1', { name: 'p1', backend: 'codex', model: 'gpt-5.5' });
    const presets = store.loadServerConfig('g1')?.presets ?? [];
    expect(presets).toHaveLength(1);
    expect(presets[0]).toEqual({ name: 'p1', backend: 'codex', model: 'gpt-5.5' });
  });

  it('addServerPreset works when no server config exists yet (creates the file)', () => {
    const store = new ConfigStore(dir);
    store.addServerPreset('gNew', { name: 'p1', backend: 'claude' });
    expect(store.loadServerConfig('gNew')?.presets).toEqual([{ name: 'p1', backend: 'claude' }]);
  });

  it('addServerPreset retries the write and succeeds once read-after-write verifies', () => {
    const store = new ConfigStore(dir);
    const original = store.saveServerConfig.bind(store);
    let calls = 0;
    const spy = vi.spyOn(store, 'saveServerConfig').mockImplementation((cfg) => {
      calls++;
      // First attempt drops the write (simulated transient I/O failure) → the
      // read-after-write check misses the preset → the loop retries.
      if (calls === 1) return;
      original(cfg);
    });
    store.addServerPreset('g1', { name: 'p1', backend: 'claude' });
    expect(calls).toBe(2);
    expect(store.loadServerConfig('g1')?.presets).toEqual([{ name: 'p1', backend: 'claude' }]);
    spy.mockRestore();
  });

  it('addServerPreset throws after 3 attempts when read-after-write never verifies', () => {
    const store = new ConfigStore(dir);
    // Every write is dropped → verification never passes → all 3 retries fail.
    const spy = vi.spyOn(store, 'saveServerConfig').mockImplementation(() => {});
    expect(() => store.addServerPreset('g1', { name: 'p1', backend: 'claude' })).toThrow();
    expect(spy).toHaveBeenCalledTimes(3);
    // Nothing was persisted.
    expect(store.loadServerConfig('g1')).toBeNull();
    spy.mockRestore();
  });

  it('removeServerPreset returns true and removes; false for an unknown name or guild', () => {
    const store = new ConfigStore(dir);
    store.addServerPreset('g1', { name: 'p1', backend: 'claude' });
    store.addServerPreset('g1', { name: 'p2', backend: 'codex' });
    expect(store.removeServerPreset('g1', 'p1')).toBe(true);
    expect(store.loadServerConfig('g1')?.presets?.map((p) => p.name)).toEqual(['p2']);
    expect(store.removeServerPreset('g1', 'nope')).toBe(false);
    expect(store.removeServerPreset('gMissing', 'p1')).toBe(false);
  });

  it('presets survive an unrelated saveServerConfig round-trip (not stripped by z.object)', () => {
    const store = new ConfigStore(dir);
    store.addServerPreset('g1', {
      name: 'p1',
      backend: 'claude',
      model: 'opus',
      effort: 'high',
      permMode: 'plan',
      profile: null,
    });
    // A subsequent unrelated save (mirrors /config patchDefaults) must not drop presets.
    const existing = store.loadServerConfig('g1')!;
    store.saveServerConfig({ ...existing, locale: 'en' });
    expect(store.loadServerConfig('g1')?.presets).toEqual([
      { name: 'p1', backend: 'claude', model: 'opus', effort: 'high', permMode: 'plan', profile: null },
    ]);
  });
});
