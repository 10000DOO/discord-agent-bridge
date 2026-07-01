import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { StateStore } from './state/store.js';
import { ChannelRegistry, type ChannelBindingInput } from './channelRegistry.js';

function input(overrides: Partial<ChannelBindingInput> = {}): ChannelBindingInput {
  return {
    guildId: 'g1',
    channelId: 'c1',
    mode: 'claude',
    sessionId: 'sess-1',
    cwd: '/abs/workspace',
    ownerId: 'u1',
    permMode: 'default',
    profile: null,
    ...overrides,
  };
}

describe('ChannelRegistry', () => {
  let dir: string;
  // Deterministic clock so createdAt/updatedAt assertions are stable.
  let clock: string;
  const now = () => clock;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-chanreg-'));
    clock = '2026-01-01T00:00:00.000Z';
  });

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('set → get round-trip, keyed by guildId:channelId', () => {
    const reg = new ChannelRegistry(new StateStore(dir), now);
    reg.set(input());
    const got = reg.get('g1', 'c1');
    expect(got).toMatchObject({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'claude',
      sessionId: 'sess-1',
      cwd: '/abs/workspace',
      ownerId: 'u1',
      permMode: 'default',
      profile: null,
      archived: false,
    });
    // A different guild with the same channelId is a distinct binding.
    expect(reg.get('g2', 'c1')).toBeUndefined();
  });

  it('list returns all bindings', () => {
    const reg = new ChannelRegistry(new StateStore(dir), now);
    reg.set(input({ guildId: 'g1', channelId: 'c1' }));
    reg.set(input({ guildId: 'g1', channelId: 'c2' }));
    reg.set(input({ guildId: 'g2', channelId: 'c1' }));
    const keys = reg.list().map((b) => `${b.guildId}:${b.channelId}`).sort();
    expect(keys).toEqual(['g1:c1', 'g1:c2', 'g2:c1']);
  });

  it('remove deletes and reports presence', () => {
    const reg = new ChannelRegistry(new StateStore(dir), now);
    reg.set(input());
    expect(reg.remove('g1', 'c1')).toBe(true);
    expect(reg.get('g1', 'c1')).toBeUndefined();
    expect(reg.remove('g1', 'c1')).toBe(false);
  });

  it('markArchived flags without deleting', () => {
    const reg = new ChannelRegistry(new StateStore(dir), now);
    reg.set(input());
    const archived = reg.markArchived('g1', 'c1');
    expect(archived?.archived).toBe(true);
    expect(reg.get('g1', 'c1')?.archived).toBe(true);
    expect(reg.markArchived('g1', 'missing')).toBeUndefined();
  });

  it('persists through the state store and reloads on a fresh registry', () => {
    const store = new StateStore(dir);
    const reg = new ChannelRegistry(store, now);
    reg.set(input({ sessionId: 'sess-persist', projectAuth: { allowedRoleIds: ['r1'], allowedUserIds: [] } }));

    // Confirm it hit disk (the store's atomic write) by re-reading raw state.
    const onDisk = new StateStore(dir).load();
    expect(onDisk.channels['g1:c1']).toBeDefined();
    expect(onDisk.channels['g1:c1'].sessionId).toBe('sess-persist');
    expect(onDisk.channels['g1:c1'].projectAuth).toEqual({ allowedRoleIds: ['r1'], allowedUserIds: [] });

    // A brand-new registry over the same dir rehydrates the binding.
    const reloaded = new ChannelRegistry(new StateStore(dir), now);
    const got = reloaded.get('g1', 'c1');
    expect(got?.sessionId).toBe('sess-persist');
    expect(got?.channelId).toBe('c1');
    expect(got?.projectAuth).toEqual({ allowedRoleIds: ['r1'], allowedUserIds: [] });
  });

  it('preserves createdAt but refreshes updatedAt on replace', () => {
    const reg = new ChannelRegistry(new StateStore(dir), now);
    clock = '2026-01-01T00:00:00.000Z';
    reg.set(input());
    clock = '2026-02-02T00:00:00.000Z';
    const updated = reg.set(input({ sessionId: 'sess-2' }));
    expect(updated.createdAt).toBe('2026-01-01T00:00:00.000Z');
    expect(updated.updatedAt).toBe('2026-02-02T00:00:00.000Z');
    expect(updated.sessionId).toBe('sess-2');
  });
});
