import { describe, it, expect, vi } from 'vitest';
import { DiscordAPIError, Events, PermissionFlagsBits, type Client, type Interaction } from 'discord.js';
import {
  adaptInteraction,
  buildSlashCommands,
  DiscordClient,
  resolveChannelAdapter,
  resolveChannelResult,
  toMessageOptions,
} from './client.js';
import type { Logger } from '../core/contracts.js';
import type { MessageRouter } from './messageRouter.js';
import type { InteractionRouter } from './interactionRouter.js';

// The `/mode backend` choices must be built from the REGISTERED backend list, so a
// backend that is not yet registered (Codex before Phase 2) is never offered.

// Pull the `backend` string-option choices out of the `/mode backend` subcommand.
function backendChoiceValues(backends: string[]): string[] {
  const commands = buildSlashCommands(backends);
  const mode = commands.find((c) => c.name === 'mode') as unknown as {
    options: {
      name: string;
      options?: { name: string; choices?: { name: string; value: string }[] }[];
    }[];
  };
  const backendSub = mode.options.find((o) => o.name === 'backend');
  const backendOpt = backendSub?.options?.find((o) => o.name === 'backend');
  return (backendOpt?.choices ?? []).map((ch) => ch.value);
}

describe('buildSlashCommands — /mode backend choices', () => {
  it('offers only the registered backends (Claude only, pre-Phase 2)', () => {
    expect(backendChoiceValues(['claude'])).toEqual(['claude']);
  });

  it('offers a later-registered backend generically (Claude + Codex)', () => {
    expect(backendChoiceValues(['claude', 'codex'])).toEqual(['claude', 'codex']);
  });

  it('does NOT offer Codex when it is not registered', () => {
    expect(backendChoiceValues(['claude'])).not.toContain('codex');
  });
});

describe('buildSlashCommands — /mode backend "custom" label', () => {
  function customChoiceName(backends: string[], opts?: { customBackendLabel?: string }) {
    const commands = buildSlashCommands(backends, opts);
    const mode = commands.find((c) => c.name === 'mode') as unknown as {
      options: { name: string; options?: { name: string; choices?: { name: string; value: string }[] }[] }[];
    };
    const backendOpt = mode.options.find((o) => o.name === 'backend')?.options?.find((o) => o.name === 'backend');
    return backendOpt?.choices?.find((c) => c.value === 'custom')?.name;
  }

  it('names the ACTUAL configured provider, not a fixed one (e.g. Kimi)', () => {
    expect(customChoiceName(['claude', 'custom'], { customBackendLabel: 'Custom (kimi-k2.7-code)' })).toBe(
      'Custom (kimi-k2.7-code)',
    );
    // A different dotfile → a different label, proving it is not hardcoded per-provider.
    expect(customChoiceName(['custom'], { customBackendLabel: 'Custom (some-other-model)' })).toBe(
      'Custom (some-other-model)',
    );
  });

  it('falls back to a live dotfile scan when no label is injected (never throws)', () => {
    // No opts.customBackendLabel — production's real path. customBackendLabel() never
    // throws (resolveCustomEnv degrades to {} on any read failure), so this must resolve
    // to SOME string rather than crashing command registration.
    expect(() => buildSlashCommands(['custom'])).not.toThrow();
    expect(typeof customChoiceName(['custom'])).toBe('string');
  });
});

describe('buildSlashCommands — /model', () => {
  it('registers /model as a TOP-LEVEL command (not a /mode subcommand)', () => {
    const commands = buildSlashCommands(['claude']);
    expect(commands.some((c) => c.name === 'model')).toBe(true);
    const mode = commands.find((c) => c.name === 'mode') as unknown as { options: { name: string }[] };
    expect(mode.options.some((o) => o.name === 'model')).toBe(false);
  });

  it('the `value` option is autocomplete-driven, NOT a static addChoices() list', () => {
    const commands = buildSlashCommands(['claude']);
    const model = commands.find((c) => c.name === 'model') as unknown as {
      options: { name: string; autocomplete?: boolean; choices?: unknown[] }[];
    };
    const value = model.options.find((o) => o.name === 'value');
    expect(value?.autocomplete).toBe(true);
    expect(value?.choices).toBeUndefined();
  });
});

