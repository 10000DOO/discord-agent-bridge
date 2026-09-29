import { execFile } from 'node:child_process';
import * as fs from 'node:fs';
import { createRequire } from 'node:module';
import * as os from 'node:os';
import * as path from 'node:path';

// Resolve a bare CLI name (e.g. `grok`) to an absolute path when possible.
// Used before spawn under launchd/systemd, where PATH is minimal and user-local
// bins (Homebrew, ~/.grok/bin, cargo) are absent. Never hardcodes a username
// or machine-specific absolute home path — only $HOME / os.homedir() / PATH /
// platform well-known dirs.

export interface ResolveCliOptions {
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  platform?: NodeJS.Platform;
  // When injected, used as the sole candidate check (tests). The default checks
  // isFile + execute bit (non-win32) via statSync.
  pathExists?: (p: string) => boolean;
}

export function wellKnownUserBinDirs(opts: {
  homeDir: string;
  platform: NodeJS.Platform;
  env?: NodeJS.ProcessEnv;
}): string[] {
  const home = opts.homeDir;
  const common = [
    path.join(home, '.local', 'bin'),
    path.join(home, '.grok', 'bin'),
    path.join(home, '.dab', 'bin'),
    path.join(home, '.cargo', 'bin'),
  ];
  if (opts.platform === 'darwin') {
    return [...common, '/opt/homebrew/bin', '/usr/local/bin'];
  }
  if (opts.platform === 'linux') {
    return [...common, '/usr/local/bin', '/home/linuxbrew/.linuxbrew/bin'];
  }
  if (opts.platform === 'win32') {
    const dirs = [...common];
    const localAppData = opts.env?.LOCALAPPDATA ?? process.env.LOCALAPPDATA;
    if (localAppData && localAppData.length > 0) {
      dirs.push(path.join(localAppData, 'Programs'));
    }
    return dirs;
  }
  return common;
}

export function augmentPath(
  pathEnv: string | undefined,
  extraDirs: string[],
  delimiter: string = path.delimiter,
): string {
  const existing = (pathEnv ?? '')
    .split(delimiter)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  const seen = new Set(existing);
  const prepend: string[] = [];
  for (const dir of extraDirs) {
    if (!dir || seen.has(dir)) continue;
    seen.add(dir);
    prepend.push(dir);
  }
  return [...prepend, ...existing].join(delimiter);
}

