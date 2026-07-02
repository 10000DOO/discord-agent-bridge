import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { runSetup, buildInviteUrl, type SetupPrompts } from './wizard.js';
import { ConfigStore } from '../core/config.js';
import type { Logger } from '../core/contracts.js';

// Zero-entropy fixtures: deliberately NOT secret-shaped so no scanner treats them as
// real credentials. The wizard never inspects the token's shape, so a plain token is
// a faithful stand-in.
const FIXTURE_TOKEN = 'test-token-value';
const FIXTURE_CLIENT_ID = '100000000000000001';

// A scripted prompt double: pops one answer per prompt call, in order. Role tiers are
// no longer prompted (they move to Discord `/config`), so the wizard now calls:
//   password(token) → input(clientId) → confirm(intent) → input(model) →
//   input(codexHome) → input(locale).
function scriptedPrompts(answers: {
  passwords: string[];
  inputs: string[];
  confirms: boolean[];
}): { prompts: SetupPrompts; passwordMessages: string[]; inputMessages: string[] } {
  const passwords = [...answers.passwords];
  const inputs = [...answers.inputs];
  const confirms = [...answers.confirms];
  const passwordMessages: string[] = [];
  const inputMessages: string[] = [];
  const prompts: SetupPrompts = {
    async password(config) {
      passwordMessages.push(config.message);
      const v = passwords.shift();
      if (v === undefined) throw new Error('no scripted password answer left');
      return v;
    },
    async input(config) {
      inputMessages.push(config.message);
      const v = inputs.shift();
      return v ?? config.default ?? '';
    },
    async confirm(config) {
      const v = confirms.shift();
      return v ?? config.default ?? false;
    },
  };
  return { prompts, passwordMessages, inputMessages };
}

// A logger double that records every message + meta it is handed, so a test can
// assert the token never reaches the operational log.
function recordingLogger(): { logger: Logger; entries: string[] } {
  const entries: string[] = [];
  const push = (message: string, meta: unknown[]) => {
    entries.push(message + ' ' + JSON.stringify(meta));
  };
  const logger: Logger = {
    debug: (m, ...meta) => push(m, meta),
    info: (m, ...meta) => push(m, meta),
    warn: (m, ...meta) => push(m, meta),
    error: (m, ...meta) => push(m, meta),
  };
  return { logger, entries };
}

let dir: string;
let store: ConfigStore;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-setup-'));
  store = new ConfigStore(dir);
});
afterEach(() => {
  fs.rmSync(dir, { recursive: true, force: true });
});

describe('buildInviteUrl', () => {
  it('contains the client id, both scopes, and a non-zero permission bitfield', () => {
    const url = buildInviteUrl(FIXTURE_CLIENT_ID);
    const parsed = new URL(url);
    expect(parsed.searchParams.get('client_id')).toBe(FIXTURE_CLIENT_ID);
    // scope carries both `bot` and `applications.commands`.
    const scope = parsed.searchParams.get('scope');
    expect(scope).toContain('bot');
    expect(scope).toContain('applications.commands');
    // permissions is a positive integer bitfield.
    const perms = parsed.searchParams.get('permissions');
    expect(perms).toBeTruthy();
    expect(BigInt(perms as string) > 0n).toBe(true);
  });
});