describe('buildSlashCommands — /config', () => {
  it('registers /config gated to the Administrator default member permission', () => {
    const commands = buildSlashCommands(['claude']);
    const config = commands.find((c) => c.name === 'config') as unknown as {
      name: string;
      default_member_permissions?: string | null;
    };
    expect(config).toBeTruthy();
    // Administrator is bit 3 (0x8); default_member_permissions is the string bitfield.
    expect(config.default_member_permissions).toBeTruthy();
    expect((BigInt(config.default_member_permissions as string) & 0x8n) === 0x8n).toBe(true);
  });
});

describe('buildSlashCommands — /clear', () => {
  it('registers /clear as a TOP-LEVEL command (no options)', () => {
    const commands = buildSlashCommands(['claude']);
    const clear = commands.find((c) => c.name === 'clear') as unknown as {
      name: string;
      description?: string;
      options?: unknown[];
    };
    expect(clear).toBeTruthy();
    expect(clear.description).toMatch(/clear|fresh|context/i);
    // No subcommands/options — just restart-in-place with current settings.
    expect(clear.options ?? []).toEqual([]);
  });
});

// The OutgoingMessage → discord.js allowedMentions mapping. The update prompt now pings
// admin roles (or @here) on the control channel, so roles/here must render into
// allowedMentions while the existing "no explicit ping → suppress" default holds.
describe('toMessageOptions — allowedMentions', () => {
  it('maps mentionUserIds onto allowedMentions.users', () => {
    const opts = toMessageOptions({ content: 'hi', mentionUserIds: ['u1', 'u2'] });
    expect(opts.allowedMentions).toEqual({ users: ['u1', 'u2'] });
  });

  it('maps mentionRoleIds onto allowedMentions.roles', () => {
    const opts = toMessageOptions({ content: '<@&r1>', mentionRoleIds: ['r1'] });
    expect(opts.allowedMentions).toEqual({ roles: ['r1'] });
  });

  it('maps mentionHere onto the "everyone" parse type (required for @here to ping)', () => {
    const opts = toMessageOptions({ content: '@here', mentionHere: true });
    expect(opts.allowedMentions).toEqual({ parse: ['everyone'] });
  });

  it('combines users, roles, and @here in one allowedMentions', () => {
    const opts = toMessageOptions({ content: 'x', mentionUserIds: ['u1'], mentionRoleIds: ['r1'], mentionHere: true });
    expect(opts.allowedMentions).toEqual({ users: ['u1'], roles: ['r1'], parse: ['everyone'] });
  });

  it('suppresses accidental @mentions when content is present but no ping is requested', () => {
    const opts = toMessageOptions({ content: 'plain @everyone in text' });
    expect(opts.allowedMentions).toEqual({ parse: [] });
  });

  it('leaves allowedMentions unset for an embed-only message with no content and no pings', () => {
    const opts = toMessageOptions({ embeds: [{ title: 't' }] });
    expect(opts.allowedMentions).toBeUndefined();
  });
});

