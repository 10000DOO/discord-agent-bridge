import { describe, it, expect } from 'vitest';
import {
  parsePossibleValues,
  parseAllPossibleValueBlocks,
  findPossibleValuesBlock,
} from './cliPossibleValues.js';

describe('parsePossibleValues', () => {
  it('parses a standard clap [possible values: a, b, c] block', () => {
    expect(parsePossibleValues('[possible values: read-only, workspace-write, danger-full-access]')).toEqual([
      'read-only',
      'workspace-write',
      'danger-full-access',
    ]);
  });

  it('is case-insensitive on the "possible values" label', () => {
    expect(parsePossibleValues('[Possible Values: default, plan]')).toEqual(['default', 'plan']);
    expect(parsePossibleValues('[POSSIBLE VALUES: a, b]')).toEqual(['a', 'b']);
  });

  it('trims whitespace around tokens and drops empties', () => {
    expect(parsePossibleValues('[possible values:  a ,  b,  ,c  ]')).toEqual(['a', 'b', 'c']);
  });

  it('returns the first block only when several exist', () => {
    const text =
      'flag A [possible values: one, two]\nflag B [possible values: three, four]';
    expect(parsePossibleValues(text)).toEqual(['one', 'two']);
  });

  it('returns [] for empty/malformed input', () => {
    expect(parsePossibleValues('')).toEqual([]);
    expect(parsePossibleValues('no brackets here')).toEqual([]);
    expect(parsePossibleValues('[possible values:]')).toEqual([]);
    expect(parsePossibleValues('[possible values:   ]')).toEqual([]);
  });

  it('handles real codex --help sandbox fragment', () => {
    const fragment = `
  -s, --sandbox <SANDBOX_MODE>
          Select the sandbox policy

          [possible values: read-only, workspace-write, danger-full-access]
`;
    expect(parsePossibleValues(fragment)).toEqual([
      'read-only',
      'workspace-write',
      'danger-full-access',
    ]);
  });

  it('handles real grok --help permission-mode fragment', () => {
    const fragment =
      '--permission-mode <MODE>\n          Permission mode [possible values: default, acceptEdits, auto, dontAsk, bypassPermissions, plan]';
    expect(parsePossibleValues(fragment)).toEqual([
      'default',
      'acceptEdits',
      'auto',
      'dontAsk',
      'bypassPermissions',
      'plan',
    ]);
  });
});

describe('parseAllPossibleValueBlocks', () => {
  it('returns every block in order', () => {
    const text =
      'x [possible values: a, b]\ny [possible values: c]\nz [Possible Values: d, e]';
    expect(parseAllPossibleValueBlocks(text)).toEqual([['a', 'b'], ['c'], ['d', 'e']]);
  });

  it('returns [] when none match', () => {
    expect(parseAllPossibleValueBlocks('nothing')).toEqual([]);
  });
});

describe('findPossibleValuesBlock', () => {
  it('picks the sandbox block among mixed help text', () => {
    const text = `
      --output-format [possible values: plain, json]
      -s, --sandbox [possible values: read-only, workspace-write, danger-full-access]
      --other [possible values: foo, bar]
    `;
    expect(
      findPossibleValuesBlock(text, (v) => v.includes('workspace-write') || v.includes('read-only')),
    ).toEqual(['read-only', 'workspace-write', 'danger-full-access']);
  });

  it('picks the permission-mode block by bypassPermissions sentinel', () => {
    const text = `
      --output-format [possible values: plain, json, streaming-json]
      --permission-mode [possible values: default, acceptEdits, auto, dontAsk, bypassPermissions, plan]
    `;
    expect(findPossibleValuesBlock(text, (v) => v.includes('bypassPermissions'))).toEqual([
      'default',
      'acceptEdits',
      'auto',
      'dontAsk',
      'bypassPermissions',
      'plan',
    ]);
  });

  it('returns undefined when no block matches', () => {
    expect(findPossibleValuesBlock('[possible values: a, b]', (v) => v.includes('zzz'))).toBeUndefined();
  });
});
