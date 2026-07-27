import { execFileSync } from 'node:child_process';
import { resolveCliCommand } from '../../core/resolveCli.js';

// Shared CLI help/version identity probe + identity-keyed value cache.
// Used by Codex sandbox and Grok permission dynamic catalogs.
// Must NOT import providerCatalog (circular).

const HELP_TIMEOUT_MS = 3_000;
const VERSION_TIMEOUT_MS = 2_000;

/** Identity when the CLI binary cannot be resolved or --version fails hard. */
export const CLI_MISSING_IDENTITY = '';

/** Injectable help-text producer (tests supply fixture help; default runs `<bin> --help`). */
export type RunHelpFn = () => string;
/** Injectable CLI identity (path@version). Empty string = CLI missing/unavailable. */
export type ResolveIdentityFn = () => string;

function bufferToString(v: string | Buffer | undefined): string {
  if (v === undefined) return '';
  return typeof v === 'string' ? v : v.toString('utf8');
}

function harvestExecOutput(err: unknown): string {
  const e = err as { stdout?: string | Buffer; stderr?: string | Buffer };
  return `${bufferToString(e.stdout)}\n${bufferToString(e.stderr)}`.trim();
}

/**
 * Default spawn-based help + identity resolvers for a CLI binary name
 * (e.g. `'codex'`, `'grok'`). Tests inject their own fns instead.
 */
export function createCliHelpRunner(binaryName: string): {
  runHelp: RunHelpFn;
  resolveIdentity: ResolveIdentityFn;
} {
  return {
    runHelp: (): string => {
      const cmd = resolveCliCommand(binaryName);
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
    },
    resolveIdentity: (): string => {
      let cmd: string;
      try {
        cmd = resolveCliCommand(binaryName);
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
    },
  };
}

export interface CliHelpValueSourceOptions {
  runHelp: RunHelpFn;
  resolveIdentity: ResolveIdentityFn;
  /** Static fallback when CLI missing, parse empty, or probe throws. */
  fallback: readonly string[];
  /** Parse help text into value ids; return [] if no block / fail. */
  parseHelp: (helpText: string) => string[];
  /** Optional post-filter applied to both parsed and fallback paths (e.g. schema allowlist). */
  filter?: (modes: readonly string[]) => string[];
}

interface ValuesCache {
  identity: string;
  values: string[];
}

/**
 * Identity-cached CLI help value catalog. Never throws from `values()`.
 * Re-checks identity on every call; re-runs help only when identity changes.
 */
export class CliHelpValueSource {
  private readonly runHelp: RunHelpFn;
  private readonly resolveIdentity: ResolveIdentityFn;
  private readonly fallback: readonly string[];
  private readonly parseHelp: (helpText: string) => string[];
  private readonly filter: ((modes: readonly string[]) => string[]) | undefined;
  private cache: ValuesCache | null = null;

  constructor(options: CliHelpValueSourceOptions) {
    this.runHelp = options.runHelp;
    this.resolveIdentity = options.resolveIdentity;
    this.fallback = options.fallback;
    this.parseHelp = options.parseHelp;
    this.filter = options.filter;
  }

  /** Catalog values (parsed or fallback). Never throws. */
  values(): string[] {
    const identity = this.safeIdentity();
    if (this.cache && this.cache.identity === identity) {
      return this.cache.values;
    }
    const values = this.probe(identity);
    this.cache = { identity, values };
    return values;
  }

  private applyFilter(modes: readonly string[]): string[] {
    return this.filter ? this.filter(modes) : [...modes];
  }

  private safeIdentity(): string {
    try {
      return this.resolveIdentity() ?? CLI_MISSING_IDENTITY;
    } catch {
      return CLI_MISSING_IDENTITY;
    }
  }

  private probe(identity: string): string[] {
    // CLI not installed yet — fallback. Next call re-checks identity so a later install
    // (identity becomes path@version) triggers a real help probe.
    if (identity === CLI_MISSING_IDENTITY) {
      return this.applyFilter(this.fallback);
    }
    try {
      const parsed = this.applyFilter(this.parseHelp(this.runHelp()));
      return parsed.length > 0 ? parsed : this.applyFilter(this.fallback);
    } catch {
      return this.applyFilter(this.fallback);
    }
  }
}