// The ChannelDelete gateway subscription (root fix for the Unknown Channel 10003
// crash): the client must forward a deleted GUILD channel's ids to onChannelDelete and
// ignore deleted DM channels (which host no session).
describe('DiscordClient — channelDelete subscription', () => {
  function harness(onChannelDelete?: (channelId: string, guildId: string) => void) {
    const handlers = new Map<string, (arg: unknown) => void>();
    const client = {
      once: (event: string, h: (arg: unknown) => void) => handlers.set(event, h),
      on: (event: string, h: (arg: unknown) => void) => handlers.set(event, h),
    } as unknown as Client;
    const logger: Logger = { debug() {}, info() {}, warn() {}, error() {} };
    new DiscordClient({
      clientId: 'app-1',
      logger,
      messageRouter: {} as unknown as MessageRouter,
      interactionRouter: {} as unknown as InteractionRouter,
      backends: () => ['claude'],
      onReady: async () => {},
      ...(onChannelDelete ? { onChannelDelete } : {}),
      client,
    });
    return handlers;
  }

  it('forwards a deleted guild channel id + guild id to onChannelDelete', () => {
    const seen: Array<[string, string]> = [];
    const handlers = harness((channelId, guildId) => seen.push([channelId, guildId]));
    const fire = handlers.get(Events.ChannelDelete);
    expect(fire).toBeTypeOf('function');
    fire!({ id: 'c1', guildId: 'g1', isDMBased: () => false });
    expect(seen).toEqual([['c1', 'g1']]);
  });

  it('ignores a deleted DM channel (no guild session to clean up)', () => {
    const seen: Array<[string, string]> = [];
    const handlers = harness((channelId, guildId) => seen.push([channelId, guildId]));
    handlers.get(Events.ChannelDelete)!({ id: 'd1', isDMBased: () => true });
    expect(seen).toEqual([]);
  });
});

describe('DiscordClient — /model autocomplete', () => {
  function harness(getModelAutocomplete: (q: string) => Promise<{ name: string; value: string }[]>) {
    const handlers = new Map<string, (arg: unknown) => void>();
    const client = {
      once: (event: string, h: (arg: unknown) => void) => handlers.set(event, h),
      on: (event: string, h: (arg: unknown) => void) => handlers.set(event, h),
    } as unknown as Client;
    const logger: Logger = { debug() {}, info() {}, warn() {}, error() {} };
    new DiscordClient({
      clientId: 'app-1',
      logger,
      messageRouter: {} as unknown as MessageRouter,
      interactionRouter: { getModelAutocomplete } as unknown as InteractionRouter,
      backends: () => ['claude'],
      onReady: async () => {},
      client,
    });
    return handlers;
  }

  it('routes /model value autocomplete through InteractionRouter.getModelAutocomplete', async () => {
    const getModelAutocomplete = vi.fn(async (q: string) => [{ name: `Opus (${q})`, value: 'opus' }]);
    const respond = vi.fn(async () => {});
    const fire = harness(getModelAutocomplete).get(Events.InteractionCreate);
    fire!({ isAutocomplete: () => true, commandName: 'model', options: { getFocused: () => 'op' }, respond });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    expect(getModelAutocomplete).toHaveBeenCalledWith('op');
    expect(respond).toHaveBeenCalledWith([{ name: 'Opus (op)', value: 'opus' }]);
  });

  it('responds empty for a command with no wired autocomplete handler', async () => {
    const getModelAutocomplete = vi.fn();
    const respond = vi.fn(async () => {});
    const fire = harness(getModelAutocomplete).get(Events.InteractionCreate);
    fire!({ isAutocomplete: () => true, commandName: 'other', options: { getFocused: () => '' }, respond });
    await Promise.resolve();
    await Promise.resolve();
    expect(getModelAutocomplete).not.toHaveBeenCalled();
    expect(respond).toHaveBeenCalledWith([]);
  });
});

describe('DiscordClient — /effort autocomplete', () => {
  function harness(
    getEffortAutocomplete: (g: string | null, c: string, q: string) => Promise<{ name: string; value: string }[]>,
  ) {
    const handlers = new Map<string, (arg: unknown) => void>();
    const client = {
      once: (event: string, h: (arg: unknown) => void) => handlers.set(event, h),
      on: (event: string, h: (arg: unknown) => void) => handlers.set(event, h),
    } as unknown as Client;
    const logger: Logger = { debug() {}, info() {}, warn() {}, error() {} };
    new DiscordClient({
      clientId: 'app-1',
      logger,
      messageRouter: {} as unknown as MessageRouter,
      interactionRouter: { getEffortAutocomplete } as unknown as InteractionRouter,
      backends: () => ['claude'],
      onReady: async () => {},
      client,
    });
    return handlers;
  }

  it('routes /effort value autocomplete through getEffortAutocomplete WITH the channel context', async () => {
    const getEffortAutocomplete = vi.fn(async (_g: string | null, _c: string, q: string) => [
      { name: `high (${q})`, value: 'high' },
    ]);
    const respond = vi.fn(async () => {});
    const fire = harness(getEffortAutocomplete).get(Events.InteractionCreate);
    fire!({
      isAutocomplete: () => true,
      commandName: 'effort',
      guildId: 'g1',
      channelId: 'c1',
      options: { getFocused: () => 'hi' },
      respond,
    });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    // guild + channel are threaded so the levels can be picked per the channel's backend/model.
    expect(getEffortAutocomplete).toHaveBeenCalledWith('g1', 'c1', 'hi');
    expect(respond).toHaveBeenCalledWith([{ name: 'high (hi)', value: 'high' }]);
  });
});

