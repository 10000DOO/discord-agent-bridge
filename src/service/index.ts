import { execFile } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  type CommandResult,
  type CommandRunner,
  type ResolvedServiceDeps,
  type ServiceDeps,
  type ServiceFs,
  type ServiceInstaller,
} from './types.js';
import { createLaunchdInstaller } from './launchd.js';
import { createSystemdInstaller } from './systemd.js';
import { createSchtasksInstaller } from './schtasks.js';

// The `service` subcommand: register discord-agent-bridge to auto-start on this OS
// (§4). This module ONLY manages the OS service — it never boots the bot itself.
// cli.ts dispatches here before any startBot() path.

// ---- Real implementations (defaults) ----------------------------------------

// execFile (no shell): resolves with the captured output + exit code even on a
// non-zero exit (that code is data the installers inspect). Rejects only when the
// binary cannot be spawned (ENOENT/EACCES) — a genuine "tool missing" failure.
const realRun: CommandRunner = (command, args) =>
  new Promise<CommandResult>((resolve, reject) => {
    execFile(command, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
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

const realFs: ServiceFs = {
  writeFile(filePath, content, mode) {
    fs.writeFileSync(filePath, content, mode !== undefined ? { encoding: 'utf8', mode } : { encoding: 'utf8' });
  },
  chmod(filePath, mode) {
    fs.chmodSync(filePath, mode);
  },
  mkdirp(dir) {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  },
  exists(filePath) {
    return fs.existsSync(filePath);
  },
  remove(filePath) {
    if (fs.existsSync(filePath)) fs.rmSync(filePath, { force: true });
  },
};

// dist/cli.js, resolved relative to this module (dist/service/index.js → ../cli.js).
// The Windows scheduled task runs `node <this>`; the file exists in a real install.
function defaultCliEntry(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.join(here, '..', 'cli.js');
}

function resolveDeps(deps: ServiceDeps): ResolvedServiceDeps {
  const home = (deps.homedir ?? os.homedir)();
  return {
    run: deps.run ?? realRun,
    fs: deps.fs ?? realFs,
    home,
    username: (deps.username ?? (() => os.userInfo().username))(),
    platform: deps.platform ?? process.platform,
    log: deps.log ?? ((m: string) => console.log(m)),
    fail: deps.fail ?? (() => {
      process.exitCode = 1;
    }),
    nodePath: (deps.nodePath ?? (() => process.execPath))(),
    cliEntry: (deps.cliEntry ?? defaultCliEntry)(),
    nodeDir: (deps.nodeDir ?? (() => path.dirname(process.execPath)))(),
    baseDir: path.join(home, '.discord-agent-bridge'),
  };
}

function selectInstaller(d: ResolvedServiceDeps): ServiceInstaller | null {
  switch (d.platform) {
    case 'darwin':
      return createLaunchdInstaller(d);
    case 'linux':
      return createSystemdInstaller(d);
    case 'win32':
      return createSchtasksInstaller(d);
    default:
      return null;
  }
}

function printUsage(d: ResolvedServiceDeps, unknown?: string): void {
  if (unknown) d.log(`알 수 없는 명령입니다: service ${unknown}`);
  d.log('사용법: discord-agent-bridge service <install|uninstall|status|restart>');
  d.log('  install    재부팅/로그인 시 자동 실행을 등록하고 즉시 시작합니다.');
  d.log('  uninstall  서비스를 중지하고 자동 실행 등록을 해제합니다.');
  d.log('  status     등록/실행 상태를 출력합니다.');
  d.log('  restart    서비스를 재시작합니다.');
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

// Run one installer operation, translating both an unspawnable command (thrown) and a
// clean "it ran but failed" (returned false) into the friendly non-zero exit.
async function guard(d: ResolvedServiceDeps, op: () => Promise<boolean>): Promise<void> {
  try {
    if (!(await op())) d.fail();
  } catch (err) {
    d.log(`명령을 실행하지 못했습니다: ${errorMessage(err)}`);
    d.log('수동 방법은 README 를 참고하세요.');
    d.fail();
  }
}

// Parse `service <sub>` and dispatch to the platform installer. Never boots the bot.
export async function runServiceCommand(argv: string[], deps: ServiceDeps = {}): Promise<void> {
  const d = resolveDeps(deps);
  const installer = selectInstaller(d);
  if (!installer) {
    d.log(`이 플랫폼(${d.platform})은 서비스 자동 등록을 지원하지 않습니다.`);
    d.log('수동 방법은 README 를 참고하세요.');
    d.fail();
    return;
  }

  const sub = argv[0];
  switch (sub) {
    case 'install':
      await guard(d, () => installer.install());
      return;
    case 'uninstall':
      await guard(d, () => installer.uninstall());
      return;
    case 'status':
      await guard(d, () => installer.status());
      return;
    case 'restart':
      await guard(d, () => installer.restart());
      return;
    default:
      printUsage(d, sub);
      d.fail();
      return;
  }
}
