import { describe, it, expect, vi } from 'vitest';
import { PermissionFlagsBits, type Interaction } from 'discord.js';
import { adaptInteraction, buildSlashCommands } from './client.js';

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
    deferReply: vi.fn(async (_o?: unknown) => { deferred = true; calls.push('deferReply'); }),
    reply: vi.fn(async (_o?: unknown) => { replied = true; calls.push('reply'); }),
    editReply: vi.fn(async (_o?: unknown) => { calls.push('editReply'); }),
    followUp: vi.fn(async (_o?: unknown) => { calls.push('followUp'); }),
  };
  return { interaction: interaction as unknown as Interaction, calls, raw: interaction };
}

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