// adaptInteraction maps a real discord.js Interaction onto the router's narrow shape.
// discord.js is mocked here (fakes satisfy the type guards structurally), so these
// assert the adapter contract — the real reply/defer wiring is validated by live use.

// A fake chat-input interaction that records which discord.js ack method fired and
// tracks deferred/replied like the real interaction. `memberPermissions` mirrors
// discord.js's resolved PermissionsBitField.
function fakeSlash(over: { adminPerm?: boolean } = {}) {
  const calls: string[] = [];
  let deferred = false;
  let replied = false;
  const interaction = {
    guildId: 'g1',
    channelId: 'c1',
    user: { id: 'u1' },
    member: { roles: { cache: { map: (fn: (r: { id: string }) => string) => ['r1'].map((id) => fn({ id })) } } },
    memberPermissions: { has: (bit: bigint) => (over.adminPerm ?? false) && bit === PermissionFlagsBits.Administrator },
    commandName: 'config',
    options: { getSubcommand: () => { throw new Error('no subcommand'); }, getString: () => null },
    get deferred() { return deferred; },
    get replied() { return replied; },
    isChatInputCommand: () => true,
    isButton: () => false,
    isStringSelectMenu: () => false,
    isRoleSelectMenu: () => false,
    isChannelSelectMenu: () => false,
    deferReply: vi.fn(async (_o?: unknown) => { deferred = true; calls.push('deferReply'); }),
    reply: vi.fn(async (_o?: unknown) => { replied = true; calls.push('reply'); }),
    editReply: vi.fn(async (_o?: unknown) => { calls.push('editReply'); }),
    followUp: vi.fn(async (_o?: unknown) => { calls.push('followUp'); }),
  };
  return { interaction: interaction as unknown as Interaction, calls, raw: interaction };
}

// A fake button interaction that records showModal (the ack for a modal-open button).
function fakeButton(customId: string) {
  const calls: string[] = [];
  let modalArg: unknown;
  const interaction = {
    guildId: 'g1',
    channelId: 'c1',
    user: { id: 'u1' },
    member: { roles: { cache: { map: (fn: (r: { id: string }) => string) => ['r1'].map((id) => fn({ id })) } } },
    memberPermissions: { has: () => false },
    customId,
    get deferred() { return false; },
    get replied() { return false; },
    isChatInputCommand: () => false,
    isButton: () => true,
    isStringSelectMenu: () => false,
    isRoleSelectMenu: () => false,
    isChannelSelectMenu: () => false,
    isModalSubmit: () => false,
    deferUpdate: vi.fn(async () => { calls.push('deferUpdate'); }),
    reply: vi.fn(),
    deferReply: vi.fn(),
    editReply: vi.fn(),
    followUp: vi.fn(),
    showModal: vi.fn(async (m: unknown) => { calls.push('showModal'); modalArg = m; }),
  };
  return { interaction: interaction as unknown as Interaction, calls, getModalArg: () => modalArg };
}

