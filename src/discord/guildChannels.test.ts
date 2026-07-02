import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  ensureGuildChannels,
  createSessionChannel,
  sessionChannelName,
  type GuildChannelProvisioner,
  type ProvisionedChannel,
} from './guildChannels.js';
import { ConfigStore } from '../core/config.js';
import { CONFIG_VERSION, type AppConfig } from '../core/configSchema.js';

// A fake GuildChannelProvisioner backed by an in-memory channel map, mirroring
// discord.js guild.channels.create/delete WITHOUT a gateway. Every create records the
// call so a test can assert idempotency (a reused channel makes no create call).
class FakeProvisioner implements GuildChannelProvisioner {
  readonly guildId = 'g1';
  // id → { name, type }. Seeded with pre-existing channels to exercise reuse.
  readonly channels = new Map<string, { name: string; type: 'category' | 'text'; parent?: string }>();
  readonly createdNames: string[] = [];
  readonly deleted: string[] = [];
  private seq = 0;

  seed(id: string, name: string, type: 'category' | 'text'): void {
    this.channels.set(id, { name, type });
  }

  channelExists(id: string): boolean {
    return this.channels.has(id);
  }

  private nextId(): string {
    this.seq += 1;
    return `chan-${this.seq}`;
  }

  async ensureCategory(name: string, existingId?: string): Promise<ProvisionedChannel> {
    if (existingId && this.channels.has(existingId)) {
      return { id: existingId, name: this.channels.get(existingId)!.name };
    }
    const id = this.nextId();
    this.channels.set(id, { name, type: 'category' });
    this.createdNames.push(name);
    return { id, name };
  }

  async ensureTextChannel(name: string, parentId: string, existingId?: string): Promise<ProvisionedChannel> {
    if (existingId && this.channels.has(existingId)) {
      return { id: existingId, name: this.channels.get(existingId)!.name };
    }
    const id = this.nextId();
    this.channels.set(id, { name, type: 'text', parent: parentId });
    this.createdNames.push(name);
    return { id, name };
  }

  async createTextChannel(name: string, parentId?: string): Promise<ProvisionedChannel> {
    const id = this.nextId();
    this.channels.set(id, { name, type: 'text', ...(parentId ? { parent: parentId } : {}) });
    this.createdNames.push(name);
    return { id, name };
  }

  async deleteChannel(id: string): Promise<void> {
    this.channels.delete(id);
    this.deleted.push(id);
  }
}

function writeConfig(dir: string): void {
  const config: AppConfig = {
    version: CONFIG_VERSION,
    discord: { token: 'x', clientId: 'cid' },
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
    autoAllowClaudeTools: ['Read'],
    profiles: {},
    usage: { userAgent: 'claude-code', cacheSec: 180 },
    audit: { channelId: null },
    locale: 'ko',
    logLevel: 'info',
    favorites: [],
  };
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify(config));
}

let home: string;
let store: ConfigStore;

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-gc-'));
  writeConfig(home);
  store = new ConfigStore(home);
});
afterEach(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

describe('ensureGuildChannels', () => {
  it('creates the category + control channel + sessions category and persists the ids', async () => {
    const prov = new FakeProvisioner();
    const channels = await ensureGuildChannels(prov, store);

    // Three channels were created (control category, control channel, sessions category).
    expect(prov.createdNames).toHaveLength(3);
    expect(channels.categoryId).toBeTruthy();
    expect(channels.controlChannelId).toBeTruthy();
    expect(channels.sessionsCategoryId).toBeTruthy();
    expect(channels.statusChannelId).toBeNull();

    // The control channel is parented to the control category.
    expect(prov.channels.get(channels.controlChannelId)?.parent).toBe(channels.categoryId);

    // Persisted to servers/g1.json.
    const saved = store.loadServerConfig('g1');
    expect(saved?.channels).toEqual(channels);
  });

  it('is idempotent: a second run reuses the stored channels and creates nothing new', async () => {
    const prov = new FakeProvisioner();
    const first = await ensureGuildChannels(prov, store);
    expect(prov.createdNames).toHaveLength(3);

    // Re-run against the SAME provisioner (channels still exist) → no new creates,
    // same ids returned.
    const second = await ensureGuildChannels(prov, store);
    expect(prov.createdNames).toHaveLength(3); // unchanged
    expect(second).toEqual(first);
  });

  it('re-creates only a channel that was deleted out from under it', async () => {
    const prov = new FakeProvisioner();
    const first = await ensureGuildChannels(prov, store);

    // The control channel gets deleted; a re-run must re-create ONLY it.
    prov.channels.delete(first.controlChannelId);
    const second = await ensureGuildChannels(prov, store);

    expect(second.categoryId).toBe(first.categoryId); // reused
    expect(second.sessionsCategoryId).toBe(first.sessionsCategoryId); // reused
    expect(second.controlChannelId).not.toBe(first.controlChannelId); // re-created
    // Exactly one additional create (the control channel).
    expect(prov.createdNames).toHaveLength(4);
    // The re-created id is persisted.
    expect(store.loadServerConfig('g1')?.channels?.controlChannelId).toBe(second.controlChannelId);
  });

  it('preserves existing server auth/defaults when persisting channels (first /init)', async () => {
    // A /config-created server file already has auth; /init must not clobber it.
    store.saveServerConfig({ version: 1, guildId: 'g1', auth: { executeRoleIds: ['role-exec'] } });
    const prov = new FakeProvisioner();
    await ensureGuildChannels(prov, store);
    const saved = store.loadServerConfig('g1');
    expect(saved?.auth?.executeRoleIds).toEqual(['role-exec']);
    expect(saved?.channels).toBeDefined();
  });
});

describe('createSessionChannel', () => {
  it('creates a proj-<folder> channel under the sessions category', async () => {
    const prov = new FakeProvisioner();
    const created = await createSessionChannel(prov, '/abs/path/My Project', 'sessions-cat');
    expect(created.name).toBe('proj-my-project');
    expect(prov.channels.get(created.id)?.parent).toBe('sessions-cat');
  });

  it('creates the channel without a parent when no sessions category is given', async () => {
    const prov = new FakeProvisioner();
    const created = await createSessionChannel(prov, '/abs/path/thing');
    expect(prov.channels.get(created.id)?.parent).toBeUndefined();
  });
});

describe('sessionChannelName', () => {
  it('slugifies the folder basename with a proj- prefix', () => {
    expect(sessionChannelName('/home/me/My_App')).toBe('proj-my-app');
    expect(sessionChannelName('/home/me/foo.bar')).toBe('proj-foo-bar');
    expect(sessionChannelName('/home/me/repo/')).toBe('proj-repo');
  });

  it('falls back to proj-session for an empty/unusable basename', () => {
    expect(sessionChannelName('/')).toBe('proj-session');
    expect(sessionChannelName('///')).toBe('proj-session');
  });

  it('caps the name at Discord’s 100-char limit', () => {
    const long = '/x/' + 'a'.repeat(200);
    expect(sessionChannelName(long).length).toBeLessThanOrEqual(100);
  });
});
