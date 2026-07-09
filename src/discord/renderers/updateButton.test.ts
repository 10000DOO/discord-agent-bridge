import { describe, it, expect } from 'vitest';
import { buildUpdateId, parseUpdateId, buildUpdatePrompt, buildUpdateDecidedRow } from './updateButton.js';
import type { ButtonSpec } from '../ports.js';

describe('buildUpdateId / parseUpdateId', () => {
  it('round-trips approve and dismiss with a semver version', () => {
    expect(parseUpdateId(buildUpdateId('approve', '1.2.3'))).toEqual({ action: 'approve', version: '1.2.3' });
    expect(parseUpdateId(buildUpdateId('dismiss', '0.13.0'))).toEqual({ action: 'dismiss', version: '0.13.0' });
  });

  it('returns null for a foreign prefix', () => {
    expect(parseUpdateId('perm:abc:allow')).toBeNull();
    expect(parseUpdateId('interrupt:g:c')).toBeNull();
  });

  it('returns null for an unknown action', () => {
    expect(parseUpdateId('dab-update:install:1.2.3')).toBeNull();
  });

  it('returns null for a malformed / tampered id', () => {
    expect(parseUpdateId('dab-update:approve')).toBeNull(); // missing version
    expect(parseUpdateId('dab-update:approve:1.2.3:extra')).toBeNull(); // too many parts
    expect(parseUpdateId('dab-update:approve:')).toBeNull(); // empty version
    expect(parseUpdateId('dab-update:decided')).toBeNull(); // the disabled placeholder id
  });
});

describe('buildUpdatePrompt', () => {
  it('builds an embed and a Yes/No row wired to approve/dismiss customIds', () => {
    const { embed, rows } = buildUpdatePrompt('1.1.0', '1.0.0');
    expect(embed.title).toBeTruthy();
    expect(embed.description).toContain('1.1.0');
    expect(embed.description).toContain('1.0.0');
    expect(rows).toHaveLength(1);
    const buttons = rows[0]!.components as ButtonSpec[];
    expect(buttons.map((b) => b.customId)).toEqual(['dab-update:approve:1.1.0', 'dab-update:dismiss:1.1.0']);
    expect(buttons.map((b) => b.style)).toEqual(['success', 'secondary']);
    expect(buttons.every((b) => !b.disabled)).toBe(true);
  });
});

describe('buildUpdateDecidedRow', () => {
  it('is a single DISABLED button (so the clicked prompt cannot be re-clicked)', () => {
    for (const action of ['approve', 'dismiss'] as const) {
      const row = buildUpdateDecidedRow(action);
      expect(row.components).toHaveLength(1);
      const button = row.components[0] as ButtonSpec;
      expect(button.disabled).toBe(true);
      expect(button.label).toBeTruthy();
      // Its id is not a valid decision id, so a stray click is ignored by parseUpdateId.
      expect(parseUpdateId(button.customId)).toBeNull();
    }
  });
});