// A fake modal-submit interaction exposing fields.getTextInputValue by custom id.
function fakeModalSubmit(customId: string, fields: Record<string, string>) {
  const interaction = {
    guildId: 'g1',
    channelId: 'c1',
    user: { id: 'u1' },
    member: { roles: { cache: { map: (fn: (r: { id: string }) => string) => ['r1'].map((id) => fn({ id })) } } },
    memberPermissions: { has: () => false },
    customId,
    fields: { getTextInputValue: (id: string) => { if (!(id in fields)) throw new Error('no field'); return fields[id]; } },
    get deferred() { return false; },
    get replied() { return false; },
    isChatInputCommand: () => false,
    isButton: () => false,
    isStringSelectMenu: () => false,
    isRoleSelectMenu: () => false,
    isChannelSelectMenu: () => false,
    isModalSubmit: () => true,
    reply: vi.fn(),
    deferReply: vi.fn(),
    editReply: vi.fn(),
    followUp: vi.fn(),
  };
  return { interaction: interaction as unknown as Interaction };
}

// The modal adapter is kept as GENERIC discord.js plumbing (ports.ts ModalSpec →
// discord.js ModalBuilder, and ModalSubmit → getField). The /config Codex-path modal
// that used to be its only caller is gone, so these use generic fixture ids.
describe('adaptInteraction — modal wiring (generic)', () => {
  it('a button exposes showModal that maps a ModalSpec onto discord.js showModal', async () => {
    const { interaction, calls, getModalArg } = fakeButton('some.button');
    const adapted = adaptInteraction(interaction);
    expect(adapted?.kind).toBe('component');
    if (!adapted || adapted.kind !== 'component') return;
    await adapted.showModal({
      customId: 'some.modal',
      title: 'Example',
      fields: [{ customId: 'some.field', label: 'value', value: 'x', required: true }],
    });
    // showModal fired (it is the ack); no defer preceded it.
    expect(calls).toEqual(['showModal']);
    // A discord.js ModalBuilder was passed (has toJSON).
    expect(typeof (getModalArg() as { toJSON?: unknown }).toJSON).toBe('function');
  });

  it('adapts a ModalSubmit interaction and reads a field value by custom id', () => {
    const { interaction } = fakeModalSubmit('some.modal', { 'some.field': 'value-1' });
    const adapted = adaptInteraction(interaction);
    expect(adapted?.kind).toBe('modalSubmit');
    if (!adapted || adapted.kind !== 'modalSubmit') return;
    expect(adapted.customId).toBe('some.modal');
    expect(adapted.getField('some.field')).toBe('value-1');
    // An absent field returns '' (never throws).
    expect(adapted.getField('missing')).toBe('');
  });
});

