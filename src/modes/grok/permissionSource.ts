import type { ModelChoice, PermMode } from '../../core/contracts.js';
import { findPossibleValuesBlock } from '../../core/cliPossibleValues.js';
import {
  CLI_MISSING_IDENTITY,
  createCliHelpRunner,
  CliHelpValueSource,
  type RunHelpFn,
  type ResolveIdentityFn,
} from '../shared/cliHelpCatalog.js';

// Grok DYNAMIC permission-mode source. Discovers `--permission-mode` values from the
// installed `grok --help` clap catalog so a CLI upgrade surfaces without a bridge restart.
// No models_cache field for permissions — CLI help is the source of truth.
//
// Honesty: docs say the flag only truly applies bypassPermissions and default for policy;
// other values are accepted but may not change policy the same way. Session wiring still
// maps only `bypassPermissions` → `--always-approve`; every other mode stays on the
// Discord/ACP interactive path. Labels for known ids stay honest English hints.
//
// Cache key = resolved binary path + `--version` output. On every catalog read we re-check
// that identity (cheap). Help is re-spawned only when the identity changes — covers:
//   • grok upgrade (version string changes)
//   • reinstall at a different path
//   • bridge started before grok was installed (identity was "missing", later becomes real)
// Fail-safe: probe failure → full CLI default list fallback; NEVER throws.
// Must NOT import providerCatalog (circular).

// Full CLI default list (matches current `grok --help`). Preferred over the old enforced
// two-mode subset so the catalog mirrors the installed CLI when the probe fails too.
export const GROK_PERMISSION_FALLBACK = [
  'default',
  'acceptEdits',
  'auto',
  'dontAsk',
  'bypassPermissions',
  'plan',
] as const;

// Re-export shared types/constants so existing test import paths stay stable.
export { CLI_MISSING_IDENTITY };
export type { RunHelpFn, ResolveIdentityFn };

// Values we will offer/persist: intersection with the Claude PermMode set (state schema).
const VALID_PERM_MODES = new Set<string>([
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
  'dontAsk',
  'auto',
]);

// Honest English labels for known ids. Enforced pair keeps the prior wording; others note
// they are accepted by the CLI but ride the non-always-approve (Discord/ACP) path.
const GROK_PERMISSION_LABELS: Record<string, string> = {
  bypassPermissions: 'bypassPermissions (auto-approve all tools)',
  default: 'default (prompts are cancelled — tools are skipped)',
  acceptEdits: 'acceptEdits (accepted by CLI; non-always-approve path)',
  auto: 'auto (accepted by CLI; non-always-approve path)',
  dontAsk: 'dontAsk (accepted by CLI; non-always-approve path)',
  plan: 'plan (accepted by CLI; non-always-approve path)',
};

export interface GrokPermissionSourceOptions {
  runHelp?: RunHelpFn;
  resolveIdentity?: ResolveIdentityFn;
}

/** Pick the permission-mode block (contains bypassPermissions sentinel). */
export function parseGrokPermissionModes(helpText: string): string[] {
  const block = findPossibleValuesBlock(helpText, (values) => values.includes('bypassPermissions'));
  return block && block.length > 0 ? block : [];
}

function filterValid(modes: readonly string[]): string[] {
  return modes.filter((m) => VALID_PERM_MODES.has(m));
}

export class GrokPermissionSource {
  private readonly source: CliHelpValueSource;

  constructor(options: GrokPermissionSourceOptions = {}) {
    const defaults = createCliHelpRunner('grok');
    this.source = new CliHelpValueSource({
      runHelp: options.runHelp ?? defaults.runHelp,
      resolveIdentity: options.resolveIdentity ?? defaults.resolveIdentity,
      fallback: GROK_PERMISSION_FALLBACK,
      parseHelp: parseGrokPermissionModes,
      filter: filterValid,
    });
  }

  /**
   * Permission-mode ids from CLI help (schema-filtered), or the static fallback. Never throws.
   * Re-checks CLI identity on every call; re-runs help only when identity changes.
   */
  permissionModes(): string[] {
    return this.source.values();
  }

  /** English {value,label} choices for the wizard/config permission step. */
  permissionChoices(): ModelChoice[] {
    return this.permissionModes().map((m) => {
      const label = GROK_PERMISSION_LABELS[m];
      return { value: m, label: label ?? m };
    });
  }

  /** True when `value` is in the (dynamic or fallback) permission catalog. */
  isKnownPermission(value: string): boolean {
    return this.permissionModes().includes(value);
  }

  /** Same list typed as PermMode[] for Capabilities.permissionModes. */
  permissionModesAsPermModes(): PermMode[] {
    return this.permissionModes() as PermMode[];
  }
}

// Module singleton for catalog / agent consumers.
export const grokPermissionSource = new GrokPermissionSource();
