import * as fs from 'node:fs';
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
