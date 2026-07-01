import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { StateStore } from './store.js';
import { STATE_VERSION, type AppState, type ChannelBindingState } from './schema.js';

function binding(overrides: Partial<ChannelBindingState> = {}): ChannelBindingState {
  return {
    guildId: 'g1',
    mode: 'claude',
    sessionId: 'sess-1',
    cwd: '/abs/workspace',
    ownerId: 'u1',
    permissionMode: 'default',
    permissionProfile: null,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    archived: false,
    ...overrides,
  };
}

describe('StateStore', () => {
  let dir: string;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-state-'));
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('returns empty v2 state when file is absent', () => {
    const store = new StateStore(dir);
    const state = store.load();
    expect(state.version).toBe(STATE_VERSION);
    expect(state.channels).toEqual({});
    expect(state.scheduledCommands).toEqual([]);
  });

  it('round-trips save → load', () => {
    const store = new StateStore(dir);
    const state: AppState = {
      version: STATE_VERSION,
      channels: { 'g1:c1': binding() },
      scheduledCommands: [],
    };
    store.save(state);
    expect(store.load()).toEqual(state);
  });

  it('tolerates and normalizes unknown fields on read', () => {
    const store = new StateStore(dir);
    fs.writeFileSync(
      store.statePath,
      JSON.stringify({
        version: STATE_VERSION,
        channels: { 'g1:c1': { ...binding(), bogusField: 'x' } },
        scheduledCommands: [],
        extraTopLevel: true,
      }),
      'utf-8',
    );
    const loaded = store.load();
    expect(loaded.channels['g1:c1']).toEqual(binding());
    expect('extraTopLevel' in loaded).toBe(false);
    expect('bogusField' in loaded.channels['g1:c1']).toBe(false);
  });

  it('runs the v1 → v2 migration and rekeys channels', () => {
    const store = new StateStore(dir);
    // v1: channels keyed by bare channelId, guildId inside the binding.
    fs.writeFileSync(
      store.statePath,
      JSON.stringify({
        version: 1,
        channels: { c1: binding({ guildId: 'g9' }) },
      }),
      'utf-8',
    );
    const loaded = store.load();
    expect(loaded.version).toBe(STATE_VERSION);
    expect(loaded.channels['g9:c1']).toBeDefined();
    expect(loaded.channels['c1']).toBeUndefined();
  });

  it('rejects malformed state (bad permissionMode)', () => {
    const store = new StateStore(dir);
    fs.writeFileSync(
      store.statePath,
      JSON.stringify({
        version: STATE_VERSION,
        channels: { 'g1:c1': { ...binding(), permissionMode: 'nonsense' } },
      }),
      'utf-8',
    );
    expect(() => store.load()).toThrow();
  });

  it('never overwrites a valid target when the rename step fails', () => {
    const store = new StateStore(dir);
    // Occupy the state.json path with a non-empty DIRECTORY so tmp write succeeds
    // but rename onto it fails naturally (EISDIR/ENOTEMPTY) — no ESM spy needed.
    fs.mkdirSync(store.statePath, { recursive: true });
    fs.writeFileSync(path.join(store.statePath, 'sentinel'), 'keep', 'utf-8');
    const state: AppState = {
      version: STATE_VERSION,
      channels: { 'g1:c1': binding() },
      scheduledCommands: [],
    };
    expect(() => store.save(state)).toThrow();
    // The occupied path is untouched: still a directory holding the sentinel,
    // never replaced by a partial file. And the tmp scratch file is the only
    // extra artifact — it never became the live state.json.
    expect(fs.statSync(store.statePath).isDirectory()).toBe(true);
    expect(fs.readFileSync(path.join(store.statePath, 'sentinel'), 'utf-8')).toBe('keep');
  });
});
