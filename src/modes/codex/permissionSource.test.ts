import { describe, it, expect } from 'vitest';
import {
  CodexPermissionSource,
  CODEX_SANDBOX_FALLBACK,
  CLI_MISSING_IDENTITY,
  parseCodexSandboxModes,
} from './permissionSource.js';

const CODEX_HELP_FIXTURE = `
Usage: codex [OPTIONS] [PROMPT]

Options:
  -s, --sandbox <SANDBOX_MODE>
          Select the sandbox policy to use when executing model-generated shell commands

          [possible values: read-only, workspace-write, danger-full-access]

      --output-format <FORMAT>
          [possible values: plain, json]

      --ask-for-approval <POLICY>
          Possible values:
          - untrusted: Only run trusted commands
`;

const CODEX_HELP_EXTRA_MODE = `
  -s, --sandbox <SANDBOX_MODE>
          [possible values: read-only, workspace-write, danger-full-access, network-write]
`;

describe('parseCodexSandboxModes', () => {
  it('picks the sandbox block (not other possible-values lists)', () => {
    expect(parseCodexSandboxModes(CODEX_HELP_FIXTURE)).toEqual([
      'read-only',
      'workspace-write',
      'danger-full-access',
    ]);
  });

  it('returns [] when help has no sandbox block', () => {
    expect(parseCodexSandboxModes('--output-format [possible values: plain, json]')).toEqual([]);
    expect(parseCodexSandboxModes('')).toEqual([]);
  });

  it('accepts a block identified by read-only alone', () => {
    expect(parseCodexSandboxModes('[possible values: read-only, locked-down]')).toEqual([
      'read-only',
      'locked-down',
    ]);
  });
});

describe('CodexPermissionSource', () => {
  it('serves modes/choices from injectable help text', () => {
    const source = new CodexPermissionSource({
      runHelp: () => CODEX_HELP_FIXTURE,
      resolveIdentity: () => '/bin/codex@1.0.0',
    });
    expect(source.sandboxModes()).toEqual([
      'read-only',
      'workspace-write',
      'danger-full-access',
    ]);
    expect(source.sandboxChoices()).toEqual([
      { value: 'read-only', label: 'read-only (read-only, ask to run)' },
      { value: 'workspace-write', label: 'workspace-write (write in workspace)' },
      { value: 'danger-full-access', label: 'danger-full-access (no sandbox (⚠ dangerous))' },
    ]);
    expect(source.isKnownSandbox('workspace-write')).toBe(true);
    expect(source.isKnownSandbox('acceptEdits')).toBe(false);
  });

  it('surfaces a new CLI mode when help lists it', () => {
    const source = new CodexPermissionSource({
      runHelp: () => CODEX_HELP_EXTRA_MODE,
      resolveIdentity: () => '/bin/codex@2.0.0',
    });
    expect(source.sandboxModes()).toContain('network-write');
    expect(source.isKnownSandbox('network-write')).toBe(true);
    expect(source.sandboxChoices().find((c) => c.value === 'network-write')?.label).toBe(
      'network-write',
    );
  });

  it('falls back to CODEX_SANDBOX_FALLBACK when help parse fails', () => {
    const empty = new CodexPermissionSource({
      runHelp: () => 'no values here',
      resolveIdentity: () => '/bin/codex@1',
    });
    expect(empty.sandboxModes()).toEqual([...CODEX_SANDBOX_FALLBACK]);

    const throws = new CodexPermissionSource({
      runHelp: () => {
        throw new Error('ENOENT');
      },
      resolveIdentity: () => '/bin/codex@1',
    });
    expect(throws.sandboxModes()).toEqual([...CODEX_SANDBOX_FALLBACK]);
    expect(throws.sandboxChoices().map((c) => c.value)).toEqual([...CODEX_SANDBOX_FALLBACK]);
  });

  it('falls back without calling help when CLI identity is missing', () => {
    let helpCalls = 0;
    const source = new CodexPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return CODEX_HELP_FIXTURE;
      },
      resolveIdentity: () => CLI_MISSING_IDENTITY,
    });
    expect(source.sandboxModes()).toEqual([...CODEX_SANDBOX_FALLBACK]);
    expect(source.sandboxModes()).toEqual([...CODEX_SANDBOX_FALLBACK]);
    expect(helpCalls).toBe(0);
  });

  it('re-uses cached help while CLI identity is unchanged', () => {
    let helpCalls = 0;
    const source = new CodexPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return CODEX_HELP_FIXTURE;
      },
      resolveIdentity: () => '/bin/codex@1.0.0',
    });
    source.sandboxModes();
    source.sandboxModes();
    source.sandboxChoices();
    source.isKnownSandbox('read-only');
    expect(helpCalls).toBe(1);
  });

  it('re-probes help when CLI version identity changes', () => {
    let helpCalls = 0;
    let version = '1.0.0';
    const source = new CodexPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return helpCalls === 1 ? CODEX_HELP_FIXTURE : CODEX_HELP_EXTRA_MODE;
      },
      resolveIdentity: () => `/bin/codex@${version}`,
    });
    expect(source.sandboxModes()).not.toContain('network-write');
    expect(helpCalls).toBe(1);
    version = '2.0.0';
    expect(source.sandboxModes()).toContain('network-write');
    expect(helpCalls).toBe(2);
  });

  it('re-probes help after CLI becomes available (installed later)', () => {
    let helpCalls = 0;
    let identity = CLI_MISSING_IDENTITY;
    const source = new CodexPermissionSource({
      runHelp: () => {
        helpCalls += 1;
        return CODEX_HELP_EXTRA_MODE;
      },
      resolveIdentity: () => identity,
    });
    expect(source.sandboxModes()).toEqual([...CODEX_SANDBOX_FALLBACK]);
    expect(helpCalls).toBe(0);
    identity = '/usr/local/bin/codex@0.143.0';
    expect(source.sandboxModes()).toContain('network-write');
    expect(helpCalls).toBe(1);
  });

  it('re-checks identity every call even when still missing (later install path)', () => {
    let identityCalls = 0;
    const source = new CodexPermissionSource({
      runHelp: () => CODEX_HELP_FIXTURE,
      resolveIdentity: () => {
        identityCalls += 1;
        return CLI_MISSING_IDENTITY;
      },
    });
    source.sandboxModes();
    source.sandboxModes();
    expect(identityCalls).toBe(2);
  });
});
