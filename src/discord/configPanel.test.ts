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
  locale: 'ko',
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

// Small helpers to pull a defaults select and the option marked default-selected.
function selectById(rows: { components: unknown[] }[], customId: string) {
  const found = rows
    .flatMap((r) => r.components as { type: string; customId: string }[])
    .find((c) => c.type === 'select' && c.customId === customId);
  return found && found.type === 'select'
    ? (found as unknown as { customId: string; options: { value: string; default?: boolean }[] })
    : undefined;
}
function defaultSelectedValue(select: { options: { value: string; default?: boolean }[] } | undefined): string | undefined {
  return select?.options.find((o) => o.default === true)?.value;
}

describe('ConfigPanel render', () => {
  it('renders 3 role-selects (prefilled), 4 string-selects, and a Save button — no Codex-path button/modal', () => {
    const { roleRows, defaultRows } = makePanel().render();
    // Flatten to the components in order (both groups form the logical panel).
    const all = [...roleRows, ...defaultRows].flatMap((r) => r.components);
    const roleSelects = all.filter((c) => c.type === 'roleSelect');
    expect(roleSelects).toHaveLength(3);
    // The admin role-select is prefilled with the current admin roles.
    const admin = roleSelects.find((c) => c.customId === 'config.role.admin');
    expect(admin && 'defaultRoleIds' in admin ? admin.defaultRoleIds : undefined).toEqual(ADMIN);

    // backend / model / permMode / locale selects.
    const stringSelects = all.filter((c) => c.type === 'select');
    expect(stringSelects.map((c) => c.customId)).toEqual([
      'config.default.backend',
      'config.default.model',
      'config.default.permMode',
      'config.default.locale',
    ]);
    // The roles Save button exists; the Codex-path button/modal are GONE.
    expect(all.some((c) => c.type === 'button' && c.customId === 'config.save')).toBe(true);
    expect(all.some((c) => c.type === 'button' && c.customId === 'config.codexHome.open')).toBe(false);
    // The panel exposes no Codex-home modal any more.
    expect('codexHomeModal' in makePanel()).toBe(false);
    expect('handleCodexHomeSubmit' in makePanel()).toBe(false);
  });

  it('every defaults select marks its CURRENTLY-SAVED value as default-selected', () => {
    const { defaultRows } = makePanel({
      backend: 'codex',
      model: 'sonnet',
      permMode: 'acceptEdits' as PermMode,
      locale: 'en',
    }).render();
    expect(defaultSelectedValue(selectById(defaultRows, 'config.default.backend'))).toBe('codex');
    expect(defaultSelectedValue(selectById(defaultRows, 'config.default.model'))).toBe('sonnet');
    expect(defaultSelectedValue(selectById(defaultRows, 'config.default.permMode'))).toBe('acceptEdits');
    expect(defaultSelectedValue(selectById(defaultRows, 'config.default.locale'))).toBe('en');
    // Exactly ONE option per select is default-selected (no stray defaults).
    for (const id of ['config.default.backend', 'config.default.model', 'config.default.permMode', 'config.default.locale']) {
      const sel = selectById(defaultRows, id);
      expect(sel?.options.filter((o) => o.default === true)).toHaveLength(1);
    }
  });

  it('regression: the permission-mode select reflects the SAVED default (default), never bypassPermissions', () => {
    // The observed bug: the dropdown displayed "전체 자동 승인 (bypassPermissions)" while the
    // saved default was "기본 (default)". With the current value marked default-selected,
    // the pre-selected option must be `default` and NOT `bypassPermissions`.
    const { defaultRows } = makePanel({ permMode: 'default' as PermMode }).render();
    const perm = selectById(defaultRows, 'config.default.permMode');
    const def = perm?.options.find((o) => o.value === 'default');
    const bypass = perm?.options.find((o) => o.value === 'bypassPermissions');
    expect(def?.default).toBe(true);
    expect(bypass?.default).toBe(false);
    expect(defaultSelectedValue(perm)).toBe('default');
    // bypassPermissions is only default-selected when the user explicitly picked it.
    const bypassPanel = selectById(makePanel({ permMode: 'bypassPermissions' as PermMode }).render().defaultRows, 'config.default.permMode');
    expect(defaultSelectedValue(bypassPanel)).toBe('bypassPermissions');
  });

  it('role selects pre-select the currently-configured roles for every tier', () => {
    const { roleRows } = makePanel().render();
    const roleSelects = roleRows.flatMap((r) => r.components).filter((c) => c.type === 'roleSelect');
    const byId = (id: string) => roleSelects.find((c) => c.customId === id);
    const admin = byId('config.role.admin');
    const exec = byId('config.role.execute');
    const read = byId('config.role.readOnly');
    expect(admin && 'defaultRoleIds' in admin ? admin.defaultRoleIds : undefined).toEqual(ADMIN);
    expect(exec && 'defaultRoleIds' in exec ? exec.defaultRoleIds : undefined).toEqual(EXEC);
    expect(read && 'defaultRoleIds' in read ? read.defaultRoleIds : undefined).toEqual(READ);
  });

  it('the defaults message stays within Discord’s 5-action-row limit (4 selects, no button)', () => {
    const { roleRows, defaultRows } = makePanel().render();
    // A single Discord message allows at most 5 action rows.
    expect(roleRows.length).toBeLessThanOrEqual(5);
    // Removing the Codex-path button frees a row: the defaults message is now 4 selects.
    expect(defaultRows.length).toBe(4);
    expect(defaultRows.length).toBeLessThanOrEqual(5);
    // The Save button rides with the role tiers (the primary reply); the defaults
    // message auto-saves each field on change, so it carries NO Save button.
    expect(roleRows.flatMap((r) => r.components).some((c) => c.type === 'button' && c.customId === 'config.save')).toBe(true);
    expect(defaultRows.flatMap((r) => r.components).some((c) => c.type === 'button')).toBe(false);
    // No empty rows (Discord rejects them).
    for (const row of [...roleRows, ...defaultRows]) {
      expect(row.components.length).toBeGreaterThan(0);
    }
  });
});

