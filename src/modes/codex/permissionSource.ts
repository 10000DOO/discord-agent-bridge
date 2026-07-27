import type { ModelChoice } from '../../core/contracts.js';
import { findPossibleValuesBlock } from '../../core/cliPossibleValues.js';
import {
  CLI_MISSING_IDENTITY,
  createCliHelpRunner,
  CliHelpValueSource,
  type RunHelpFn,
  type ResolveIdentityFn,
} from '../shared/cliHelpCatalog.js';

// Codex DYNAMIC sandbox-mode source. Discovers `-s`/`--sandbox` values from the installed
// `codex --help` clap catalog so a CLI upgrade that adds/removes a sandbox mode surfaces
// without a bridge restart. No models_cache field for permissions — CLI help is the source
// of truth.
//
// Cache key = resolved binary path + `--version` output. On every catalog read we re-check
// that identity (cheap). Help is re-spawned only when the identity changes — covers:
//   • codex upgrade (version string changes)
//   • reinstall at a different path
//   • bridge started before codex was installed (identity was "missing", later becomes real)
// Fail-safe: any probe failure falls back to the static three-value list and NEVER throws.
// Must NOT import providerCatalog (circular).

// Static fallback = current documented -s values (matches codex --help today).
export const CODEX_SANDBOX_FALLBACK = [
  'read-only',
  'workspace-write',
  'danger-full-access',
] as const;

export type CodexSandboxFallback = (typeof CODEX_SANDBOX_FALLBACK)[number];

// Re-export shared types/constants so existing test import paths stay stable.
export { CLI_MISSING_IDENTITY };
export type { RunHelpFn, ResolveIdentityFn };

// Short English hints for known sandbox ids (selectable option labels, English only).
const CODEX_SANDBOX_HINTS: Record<string, string> = {
  'read-only': 'read-only, ask to run',
  'workspace-write': 'write in workspace',
  'danger-full-access': 'no sandbox (⚠ dangerous)',
};

export interface CodexPermissionSourceOptions {
  runHelp?: RunHelpFn;
  resolveIdentity?: ResolveIdentityFn;
}

/** Pick the sandbox block: the possible-values list containing a known sandbox sentinel. */
export function parseCodexSandboxModes(helpText: string): string[] {
  const block = findPossibleValuesBlock(
    helpText,
    (values) => values.includes('workspace-write') || values.includes('read-only'),
  );
  return block && block.length > 0 ? block : [];
}

export class CodexPermissionSource {
  private readonly source: CliHelpValueSource;

  constructor(options: CodexPermissionSourceOptions = {}) {
    const defaults = createCliHelpRunner('codex');
    this.source = new CliHelpValueSource({
      runHelp: options.runHelp ?? defaults.runHelp,
      resolveIdentity: options.resolveIdentity ?? defaults.resolveIdentity,
      fallback: CODEX_SANDBOX_FALLBACK,
      parseHelp: parseCodexSandboxModes,
    });
  }

  /**
   * Sandbox mode ids from CLI help, or the static fallback. Never throws.
   * Re-checks CLI identity on every call; re-runs help only when identity changes.
   */
  sandboxModes(): string[] {
    return this.source.values();
  }

  /** English {value,label} choices for the wizard/config permission step. */
  sandboxChoices(): ModelChoice[] {
    return this.sandboxModes().map((m) => {
      const hint = CODEX_SANDBOX_HINTS[m];
      return { value: m, label: hint ? `${m} (${hint})` : m };
    });
  }

  /** True when `value` is in the (dynamic or fallback) sandbox catalog. */
  isKnownSandbox(value: string): boolean {
    return this.sandboxModes().includes(value);
  }
}

// Module singleton for providerCatalog / policy consumers.
export const codexPermissionSource = new CodexPermissionSource();