describe('runSetup', () => {
  it('writes a config with the entered token, clientId, and defaults', async () => {
    const { prompts } = scriptedPrompts({
      passwords: [FIXTURE_TOKEN],
      // clientId, model, codexHome, locale — NO role prompts.
      inputs: [FIXTURE_CLIENT_ID, 'sonnet', '/tmp/codex', 'en'],
      confirms: [true],
    });
    const opened: string[] = [];

    await runSetup({
      prompts,
      store,
      open: async (target) => {
        opened.push(target);
      },
      log: () => {},
    });

    const config = store.load();
    expect(config.discord.token).toBe(FIXTURE_TOKEN);
    expect(config.discord.clientId).toBe(FIXTURE_CLIENT_ID);
    expect(config.defaults.mode).toBe('claude');
    expect(config.defaults.claudeModel).toBe('sonnet');
    expect(config.defaults.codexHome).toBe('/tmp/codex');
    expect(config.locale).toBe('en');

    // The invite URL was opened, carrying the client id + both scopes + non-zero perms.
    expect(opened).toHaveLength(1);
    const parsed = new URL(opened[0]);
    expect(parsed.searchParams.get('client_id')).toBe(FIXTURE_CLIENT_ID);
    expect(parsed.searchParams.get('scope')).toContain('bot');
    expect(parsed.searchParams.get('scope')).toContain('applications.commands');
    expect(BigInt(parsed.searchParams.get('permissions') as string) > 0n).toBe(true);
  });

  it('no longer prompts for role tiers; writes EMPTY role allowlists', async () => {
    const { prompts, inputMessages } = scriptedPrompts({
      passwords: [FIXTURE_TOKEN],
      inputs: [FIXTURE_CLIENT_ID, '', '', ''],
      confirms: [true],
    });

    await runSetup({ prompts, store, open: async () => {}, log: () => {} });

    // No prompt message mentions admin/execute/read-only role tiers anymore.
    for (const msg of inputMessages) {
      expect(msg).not.toMatch(/역할|role/i);
    }

    // Role allowlists are all empty (deny-by-default until `/config` sets them).
    const config = store.load();
    expect(config.auth.adminRoleIds).toEqual([]);
    expect(config.auth.executeRoleIds).toEqual([]);
    expect(config.auth.readOnlyRoleIds).toEqual([]);
  });

  it('prints the `/config` guidance line pointing roles at Discord', async () => {
    const { prompts } = scriptedPrompts({
      passwords: [FIXTURE_TOKEN],
      inputs: [FIXTURE_CLIENT_ID, '', '', ''],
      confirms: [true],
    });
    const logs: string[] = [];

    await runSetup({ prompts, store, open: async () => {}, log: (m) => logs.push(m) });

    // The guidance line tells the operator to set roles in Discord via `/config`.
    expect(logs.some((l) => l.includes('/config') && l.includes('Discord'))).toBe(true);
  });

  it('writes 0600 config with defaults when optional fields are left blank', async () => {
    const { prompts } = scriptedPrompts({
      passwords: [FIXTURE_TOKEN],
      // clientId given; defaults all blank → wizard applies CONFIG_DEFAULTS
      inputs: [FIXTURE_CLIENT_ID, '', '', ''],
      confirms: [true],
    });

    await runSetup({ prompts, store, open: async () => {}, log: () => {} });

    const config = store.load();
    expect(config.auth.executeRoleIds).toEqual([]);
    expect(config.defaults.claudeModel).toBe('opus');
    expect(config.defaults.codexHome).toBe('~/.codex');
    expect(config.locale).toBe('ko');

    if (process.platform !== 'win32') {
      const mode = fs.statSync(store.configPath).mode & 0o777;
      expect(mode).toBe(0o600);
    }
  });

  it('never leaks the token to the operational logger or user output', async () => {
    const { prompts } = scriptedPrompts({
      passwords: [FIXTURE_TOKEN],
      inputs: [FIXTURE_CLIENT_ID, '', '', ''],
      confirms: [true],
    });
    const { logger, entries } = recordingLogger();
    const userOutput: string[] = [];

    await runSetup({
      prompts,
      store,
      logger,
      open: async () => {},
      log: (m) => userOutput.push(m),
    });

    // Token must never appear in any logged line or any user-facing output line.
    for (const line of [...entries, ...userOutput]) {
      expect(line).not.toContain(FIXTURE_TOKEN);
    }
    // But it WAS written to the (0600) config file.
    expect(store.load().discord.token).toBe(FIXTURE_TOKEN);
  });

  it('proceeds even if opening the browser throws', async () => {
    const { prompts } = scriptedPrompts({
      passwords: [FIXTURE_TOKEN],
      inputs: [FIXTURE_CLIENT_ID, '', '', ''],
      confirms: [true],
    });

    await runSetup({
      prompts,
      store,
      open: async () => {
        throw new Error('no browser here');
      },
      log: () => {},
    });

    // A failed open() does not abort the wizard — the config is still written.
    expect(store.exists()).toBe(true);
    expect(store.load().discord.clientId).toBe(FIXTURE_CLIENT_ID);
  });
});
