import * as os from 'node:os';
import * as path from 'node:path';
import * as fs from 'node:fs';

// Safe, regex-only scanner for shell dotfiles. It NEVER sources or executes the
// file; it scans the entire file content for a known allow-list of Anthropic/SDK
// env vars and extracts them. Both `export KEY=...` and bare `KEY=...` forms are
// accepted, as are values inside an alias definition.
//
// Unknown keys are ignored, values are never logged, and the returned `source` is
// just the filename (e.g. '.zshrc') so the operator can see where the effective
// value came from.

export interface ResolveCustomEnvOptions {
  // Override the home directory used to locate dotfiles (for tests).
  homeDir?: string;
  // Inject file contents by basename, e.g. { '.zshrc': 'export ANTHROPIC_MODEL=...' }.
  // Files not present here are read from disk normally.
  files?: Record<string, string>;
}

export interface CustomEnvResult {
  env: Record<string, string>;
  hasDangerousFlag: boolean;
  source: string | undefined;
}

// Dotfiles scanned. Later files override earlier files; within a file, the last
// occurrence of a key wins.
const DEFAULT_FILES = ['.zshrc', '.zprofile', '.bashrc', '.bash_profile', '.bash_login', '.profile'];

// Allow-listed env vars only. Anything else in the file is ignored.
const ALLOWED_KEYS = new Set([
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_MODEL',
  'ANTHROPIC_SMALL_FAST_MODEL',
  'API_TIMEOUT_MS',
]);

const DANGEROUS_FLAG = '--dangerously-skip-permissions';

export function resolveCustomEnv(opts: ResolveCustomEnvOptions = {}): CustomEnvResult {
  const homeDir = opts.homeDir ?? os.homedir();
  const injectedFiles = opts.files ?? {};

  let env: Record<string, string> = {};
  let source: string | undefined;
  let hasDangerousFlag = false;

  for (const file of DEFAULT_FILES) {
    let content: string | undefined;
    if (Object.prototype.hasOwnProperty.call(injectedFiles, file)) {
      content = injectedFiles[file];
    } else {
      try {
        content = fs.readFileSync(path.join(homeDir, file), 'utf-8');
      } catch {
        continue;
      }
    }
    if (content === undefined || content.length === 0) continue;

    if (content.includes(DANGEROUS_FLAG)) {
      hasDangerousFlag = true;
    }

    const extracted = extractEnv(content);
    if (extracted.sourceKeys.length > 0) {
      // Later files override earlier files; extractEnv already keeps the last
      // occurrence within the same file.
      env = { ...env, ...extracted.env };
      source = file;
    }
  }

  return { env, source, hasDangerousFlag };
}

// Extract ALLOWED_KEYS env assignments from the full file content. Supports:
//   export ANTHROPIC_MODEL="kimi-k2.7-code"
//   ANTHROPIC_BASE_URL='https://...'
//   API_TIMEOUT_MS=600000
//   alias kimi='ANTHROPIC_MODEL="kimi" claude'
// Within one file, the last assignment for a key wins.
function extractEnv(content: string): { env: Record<string, string>; sourceKeys: string[] } {
  const env: Record<string, string> = {};
  const sourceKeys: string[] = [];

  const keysPattern = [...ALLOWED_KEYS].map(escapeRegex).join('|');
  const pattern = new RegExp(
    `(?:^|\\s|;|')(?:export\\s+)?\\b(${keysPattern})\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s;]*))`,
    'g',
  );

  let match: RegExpExecArray | null;
  while ((match = pattern.exec(content)) !== null) {
    const key = match[1];
    const rawValue = match[2] ?? match[3] ?? match[4] ?? '';
    if (ALLOWED_KEYS.has(key)) {
      env[key] = rawValue;
      if (!sourceKeys.includes(key)) sourceKeys.push(key);
    }
  }

  return { env, sourceKeys };
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
