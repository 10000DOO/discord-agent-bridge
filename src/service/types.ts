// Shared types + constants for the `service` subcommand (auto-start registration).
// Every OS touchpoint — running launchctl/systemctl/schtasks, writing files, reading
// the home dir / node paths — is injectable so the installers are unit-testable with
// no real service manager and no real filesystem writes (mirrors the DI style of
// setup/wizard.ts and modes/codex/runner.ts).

// launchd Label / plist basename (reverse-DNS is the launchd convention).
export const SERVICE_LABEL = 'com.discord-agent-bridge';
// systemd unit name and Windows Scheduled-Task name.
export const SERVICE_NAME = 'discord-agent-bridge';

// The captured result of one OS command. `code` is the process exit code (null if it
// was killed by a signal). A non-zero code is DATA the installer inspects — the runner
// does not reject on it; it only rejects when the binary itself cannot be spawned.
export interface CommandResult {
  code: number | null;
  stdout: string;
  stderr: string;
}

// Runs an OS command WITHOUT a shell (execFile semantics — no shell injection).
export type CommandRunner = (command: string, args: readonly string[]) => Promise<CommandResult>;

// The slice of the filesystem the installers touch. Sync to match ConfigStore's fs
// usage. Injectable so tests capture writes instead of hitting disk.
export interface ServiceFs {
  writeFile(filePath: string, content: string, mode?: number): void;
  chmod(filePath: string, mode: number): void;
  mkdirp(dir: string): void;
  exists(filePath: string): boolean;
  remove(filePath: string): void;
}

// Injectable dependencies. All optional; each defaults to the real implementation so
// `runServiceCommand(argv)` is the production path and `runServiceCommand(argv, {...})`
// is the test path.
export interface ServiceDeps {
  run?: CommandRunner;
  fs?: ServiceFs;
  homedir?: () => string;
  username?: () => string;
  platform?: NodeJS.Platform;
  log?: (message: string) => void;
  // Signals a non-zero process exit for an expected failure (default sets
  // process.exitCode = 1 — the same friendly-failure convention as app.ts).
  fail?: () => void;
  // Absolute path to the node binary that launches future runs (Windows task command).
  nodePath?: () => string;
  // Absolute path to this package's CLI entry (dist/cli.js) for the Windows task.
  cliEntry?: () => string;
  // Directory holding the `node` binary at install time — the nvm-less PATH fallback
  // baked into the run.sh wrapper (macOS/Linux).
  nodeDir?: () => string;
}

// Fully-resolved deps handed to the platform installers (no optionals).
export interface ResolvedServiceDeps {
  run: CommandRunner;
  fs: ServiceFs;
  home: string;
  username: string;
  platform: NodeJS.Platform;
  log: (message: string) => void;
  fail: () => void;
  nodePath: string;
  cliEntry: string;
  nodeDir: string;
  // ~/.discord-agent-bridge — holds run.sh and the agent logs.
  baseDir: string;
}

// One platform's auto-start operations. Each returns whether it SUCCEEDED so the
// dispatcher can set the process exit code once, in a single place. `status` returns
// true whenever it managed to report (a query is informational, not a failure).
export interface ServiceInstaller {
  install(): Promise<boolean>;
  uninstall(): Promise<boolean>;
  status(): Promise<boolean>;
  restart(): Promise<boolean>;
}
