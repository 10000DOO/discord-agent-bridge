import { describe, it, expect } from 'vitest';
import { buildSlashCommands } from './client.js';

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