// Default candidate check: regular file (stat follows symlinks → symlink-to-file
// counts) and, on non-Windows, any execute bit (USR/GRP/OTH).
function isRunnableFile(filePath: string, platform: NodeJS.Platform): boolean {
  try {
    const st = fs.statSync(filePath);
    if (!st.isFile()) return false;
    if (platform === 'win32') return true;
    return (st.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

function candidateNames(command: string, platform: NodeJS.Platform): string[] {
  if (platform !== 'win32') return [command];
  const lower = command.toLowerCase();
  if (lower.endsWith('.exe') || lower.endsWith('.cmd') || lower.endsWith('.bat')) {
    return [command];
  }
  // Prefer the bare name first (may already be a shebang script / no extension),
  // then Windows executable extensions.
  return [command, `${command}.exe`, `${command}.cmd`];
}

function hasPathSeparator(command: string): boolean {
  return command.includes('/') || command.includes('\\') || path.isAbsolute(command);
}

export function resolveCliCommand(command: string, opts: ResolveCliOptions = {}): string {
  if (!command || command.trim().length === 0) return command;

  const env = opts.env ?? process.env;
  const homeDir = opts.homeDir ?? env.HOME ?? env.USERPROFILE ?? os.homedir();
  const platform = opts.platform ?? process.platform;
  const pathExists = opts.pathExists ?? ((p: string) => isRunnableFile(p, platform));
  const delim = path.delimiter;

  // 1. Absolute or relative path with separators → leave unchanged (spawn fails if bad).
  if (hasPathSeparator(command)) {
    return command;
  }

  const names = candidateNames(command, platform);

  // 2. Search PATH entries.
  const pathEnv = env.PATH ?? env.Path ?? '';
  const pathDirs = pathEnv
    .split(delim)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  for (const dir of pathDirs) {
    for (const name of names) {
      const candidate = path.join(dir, name);
      if (pathExists(candidate)) return candidate;
    }
  }

  // 3. Well-known user / system bin dirs (portable, $HOME-relative).
  for (const dir of wellKnownUserBinDirs({ homeDir, platform, env })) {
    for (const name of names) {
      const candidate = path.join(dir, name);
      if (pathExists(candidate)) return candidate;
    }
  }

  // 4. Not found → original bare name (ENOENT path preserved).
  return command;
}

export interface ResolveClaudeOptions extends ResolveCliOptions {
  execPath?: string;
  listDir?: (dir: string) => string[];
  realpath?: (p: string) => string;
}

// Claude-only: locate an installed Claude Code CLI in a form the Agent SDK can run as
// Options.pathToClaudeCodeExecutable. The SDK spawns that path directly with no shell,
// except a `.js` path, which it runs through `node`. undefined → the SDK's bundled CLI.
// Search order: PATH, the running node's bin dir, well-known bins, legacy
// ~/.claude/local, nvm (NVM_BIN, then newest version), volta, fnm, asdf, %APPDATA%\npm.
export function resolveClaudeExecutable(opts: ResolveClaudeOptions = {}): string | undefined {
  const env = opts.env ?? process.env;
  const homeDir = opts.homeDir ?? env.HOME ?? env.USERPROFILE ?? os.homedir();
  const platform = opts.platform ?? process.platform;
  const pathExists = opts.pathExists ?? ((p: string) => isRunnableFile(p, platform));
  const listDir = opts.listDir ?? readDirOrEmpty;
  const realpath = opts.realpath ?? realpathOrSelf;
  const pathDirs = (env.PATH ?? env.Path ?? '').split(path.delimiter).map((p) => p.trim()).filter((p) => p.length > 0);
  const nvmNodeDir = path.join(env.NVM_DIR || path.join(homeDir, '.nvm'), 'versions', 'node');
  const nvmVersionBins = listDir(nvmNodeDir).filter((v) => v.startsWith('v')).sort((a, b) => b.localeCompare(a, undefined, { numeric: true })).map((v) => path.join(nvmNodeDir, v, 'bin'));
  const dirs = [
    ...pathDirs,
    path.dirname(opts.execPath ?? process.execPath),
    ...wellKnownUserBinDirs({ homeDir, platform, env }),
    path.join(homeDir, '.claude', 'local', 'node_modules', '.bin'),
    ...(env.NVM_BIN ? [env.NVM_BIN] : []),
    ...nvmVersionBins,
    path.join(homeDir, '.volta', 'bin'),
    path.join(env.FNM_DIR || path.join(homeDir, '.local', 'share', 'fnm'), 'aliases', 'default', 'bin'),
    path.join(env.ASDF_DATA_DIR || path.join(homeDir, '.asdf'), 'shims'),
    ...(platform === 'win32' && env.APPDATA ? [path.join(env.APPDATA, 'npm')] : []),
  ];
  const names = platform === 'win32' ? ['claude.exe', 'claude.cmd'] : ['claude'];
  for (const dir of dirs) {
    for (const name of names) {
      const candidate = path.join(dir, name);
      if (!pathExists(candidate)) continue;
      const runnable = toSdkRunnable(candidate, pathExists, realpath);
      if (runnable !== undefined) return runnable;
    }
  }
  return undefined;
}

function toSdkRunnable(candidate: string, pathExists: (p: string) => boolean, realpath: (p: string) => string): string | undefined {
  // Windows npm shim: Node refuses to spawn a .cmd without a shell (EINVAL), so hand
  // the SDK the package entry the shim wraps (native claude.exe, or cli.js on old CLIs).
  if (candidate.toLowerCase().endsWith('.cmd')) {
    const pkg = path.join(path.dirname(candidate), 'node_modules', '@anthropic-ai', 'claude-code');
    return [path.join(pkg, 'bin', 'claude.exe'), path.join(pkg, 'cli.js')].find((p) => pathExists(p));
  }
  // An npm bin symlink to cli.js (old CLIs): pass the .js so the SDK runs it through
  // node. Any other link stays as found — a volta shim dispatches on its argv[0] name.
  const real = realpath(candidate);
  return real.endsWith('.js') ? real : candidate;
}

function readDirOrEmpty(dir: string): string[] {
  try {
    return fs.readdirSync(dir);
  } catch {
    return [];
  }
}

function realpathOrSelf(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return p;
  }
}

const CLI_VERSION_TIMEOUT_MS = 5_000;
// Keyed by realpath + mtime, so a CLI auto-update (new realpath) or an in-place reinstall
// (new mtime) is re-checked. The stored promise also dedupes concurrent checks.
const cliVersionCache = new Map<string, Promise<string>>();

// The installed Claude Code CLI to hand the SDK, or undefined → the SDK's bundled CLI.
// An installed CLI older than the one the SDK was built against (its package.json
// `claudeCodeVersion`) may not know flags the SDK passes (e.g. --effort) and would exit
// on "unknown option", so it is skipped; so is one whose version cannot be read.
export async function resolveUsableClaudeExecutable(): Promise<string | undefined> {
  const exe = resolveClaudeExecutable();
  if (exe === undefined) return undefined;
  return cliVersionAtLeast(await cliVersionOutput(exe), bundledClaudeCliVersion()) ? exe : undefined;
}

// True when `output` (e.g. "2.1.284 (Claude Code)") is a numeric X.Y.Z at least `minimum`.
// Anything unparsable on either side is false. A prerelease suffix is ignored.
export function cliVersionAtLeast(output: string, minimum: string | undefined): boolean {
  const have = parseXyz(output);
  const need = parseXyz(minimum ?? '');
  if (have === undefined || need === undefined) return false;
  for (let i = 0; i < 3; i++) {
    if (have[i] !== need[i]) return have[i] > need[i];
  }
  return true;
}

function parseXyz(text: string): number[] | undefined {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(text.trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : undefined;
}

function bundledClaudeCliVersion(): string | undefined {
  try {
    const sdkDir = path.dirname(createRequire(import.meta.url).resolve('@anthropic-ai/claude-agent-sdk'));
    const version: unknown = JSON.parse(fs.readFileSync(path.join(sdkDir, 'package.json'), 'utf8')).claudeCodeVersion;
    return typeof version === 'string' ? version : undefined;
  } catch {
    return undefined;
  }
}

// `<exe> --version` without a shell; a `.js` entry runs through this node. Resolves ''
// on any failure (the caller then keeps the bundled CLI); a hang is SIGKILLed at the timeout.
function cliVersionOutput(exe: string): Promise<string> {
  const real = realpathOrSelf(exe);
  let key = real;
  try {
    key = `${real}:${fs.statSync(real).mtimeMs}`;
  } catch {
    // Unstat-able: fall back to the path alone; the spawn below reports the failure.
  }
  let pending = cliVersionCache.get(key);
  if (pending === undefined) {
    const [cmd, args] = real.endsWith('.js') ? [process.execPath, [real, '--version']] : [exe, ['--version']];
    pending = new Promise<string>((resolve) => {
      try {
        execFile(cmd, args, { encoding: 'utf8', timeout: CLI_VERSION_TIMEOUT_MS, killSignal: 'SIGKILL', windowsHide: true }, (err, stdout) => resolve(err ? '' : stdout));
      } catch {
        resolve('');
      }
    });
    cliVersionCache.set(key, pending);
    // Only a real version output stays cached: a failure or timeout (e.g. a slow first
    // run after an update) is dropped so the next session re-checks. Runs after set(),
    // so a synchronous spawn throw is dropped too; the promise itself never rejects.
    void pending.then((out) => {
      if (out === '') cliVersionCache.delete(key);
    });
  }
  return pending;
}