// The auto-provision wiring on ClientReady / GuildCreate (§ auto-provision, /init
// optional). discord.js is faked: the Client captures its event handlers so a test
// fires ClientReady / GuildCreate WITHOUT a gateway. The fake's token is empty so
// registerCommands fails fast (no REST/network) — the ready handler catches it and
// still runs auto-provision, which is what we assert here.
describe('DiscordClient auto-provision on ready / guild-join', () => {
  const noopLogger: Logger = { debug() {}, info() {}, warn() {}, error() {} };

  function fakeGatewayClient(guildIds: string[]) {
    const once = new Map<string, (arg: unknown) => void>();
    const on = new Map<string, (arg: unknown) => void>();
    const cache = new Map<string, unknown>(guildIds.map((id) => [id, { id }]));
    const ready = { user: { tag: 'bot#0001' }, guilds: { cache } };
    const client = {
      once: (event: string, handler: (arg: unknown) => void) => { once.set(event, handler); },
      on: (event: string, handler: (arg: unknown) => void) => { on.set(event, handler); },
      guilds: { cache },
      channels: { fetch: async () => null },
      token: '', // empty → registerCommands throws before any REST call (network-free)
    } as unknown as Client;
    return {
      client,
      fireReady: async () => {
        const handler = once.get(Events.ClientReady);
        if (!handler) throw new Error('no ClientReady handler registered');
        handler(ready);
        await new Promise((r) => setTimeout(r, 0));
      },
      fireGuildCreate: async (guildId: string) => {
        const handler = on.get(Events.GuildCreate);
        if (!handler) throw new Error('no GuildCreate handler registered');
        handler({ id: guildId, name: 'g' });
        await new Promise((r) => setTimeout(r, 0));
      },
    };
  }

  function build(client: Client, autoProvisionGuild?: (guildId: string, isNewGuild: boolean) => Promise<void>) {
    const messageRouter = {} as unknown as MessageRouter;
    const interactionRouter = {} as unknown as InteractionRouter;
    return new DiscordClient({
      clientId: 'cid',
      logger: noopLogger,
      messageRouter,
      interactionRouter,
      backends: () => ['claude'],
      onReady: async () => {},
      ...(autoProvisionGuild ? { autoProvisionGuild } : {}),
      client,
    });
  }

  it('invokes autoProvisionGuild for EVERY existing guild on ClientReady', async () => {
    const fc = fakeGatewayClient(['g1', 'g2']);
    const provisioned: string[] = [];
    build(fc.client, async (guildId) => { provisioned.push(guildId); });
    await fc.fireReady();
    expect(provisioned.sort()).toEqual(['g1', 'g2']);
  });

  it('invokes autoProvisionGuild when the bot is added to a new guild (GuildCreate)', async () => {
    const fc = fakeGatewayClient([]);
    const provisioned: string[] = [];
    build(fc.client, async (guildId) => { provisioned.push(guildId); });
    await fc.fireGuildCreate('new-guild');
    expect(provisioned).toEqual(['new-guild']);
  });

  it('a throwing autoProvisionGuild never crashes the ready handler', async () => {
    const fc = fakeGatewayClient(['g1']);
    build(fc.client, async () => { throw new Error('boom'); });
    // The ready handler catches per-guild failures — firing must not reject.
    await expect(fc.fireReady()).resolves.toBeUndefined();
  });

  it('is optional: no autoProvisionGuild dep → ClientReady still completes', async () => {
    const fc = fakeGatewayClient(['g1']);
    build(fc.client); // no autoProvisionGuild wired
    await expect(fc.fireReady()).resolves.toBeUndefined();
  });

  it('passes isNewGuild=false on ClientReady (existing) and true on GuildCreate (fresh invite)', async () => {
    // The flag is how the app decides to post the render-setup prompt on a fresh invite only,
    // never on the re-provisioning of existing guilds every restart.
    const fc = fakeGatewayClient(['existing-1']);
    const calls: Array<{ guildId: string; isNewGuild: boolean }> = [];
    build(fc.client, async (guildId, isNewGuild) => { calls.push({ guildId, isNewGuild }); });
    await fc.fireReady();
    await fc.fireGuildCreate('fresh-invite');
    expect(calls).toContainEqual({ guildId: 'existing-1', isNewGuild: false });
    expect(calls).toContainEqual({ guildId: 'fresh-invite', isNewGuild: true });
  });
});

// resolveChannelResult is the classification foundation (design §5.2): it maps a raw
// channels.fetch outcome onto ok/gone/unavailable so the wiring re-wire loop can tell a
// permanent deletion (10003) from a transient fault. discord.js error types stay in
// client.ts, so these tests construct real DiscordAPIError instances.
describe('resolveChannelResult — transient vs permanent classification', () => {
  function clientWithFetch(fetch: (id: string) => Promise<unknown>): Client {
    return { channels: { fetch } } as unknown as Client;
  }
  function djsError(code: number): DiscordAPIError {
    // (rawError, code, status, method, url, bodyData) — only `code` is read downstream.
    return new DiscordAPIError({ code, message: `code ${code}` }, code, code === 10003 ? 404 : 403, 'GET', 'https://x', {
      files: [],
      body: {},
    });
  }
  const sendableChannel = { id: 'c1', send: async () => ({ id: 'm1' }) };

  it('(a) a sendable channel → ok with a live sink', async () => {
    const res = await resolveChannelResult(clientWithFetch(async () => sendableChannel), 'c1');
    expect(res.status).toBe('ok');
    if (res.status !== 'ok') return;
    expect(typeof res.channel.send).toBe('function');
  });

  it('(b) a 10003 Unknown Channel throw → gone (the single permanent signal)', async () => {
    const res = await resolveChannelResult(clientWithFetch(async () => { throw djsError(10003); }), 'c1');
    expect(res.status).toBe('gone');
  });

  it('(c) a 50001 Missing Access throw → unavailable (transient; never cleaned up)', async () => {
    const res = await resolveChannelResult(clientWithFetch(async () => { throw djsError(50001); }), 'c1');
    expect(res.status).toBe('unavailable');
  });

  it('(d) a generic Error (ConnectTimeout / fetch failed) → unavailable', async () => {
    const res = await resolveChannelResult(clientWithFetch(async () => { throw new Error('fetch failed'); }), 'c1');
    expect(res.status).toBe('unavailable');
  });

  it('(e) null / a non-sendable channel (no exception) → unavailable (conservative)', async () => {
    const nullRes = await resolveChannelResult(clientWithFetch(async () => null), 'c1');
    expect(nullRes.status).toBe('unavailable');
    // A category/voice channel has no send() → not sendable → unavailable, not gone.
    const notSendable = await resolveChannelResult(clientWithFetch(async () => ({ id: 'cat' })), 'c1');
    expect(notSendable.status).toBe('unavailable');
  });
});

