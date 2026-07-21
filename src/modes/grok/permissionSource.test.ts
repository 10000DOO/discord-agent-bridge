import { describe, it, expect } from 'vitest';
import {
  GrokPermissionSource,
  GROK_PERMISSION_FALLBACK,
  CLI_MISSING_IDENTITY,
  parseGrokPermissionModes,
} from './permissionSource.js';

const GROK_HELP_FIXTURE = `
Usage: grok [OPTIONS] [PROMPT]

Options:
      --output-format <OUTPUT_FORMAT>
          Output format for headless mode [default: plain] [possible values: plain, json, streaming-json]
      --permission-mode <MODE>
          Permission mode [possible values: default, acceptEdits, auto, dontAsk, bypassPermissions, plan]
      --reasoning-effort <EFFORT>
          Reasoning effort for reasoning models
`;

const GROK_HELP_SUBSET = `
      --permission-mode <MODE>
          [possible values: default, bypassPermissions]
`;

const GROK_HELP_WITH_UNKNOWN = `
      --permission-mode <MODE>
          [possible values: default, bypassPermissions, customMode, plan]
`;

describe('parseGrokPermissionModes', () => {
  it('picks the permission-mode block (not output-format)', () => {
    expect(parseGrokPermissionModes(GROK_HELP_FIXTURE)).toEqual([
      'default',
      'acceptEdits',
      'auto',
      'dontAsk',
      'bypassPermissions',
      'plan',
    ]);
  });

  it('returns [] when help has no bypassPermissions block', () => {
    expect(parseGrokPermissionModes('--output-format [possible values: plain, json]')).toEqual([]);
    expect(parseGrokPermissionModes('')).toEqual([]);
  });
});

describe('GrokPermissionSource', () => {
  it('serves modes/choices from injectable full help text', () => {
    const source = new GrokPermissionSource({
      runHelp: () => GROK_HELP_FIXTURE,
      resolveIdentity: () => '/bin/grok@1.0.0',
    });
    expect(source.permissionModes()).toEqual([
      'default',
      'acceptEdits',
      'auto',
      'dontAsk',
      'bypassPermissions',
      'plan',
    ]);
    const choices = source.permissionChoices();
    expect(choices.map((c) => c.value)).toEqual(source.permissionModes());
    expect(choices.find((c) => c.value === 'bypassPermissions')?.label).toBe(
      'bypassPermissions (auto-approve all tools)',
    );
    expect(choices.find((c) => c.value === 'default')?.label).toBe(
      'default (prompts are cancelled — tools are skipped)',
    );
    expect(choices.find((c) => c.value === 'plan')?.label).toContain('non-always-approve');
    expect(source.isKnownPermission('auto')).toBe(true);
    expect(source.isKnownPermission('workspace-write')).toBe(false);
  });

  it('serves a CLI subset when help only lists two modes', () => {
    const source = new GrokPermissionSource({
      runHelp: () => GROK_HELP_SUBSET,
      resolveIdentity: () => '/bin/grok@1',
    });
    expect(source.permissionModes()).toEqual(['default', 'bypassPermissions']);
  });

  it('filters unknown CLI tokens that are not in the PermMode set', () => {
    const source = new GrokPermissionSource({
      runHelp: () => GROK_HELP_WITH_UNKNOWN,
      resolveIdentity: () => '/bin/grok@1',
    });
    expect(source.permissionModes()).toEqual(['default', 'bypassPermissions', 'plan']);
    expect(source.isKnownPermission('customMode')).toBe(false);
  });

  it('falls back to GROK_PERMISSION_FALLBACK when help parse fails', () => {
    const empty = new GrokPermissionSource({
      runHelp: () => 'no values here',
      resolveIdentity: () => '/bin/grok@1',
    });
    expect(empty.permissionModes()).toEqual([...GROK_PERMISSION_FALLBACK]);

    const throws = new GrokPermissionSource({
      runHelp: () => {
        throw new Error('ENOENT');
      },
      resolveIdentity: () => '/bin/grok@1',
    });
    expect(throws.permissionModes()).toEqual([...GROK_PERMISSION_FALLBACK]);
  });

  it('falls back without calling help when CLI identity is missing', () => {
    let helpCalls = 0;
    const source = new GrokPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return GROK_HELP_FIXTURE;
      },
      resolveIdentity: () => CLI_MISSING_IDENTITY,
    });
    expect(source.permissionModes()).toEqual([...GROK_PERMISSION_FALLBACK]);
    expect(helpCalls).toBe(0);
  });

  it('re-uses cached help while CLI identity is unchanged', () => {
    let helpCalls = 0;
    const source = new GrokPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return GROK_HELP_FIXTURE;
      },
      resolveIdentity: () => '/bin/grok@1.0.0',
    });
    source.permissionModes();
    source.permissionChoices();
    source.isKnownPermission('plan');
    expect(helpCalls).toBe(1);
  });

  it('re-probes help when CLI version identity changes', () => {
    let helpCalls = 0;
    let version = '1.0.0';
    const source = new GrokPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return helpCalls === 1 ? GROK_HELP_SUBSET : GROK_HELP_FIXTURE;
      },
      resolveIdentity: () => `/bin/grok@${version}`,
    });
    expect(source.permissionModes()).toEqual(['default', 'bypassPermissions']);
    expect(helpCalls).toBe(1);
    version = '2.0.0';
    expect(source.permissionModes()).toContain('acceptEdits');
    expect(helpCalls).toBe(2);
  });

  it('re-probes help after CLI becomes available (installed later)', () => {
    let helpCalls = 0;
    let identity = CLI_MISSING_IDENTITY;
    const source = new GrokPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return GROK_HELP_SUBSET;
      },
      resolveIdentity: () => identity,
    });
    expect(source.permissionModes()).toEqual([...GROK_PERMISSION_FALLBACK]);
    expect(helpCalls).toBe(0);
    identity = '/Users/me/.grok/bin/grok@0.9.0';
    expect(source.permissionModes()).toEqual(['default', 'bypassPermissions']);
    expect(helpCalls).toBe(1);
  });
});
