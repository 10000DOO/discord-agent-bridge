import { execFileSync } from 'node:child_process';
import type { ModelChoice, PermMode } from '../../core/contracts.js';
import { findPossibleValuesBlock } from '../../core/cliPossibleValues.js';
import { resolveCliCommand } from '../../core/resolveCli.js';

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

/** Identity when the CLI binary cannot be resolved or --version fails hard. */
export const CLI_MISSING_IDENTITY = '';

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

const HELP_TIMEOUT_MS = 3_000;
const VERSION_TIMEOUT_MS = 2_000;

/** Injectable help-text producer (tests supply fixture help; default runs `grok --help`). */
export type RunHelpFn = () => string;
/** Injectable CLI identity (path@version). Empty string = CLI missing/unavailable. */
export type ResolveIdentityFn = () => string;

export interface GrokPermissionSourceOptions {
  runHelp?: RunHelpFn;
  resolveIdentity?: ResolveIdentityFn;
}

function bufferToString(v: string | Buffer | undefined): string {
  if (v === undefined) return '';
  return typeof v === 'string' ? v : v.toString('utf8');
}

function harvestExecOutput(err: unknown): string {
  const e = err as { stdout?: string | Buffer; stderr?: string | Buffer };
  return `${bufferToString(e.stdout)}\n${bufferToString(e.stderr)}`.trim();
}

function defaultRunHelp(): string {
  const cmd = resolveCliCommand('grok');
  try {
    return execFileSync(cmd, ['--help'], {
      encoding: 'utf8',
      timeout: HELP_TIMEOUT_MS,
      maxBuffer: 1024 * 1024,
    });
  } catch (err) {
    const out = harvestExecOutput(err);
    if (out.length > 0) return out;
    throw err;
  }
}

function defaultResolveIdentity(): string {
  let cmd: string;
  try {
    cmd = resolveCliCommand('grok');
  } catch {
    return CLI_MISSING_IDENTITY;
  }
  try {
    const ver = execFileSync(cmd, ['--version'], {
      encoding: 'utf8',
      timeout: VERSION_TIMEOUT_MS,
      maxBuffer: 64 * 1024,
    }).trim();
    return `${cmd}@${ver}`;
  } catch (err) {
    const out = harvestExecOutput(err);
    if (out.length > 0) return `${cmd}@${out}`;
    return `${cmd}@`;
  }
}

/** Pick the permission-mode block (contains bypassPermissions sentinel). */
export function parseGrokPermissionModes(helpText: string): string[] {
  const block = findPossibleValuesBlock(helpText, (values) => values.includes('bypassPermissions'));
  return block && block.length > 0 ? block : [];
}

function filterValid(modes: readonly string[]): string[] {
  return modes.filter((m) => VALID_PERM_MODES.has(m));
}

interface ModesCache {
  identity: string;
  modes: string[];
}

export class GrokPermissionSource {
  private readonly runHelp: RunHelpFn;
  private readonly resolveIdentity: ResolveIdentityFn;
  private cache: ModesCache | null = null;

  constructor(options: GrokPermissionSourceOptions = {}) {
    this.runHelp = options.runHelp ?? defaultRunHelp;
    this.resolveIdentity = options.resolveIdentity ?? defaultResolveIdentity;
  }

  /**
   * Permission-mode ids from CLI help (schema-filtered), or the static fallback. Never throws.
   * Re-checks CLI identity on every call; re-runs help only when identity changes.
   */
  permissionModes(): string[] {
    const identity = this.safeIdentity();
    if (this.cache && this.cache.identity === identity) {
      return this.cache.modes;
    }
    const modes = this.probeModes(identity);
    this.cache = { identity, modes };
    return modes;
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

  private safeIdentity(): string {
    try {
      return this.resolveIdentity() ?? CLI_MISSING_IDENTITY;
    } catch {
      return CLI_MISSING_IDENTITY;
    }
  }

  private probeModes(identity: string): string[] {
    // CLI not installed yet — fallback. Next call re-checks identity so a later install
    // (identity becomes path@version) triggers a real help probe.
    if (identity === CLI_MISSING_IDENTITY) {
      return filterValid(GROK_PERMISSION_FALLBACK);
    }
    try {
      const parsed = filterValid(parseGrokPermissionModes(this.runHelp()));
      return parsed.length > 0 ? parsed : filterValid(GROK_PERMISSION_FALLBACK);
    } catch {
      return filterValid(GROK_PERMISSION_FALLBACK);
    }
  }
}

// Module singleton for catalog / agent consumers.
export const grokPermissionSource = new GrokPermissionSource();