// resolveChannelAdapter is now a thin wrapper over resolveChannelResult; the null-or-channel
// contract every legacy caller (notifier/status/sendFile/resolveChannel port) relies on must
// be preserved: ok → a channel, everything else → null.
describe('resolveChannelAdapter — thin-wrapper regression (null-or-channel preserved)', () => {
  function clientWithFetch(fetch: (id: string) => Promise<unknown>): Client {
    return { channels: { fetch } } as unknown as Client;
  }
  function djsError(code: number): DiscordAPIError {
    return new DiscordAPIError({ code, message: `code ${code}` }, code, 404, 'GET', 'https://x', { files: [], body: {} });
  }

  it('ok → a channel; gone / transient / null all → null', async () => {
    const ok = await resolveChannelAdapter(clientWithFetch(async () => ({ id: 'c1', send: async () => ({ id: 'm' }) })), 'c1');
    expect(ok).not.toBeNull();
    const gone = await resolveChannelAdapter(clientWithFetch(async () => { throw djsError(10003); }), 'c1');
    expect(gone).toBeNull();
    const transient = await resolveChannelAdapter(clientWithFetch(async () => { throw new Error('boom'); }), 'c1');
    expect(transient).toBeNull();
    const missing = await resolveChannelAdapter(clientWithFetch(async () => null), 'c1');
    expect(missing).toBeNull();
  });
});

describe('adaptInteraction — acknowledgment wiring', () => {
  it('exposes deferReply/editReply/followUp and an acknowledged flag that tracks defer', async () => {
    const { interaction, raw } = fakeSlash();
    const adapted = adaptInteraction(interaction);
    expect(adapted).toBeTruthy();
    if (!adapted) return;
    expect(adapted.acknowledged).toBe(false);
    await adapted.deferReply({ ephemeral: true });
    expect(raw.deferReply).toHaveBeenCalledOnce();
    // The deferReply carried the Ephemeral flag.
    expect(raw.deferReply.mock.calls[0]?.[0]).toMatchObject({ flags: expect.anything() });
    // Now acknowledged → the guaranteed-error path uses editReply, not reply.
    expect(adapted.acknowledged).toBe(true);
    await adapted.editReply({ content: 'done' });
    expect(raw.editReply).toHaveBeenCalledOnce();
  });

  it('fills hasAdminPermission from interaction.memberPermissions (Administrator bit)', () => {
    expect(adaptInteraction(fakeSlash({ adminPerm: true }).interaction)?.hasAdminPermission).toBe(true);
    expect(adaptInteraction(fakeSlash({ adminPerm: false }).interaction)?.hasAdminPermission).toBe(false);
  });

  it('editReply omits the ephemeral flag (only deferReply/reply/followUp set visibility)', async () => {
    const { interaction, raw } = fakeSlash();
    const adapted = adaptInteraction(interaction);
    await adapted?.editReply({ content: 'x', ephemeral: true });
    // editReply body must not carry a flags key (discord.js rejects it).
    expect(raw.editReply.mock.calls[0]?.[0]).not.toHaveProperty('flags');
  });
});
