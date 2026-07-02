import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { ConfigPanel, isConfigPanelId, type ConfigPanelDefaults } from './configPanel.js';
import { ConfigStore } from '../core/config.js';
import type { PermMode } from '../core/contracts.js';

// The /config panel is transport-agnostic (no discord.js): it takes plain inputs
// (role-select `values`, string-select `value`, Save) and persists to a temp-dir
// ConfigStore. These tests drive it directly, exactly as the router does.

const ADMIN = ['role-admin-1'];
const EXEC = ['role-exec-1'];
const READ = ['role-read-1'];

const DEFAULTS: ConfigPanelDefaults = {
  adminRoleIds: ADMIN,
  executeRoleIds: EXEC,
  readOnlyRoleIds: READ,
  backend: 'claude',
  model: 'opus',
  permMode: 'default' as PermMode,
};

let dir: string;
let store: ConfigStore;

function makePanel(overrides: Partial<ConfigPanelDefaults> = {}): ConfigPanel {
  return new ConfigPanel({
    guildId: 'g1',
    ownerId: 'admin-user',
    configStore: store,
    defaults: { ...DEFAULTS, ...overrides },
    backends: ['claude', 'codex'],
    models: ['opus', 'sonnet'],
    permModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
  });
}

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-cfgpanel-'));
  store = new ConfigStore(dir);
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

describe('isConfigPanelId', () => {
  it('recognizes config panel component ids and rejects others', () => {
    expect(isConfigPanelId('config.role.admin')).toBe(true);
    expect(isConfigPanelId('config.save')).toBe(true);
    expect(isConfigPanelId('backend')).toBe(false);
    expect(isConfigPanelId('perm:req-1:allow')).toBe(false);
  });
});

describe('ConfigPanel render', () => {
  it('renders 3 role-selects (prefilled), 3 string-selects, and a Save button', () => {
    const { rows } = makePanel().render();
    // Flatten to the components in order.
    const all = rows.flatMap((r) => r.components);
    const roleSelects = all.filter((c) => c.type === 'roleSelect');
    expect(roleSelects).toHaveLength(3);
    // The admin role-select is prefilled with the current admin roles.
    const admin = roleSelects.find((c) => c.customId === 'config.role.admin');
    expect(admin && 'defaultRoleIds' in admin ? admin.defaultRoleIds : undefined).toEqual(ADMIN);

    const stringSelects = all.filter((c) => c.type === 'select');
    expect(stringSelects.map((c) => c.customId)).toEqual([
      'config.default.backend',
      'config.default.model',
      'config.default.permMode',
    ]);
    expect(all.some((c) => c.type === 'button' && c.customId === 'config.save')).toBe(true);
  });
});

describe('ConfigPanel save', () => {
  it('Save persists picked role ids + a default backend into servers/<guildId>.json', () => {
    const panel = makePanel();

    // Pick new admin + read-only roles via role-selects; touch a default backend.
    expect(panel.handle({ id: 'config.role.admin', values: ['new-admin'] })).toEqual({ kind: 'pending' });
    expect(panel.handle({ id: 'config.role.readOnly', values: ['new-read-a', 'new-read-b'] })).toEqual({ kind: 'pending' });
    expect(panel.handle({ id: 'config.default.backend', value: 'codex' })).toEqual({ kind: 'pending' });

    const result = panel.handle({ id: 'config.save' });
    expect(result.kind).toBe('saved');

    // The server file exists and carries the picked role ids + default.
    const saved = store.loadServerConfig('g1');
    expect(saved).not.toBeNull();
    expect(saved?.guildId).toBe('g1');
    expect(saved?.auth?.adminRoleIds).toEqual(['new-admin']);
    expect(saved?.auth?.readOnlyRoleIds).toEqual(['new-read-a', 'new-read-b']);
    // The UNTOUCHED execute tier keeps its prior (prefilled) value.
    expect(saved?.auth?.executeRoleIds).toEqual(EXEC);
    expect(saved?.defaults?.mode).toBe('codex');
  });

  it('confirmation summary reflects the picks (role mentions + default backend)', () => {
    const panel = makePanel();
    panel.handle({ id: 'config.role.admin', values: ['A1', 'A2'] });
    panel.handle({ id: 'config.default.model', value: 'sonnet' });
    const result = panel.handle({ id: 'config.save' });
    expect(result.kind).toBe('saved');
    if (result.kind !== 'saved') return;
    // Role mentions (<@&id>) for the picked admin roles.
    expect(result.summary).toContain('<@&A1>');
    expect(result.summary).toContain('<@&A2>');
    // The chosen default model appears.
    expect(result.summary).toContain('sonnet');
    // Untouched execute tier is still reported (its prior value).
    expect(result.summary).toContain('<@&role-exec-1>');
  });

  it('an untouched tier keeps the EXISTING server-file value (not the prefill) on Save', () => {
    // Pre-seed a server file with an execute tier different from the panel prefill.
    store.saveServerConfig({
      version: 2,
      guildId: 'g1',
      auth: { adminRoleIds: [], executeRoleIds: ['pre-existing-exec'], readOnlyRoleIds: [] },
    });

    const panel = makePanel();
    // Only touch admin; leave execute + read-only untouched.
    panel.handle({ id: 'config.role.admin', values: ['fresh-admin'] });
    panel.handle({ id: 'config.save' });

    const saved = store.loadServerConfig('g1');
    expect(saved?.auth?.adminRoleIds).toEqual(['fresh-admin']);
    // Untouched execute tier falls through to the existing server-file value.
    expect(saved?.auth?.executeRoleIds).toEqual(['pre-existing-exec']);
  });

  it('a role-select can CLEAR a tier (empty values) — deny-by-default for that tier', () => {
    const panel = makePanel();
    // Explicitly clear the execute tier.
    expect(panel.handle({ id: 'config.role.execute', values: [] })).toEqual({ kind: 'pending' });
    panel.handle({ id: 'config.save' });
    const saved = store.loadServerConfig('g1');
    expect(saved?.auth?.executeRoleIds).toEqual([]);
    // Admin (untouched) keeps its prefill.
    expect(saved?.auth?.adminRoleIds).toEqual(ADMIN);
  });

  it('a malformed role input (no `values`) is ignored, not stored as an empty tier', () => {
    const panel = makePanel();
    expect(panel.handle({ id: 'config.role.admin' })).toEqual({ kind: 'ignored' });
    panel.handle({ id: 'config.save' });
    const saved = store.loadServerConfig('g1');
    // Admin kept its prefill (the glitchy input did not blank it).
    expect(saved?.auth?.adminRoleIds).toEqual(ADMIN);
  });

  it('ignores an unknown component id', () => {
    const panel = makePanel();
    expect(panel.handle({ id: 'config.bogus' })).toEqual({ kind: 'ignored' });
  });
});
