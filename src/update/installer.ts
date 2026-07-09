import { execFile } from 'node:child_process';
import type { CommandResult, CommandRunner } from '../service/types.js';
import { pidFilePath, type RestartStrategy } from './environment.js';

// The install + restart side effects for the auto-updater (§7). Every OS touchpoint —
// running npm, spawning the successor, writing the PID file — is injectable so the
// orchestrator (autoUpdater.ts) is unit-testable without a real npm, spawn, or disk.

// The outcome of `npm i -g`. `ok` is code === 0; stderr is surfaced in the failure
// notice. code is null when the command could not be spawned at all (npm missing).
export interface InstallResult {
  ok: boolean;
  code: number | null;
  stderr: string;
}

// A real CommandRunner (execFile, no shell — mirrors service/index.ts realRun). Rejects
// only when the binary cannot be spawned; a non-zero exit is captured as data. installLatest
// converts a spawn rejection into an InstallResult, so callers never see a throw.
export const realCommandRunner: CommandRunner = (command, args) =>
  new Promise<CommandResult>((resolve, reject) => {
    execFile(command, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      const e = err as (NodeJS.ErrnoException & { code?: number | string }) | null;
      if (e && typeof e.code === 'string') {
        reject(e);
        return;
      }
      resolve({
        code: e && typeof e.code === 'number' ? e.code : 0,
        stdout: String(stdout ?? ''),
        stderr: String(stderr ?? ''),
      });
    });
  });

// Install the latest published version globally. win32 uses `npm.cmd` (the shim on
// PATH); other platforms use `npm`. Never throws: a spawn failure (npm not found) is
// reported as { ok:false, code:null }.
export async function installLatest(run: CommandRunner, platform: NodeJS.Platform): Promise<InstallResult> {
  const npm = platform === 'win32' ? 'npm.cmd' : 'npm';
  try {
    const res = await run(npm, ['i', '-g', 'discord-agent-bridge@latest']);
    return { ok: res.code === 0, code: res.code, stderr: res.stderr };
  } catch (err) {
    return { ok: false, code: null, stderr: err instanceof Error ? err.message : String(err) };
  }
}

// The narrow child_process.spawn surface performRestart needs (detached, no I/O). The
// return value only needs unref() so the parent can exit without waiting on the child.
export type SpawnFn = (
  command: string,
  args: readonly string[],
  options: { detached: boolean; stdio: 'ignore'; env: NodeJS.ProcessEnv },
) => { unref: () => void };

export interface RestartDeps {
  strategy: RestartStrategy;
  nodePath: string;
  cliEntry: string;
  spawn: SpawnFn;
  exit: (code: number) => never;
  env: NodeJS.ProcessEnv;
}

// Restart the process for the freshly installed version (§3.1). Method A (supervised):
// exit(0) only — the service manager relaunches the new code. Method B (respawn): spawn
// a detached, I/O-less successor running `node <cliEntry>` (the global package was
// replaced in place, so the same entry path is now the new version), then exit(0).
export function performRestart(d: RestartDeps): void {
  if (d.strategy === 'respawn') {
    const child = d.spawn(d.nodePath, [d.cliEntry], { detached: true, stdio: 'ignore', env: d.env });
    child.unref();
  }
  d.exit(0);
}

// The slice of fs the PID-file helpers touch (injectable for tests). Sync to match the
// rest of the service/config fs usage.
export interface MinimalFs {
  writeFileSync: (filePath: string, data: string) => void;
  existsSync: (filePath: string) => boolean;
  rmSync: (filePath: string, options: { force: true }) => void;
}

// Record this process's PID in the base dir (§3.5) so an operator can terminate a
// detached-respawned instance in the foreground case. Best-effort by the caller.
export function writePidFile(baseDir: string, pid: number, fs: MinimalFs): void {
  fs.writeFileSync(pidFilePath(baseDir), String(pid));
}

// Remove the PID file on shutdown. No-op when absent (never throws for a missing file).
export function removePidFile(baseDir: string, fs: MinimalFs): void {
  const target = pidFilePath(baseDir);
  if (fs.existsSync(target)) fs.rmSync(target, { force: true });
}