describe('ConfigPanel save', () => {
  it('Save persists picked role ids into servers/<guildId>.json (defaults auto-save separately)', () => {
    const panel = makePanel();

    // Pick new admin + read-only roles via role-selects (batched until Save).
    expect(panel.handle({ id: 'config.role.admin', values: ['new-admin'] })).toEqual({ kind: 'pending' });
    expect(panel.handle({ id: 'config.role.readOnly', values: ['new-read-a', 'new-read-b'] })).toEqual({ kind: 'pending' });

    const result = panel.handle({ id: 'config.save' });
    expect(result.kind).toBe('saved');

    // The server file exists and carries the picked role ids.
    const saved = store.loadServerConfig('g1');
    expect(saved).not.toBeNull();
    expect(saved?.guildId).toBe('g1');
    expect(saved?.auth?.adminRoleIds).toEqual(['new-admin']);
    expect(saved?.auth?.readOnlyRoleIds).toEqual(['new-read-a', 'new-read-b']);
    // The UNTOUCHED execute tier keeps its prior (prefilled) value.
    expect(saved?.auth?.executeRoleIds).toEqual(EXEC);
  });

  it('confirmation summary reflects the picked role mentions and current defaults', () => {
    const panel = makePanel();
    panel.handle({ id: 'config.role.admin', values: ['A1', 'A2'] });
    const result = panel.handle({ id: 'config.save' });
    expect(result.kind).toBe('saved');
    if (result.kind !== 'saved') return;
    // Role mentions (<@&id>) for the picked admin roles.
    expect(result.summary).toContain('<@&A1>');
    expect(result.summary).toContain('<@&A2>');
    // Untouched execute tier is still reported (its prior value).
    expect(result.summary).toContain('<@&role-exec-1>');
    // The current default model (the prefill) is reported.
    expect(result.summary).toContain('opus');
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

describe('ConfigPanel defaults auto-save (per-field, no Save button)', () => {
  it('a backend select change persists defaults.mode immediately (no Save)', () => {
    const panel = makePanel();
    const result = panel.handle({ id: 'config.default.backend', value: 'codex' });
    expect(result.kind).toBe('autosaved');
    // Persisted right away — no Save call needed.
    expect(store.loadServerConfig('g1')?.defaults?.mode).toBe('codex');
  });

  it('a model select change persists defaults.claudeModel immediately', () => {
    const panel = makePanel();
    const result = panel.handle({ id: 'config.default.model', value: 'sonnet' });
    expect(result.kind).toBe('autosaved');
    expect(store.loadServerConfig('g1')?.defaults?.claudeModel).toBe('sonnet');
  });

  it('a permMode select change persists defaults.permissionMode immediately', () => {
    const panel = makePanel();
    const result = panel.handle({ id: 'config.default.permMode', value: 'acceptEdits' });
    expect(result.kind).toBe('autosaved');
    expect(store.loadServerConfig('g1')?.defaults?.permissionMode).toBe('acceptEdits');
  });

  it('auto-save writes ONLY the changed field, preserving the others', () => {
    const panel = makePanel();
    // Change three defaults in sequence; each merges over the prior server file.
    panel.handle({ id: 'config.default.backend', value: 'codex' });
    panel.handle({ id: 'config.default.model', value: 'sonnet' });
    panel.handle({ id: 'config.default.permMode', value: 'plan' });
    const saved = store.loadServerConfig('g1');
    expect(saved?.defaults?.mode).toBe('codex');
    expect(saved?.defaults?.claudeModel).toBe('sonnet');
    expect(saved?.defaults?.permissionMode).toBe('plan');
    // Auto-saving defaults must NOT write any role tiers (those need Save).
    expect(saved?.auth).toBeUndefined();
  });

  it('auto-save preserves role tiers already Saved to the server file', () => {
    // Pre-seed roles as if a prior Save had run.
    store.saveServerConfig({
      version: 2,
      guildId: 'g1',
      auth: { adminRoleIds: ['pre-admin'], executeRoleIds: ['pre-exec'], readOnlyRoleIds: [] },
    });
    const panel = makePanel();
    panel.handle({ id: 'config.default.model', value: 'sonnet' });
    const saved = store.loadServerConfig('g1');
    // The model landed AND the previously-saved roles are untouched.
    expect(saved?.defaults?.claudeModel).toBe('sonnet');
    expect(saved?.auth?.adminRoleIds).toEqual(['pre-admin']);
    expect(saved?.auth?.executeRoleIds).toEqual(['pre-exec']);
  });
});

describe('ConfigPanel locale', () => {
  it('a locale select change persists the per-guild locale immediately', () => {
    const panel = makePanel();
    const result = panel.handle({ id: 'config.default.locale', value: 'en' });
    expect(result.kind).toBe('autosaved');
    expect(store.loadServerConfig('g1')?.locale).toBe('en');
  });

  it('the locale notice names the chosen language', () => {
    const panel = makePanel();
    const result = panel.handle({ id: 'config.default.locale', value: 'en' });
    if (result.kind !== 'autosaved') throw new Error('expected autosaved');
    expect(result.notice).toContain('English');
  });
});
