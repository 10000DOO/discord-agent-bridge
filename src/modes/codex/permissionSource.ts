import { execFileSync } from 'node:child_process';
import type { ModelChoice } from '../../core/contracts.js';
import { findPossibleValuesBlock } from '../../core/cliPossibleValues.js';
import { resolveCliCommand } from '../../core/resolveCli.js';

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

// Short English hints for known sandbox ids (selectable option labels, English only).
const CODEX_SANDBOX_HINTS: Record<string, string> = {
  'read-only': 'read-only, ask to run',
  'workspace-write': 'write in workspace',
  'danger-full-access': 'no sandbox (⚠ dangerous)',
};

const HELP_TIMEOUT_MS = 3_000;
const VERSION_TIMEOUT_MS = 2_000;

/** Identity when the CLI binary cannot be resolved or --version fails. */
export const CLI_MISSING_IDENTITY = '';

/** Injectable help-text producer (tests supply fixture help; default runs `codex --help`). */
export type RunHelpFn = () => string;
/** Injectable CLI identity (path@version). Empty string = CLI missing/unavailable. */
export type ResolveIdentityFn = () => string;

export interface CodexPermissionSourceOptions {
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
  const cmd = resolveCliCommand('codex');
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
    cmd = resolveCliCommand('codex');
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
    // Binary path resolved but version failed — still treat as "present" so help can run;
    // include path so a later working version invalidates the cache.
    return `${cmd}@`;
  }
}

/** Pick the sandbox block: the possible-values list containing a known sandbox sentinel. */
export function parseCodexSandboxModes(helpText: string): string[] {
  const block = findPossibleValuesBlock(
    helpText,
    (values) => values.includes('workspace-write') || values.includes('read-only'),
  );
  return block && block.length > 0 ? block : [];
}

interface ModesCache {
  identity: string;
  modes: string[];
}

export class CodexPermissionSource {
  private readonly runHelp: RunHelpFn;
  private readonly resolveIdentity: ResolveIdentityFn;
  private cache: ModesCache | null = null;

  constructor(options: CodexPermissionSourceOptions = {}) {
    this.runHelp = options.runHelp ?? defaultRunHelp;
    this.resolveIdentity = options.resolveIdentity ?? defaultResolveIdentity;
  }

  /**
   * Sandbox mode ids from CLI help, or the static fallback. Never throws.
   * Re-checks CLI identity on every call; re-runs help only when identity changes.
   */
  sandboxModes(): string[] {
    const identity = this.safeIdentity();
    if (this.cache && this.cache.identity === identity) {
      return this.cache.modes;
    }
    const modes = this.probeModes(identity);
    this.cache = { identity, modes };
    return modes;
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
      return [...CODEX_SANDBOX_FALLBACK];
    }
    try {
      const parsed = parseCodexSandboxModes(this.runHelp());
      return parsed.length > 0 ? parsed : [...CODEX_SANDBOX_FALLBACK];
    } catch {
      return [...CODEX_SANDBOX_FALLBACK];
    }
  }
}

// Module singleton for providerCatalog / policy consumers.
export const codexPermissionSource = new CodexPermissionSource();
