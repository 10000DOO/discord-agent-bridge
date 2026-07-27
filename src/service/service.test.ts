import { describe, it, expect } from 'vitest';
import { execFile as execFileCallback } from 'node:child_process';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import * as path from 'node:path';
import { promisify } from 'node:util';
import { runServiceCommand } from './index.js';
import { buildRunScript } from './runScript.js';
import {
  SERVICE_LABEL,
  SERVICE_NAME,
  type CommandResult,
  type ResolvedServiceDeps,
  type ServiceDeps,
  type ServiceFs,
} from './types.js';

const execFile = promisify(execFileCallback);

// An in-memory fs + a recording command runner so a test asserts EXACTLY which files
// get which content and which OS commands are invoked — no real launchctl/systemctl/
// schtasks runs and no real file is written (mirrors the wizard.test.ts DI style).

interface RunCall {
  command: string;
  args: string[];
}

function harness(overrides: Partial<ServiceDeps> = {}) {
  const files = new Map<string, { content: string; mode?: number }>();
  const removed: string[] = [];
  const runCalls: RunCall[] = [];
  const logs: string[] = [];
  let failed = false;
  // Default: every command "succeeds" (code 0). A test overrides via `results`.
  const results = new Map<string, CommandResult>();

  const fsFake: ServiceFs = {
    writeFile(filePath, content, mode) {
      files.set(filePath, { content, mode });
    },
    chmod(filePath, mode) {
      const cur = files.get(filePath);
      if (cur) cur.mode = mode;
    },
    mkdirp() {
      /* no-op in memory */
    },
    exists(filePath) {
      return files.has(filePath);
    },
    remove(filePath) {
      files.delete(filePath);
      removed.push(filePath);
    },
  };

  const deps: ServiceDeps = {
    fs: fsFake,
    run: async (command, args) => {
      runCalls.push({ command, args: [...args] });
      return results.get(`${command} ${args.join(' ')}`) ?? results.get(command) ?? { code: 0, stdout: '', stderr: '' };
    },
    homedir: () => '/home/tester',
    username: () => 'tester',
    log: (m) => logs.push(m),
    fail: () => {
      failed = true;
    },
    nodePath: () => '/opt/node/bin/node',
    cliEntry: () => '/opt/dab/dist/cli.js',
    nodeDir: () => '/opt/node/bin',
    ...overrides,
  };

  return {
    deps,
    files,
    removed,
    runCalls,
    logs,
    results,
    get failed() {
      return failed;
    },
    ran: (command: string) => runCalls.filter((c) => c.command === command),
    logText: () => logs.join('\n'),
  };
}

const BASE = '/home/tester/.discord-agent-bridge';
const RUN_SH = `${BASE}/run.sh`;

async function writeExecutable(filePath: string, content: string): Promise<void> {
  await writeFile(filePath, content, 'utf8');
  await chmod(filePath, 0o755);
}

describe('runServiceCommand — dispatch', () => {
  it('prints usage and fails on an unknown subcommand', async () => {
    const h = harness({ platform: 'darwin' });
    await runServiceCommand(['bogus'], h.deps);
    expect(h.logText()).toContain('알 수 없는 명령');
    expect(h.logText()).toContain('사용법');
    expect(h.failed).toBe(true);
    expect(h.runCalls).toHaveLength(0); // never touched the OS
  });

  it('prints usage and fails when no subcommand is given', async () => {
    const h = harness({ platform: 'darwin' });
    await runServiceCommand([], h.deps);
    expect(h.logText()).toContain('사용법');
    expect(h.failed).toBe(true);
  });

  it('reports an unsupported platform and fails', async () => {
    const h = harness({ platform: 'freebsd' as NodeJS.Platform });
    await runServiceCommand(['install'], h.deps);
    expect(h.logText()).toContain('지원하지 않습니다');
    expect(h.logText()).toContain('README');
    expect(h.failed).toBe(true);
    expect(h.runCalls).toHaveLength(0);
  });

  it('turns an unspawnable command (thrown) into a friendly failure', async () => {
    const h = harness({
      platform: 'darwin',
      run: async () => {
        const err = new Error('spawn launchctl ENOENT') as NodeJS.ErrnoException;
        err.code = 'ENOENT';
        throw err;
      },
    });
    await runServiceCommand(['status'], h.deps);
    expect(h.logText()).toContain('실행하지 못했습니다');
    expect(h.logText()).toContain('README');
    expect(h.failed).toBe(true);
  });
});

describe('runServiceCommand — macOS (launchd)', () => {
  const PLIST = `/home/tester/Library/LaunchAgents/${SERVICE_LABEL}.plist`;

  it('install writes an executable run.sh + plist and loads it', async () => {
    const h = harness({ platform: 'darwin' });
    await runServiceCommand(['install'], h.deps);

    // run.sh: version-independent launcher, executable.
    const script = h.files.get(RUN_SH);
    expect(script).toBeDefined();
    expect(script?.mode).toBe(0o755);
    expect(script?.content).toContain('nvm_node="$(nvm which default 2>/dev/null || true)"');
    expect(script?.content).toContain('if [ ! -x "$nvm_node" ]; then');
    expect(script?.content).toContain('nvm_node="$(nvm which node 2>/dev/null || true)"');
    expect(script?.content).toContain('export PATH="$(dirname "$nvm_node"):$PATH"');
    expect(script?.content).toContain('if [ ! -x "$nvm_node" ] && [ -x "/opt/node/bin/node" ]; then');
    expect(script?.content).toContain('export PATH="/opt/node/bin:$PATH"');
    // Portable user-local CLI bins (grok etc.) — $HOME-relative, no machine path.
    expect(script?.content).toContain('$HOME/.local/bin');
    expect(script?.content).toContain('$HOME/.grok/bin');
    expect(script?.content).toContain('/home/linuxbrew/.linuxbrew/bin');
    expect(script?.content).toContain(
      'export PATH="$HOME/.local/bin:$HOME/.grok/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:$PATH"',
    );
    // Supervisor marker (§3.2): run.sh is only generated for launchd/systemd, so this
    // marks the process as "exit relaunches me" for the auto-updater's method-A restart.
    expect(script?.content).toContain('export DAB_SUPERVISED=1');
    expect(script?.content).toContain('exec discord-agent-bridge');

    // plist: bash + run.sh, RunAtLoad/KeepAlive, HOME env, log paths.
    const plist = h.files.get(PLIST);
    expect(plist).toBeDefined();
    expect(plist?.content).toContain(`<string>${SERVICE_LABEL}</string>`);
    expect(plist?.content).toContain('<string>/bin/bash</string>');
    expect(plist?.content).toContain(`<string>${RUN_SH}</string>`);
    expect(plist?.content).toContain('<key>RunAtLoad</key>');
    expect(plist?.content).toContain('<key>KeepAlive</key>');
    expect(plist?.content).toContain('<string>/home/tester</string>'); // HOME
    expect(plist?.content).toContain(`${BASE}/agent.out.log`);
    expect(plist?.content).toContain(`${BASE}/agent.err.log`);

    // launchctl: unload (best-effort) then load -w.
    const calls = h.ran('launchctl');
    expect(calls.some((c) => c.args.join(' ') === `unload ${PLIST}`)).toBe(true);
    expect(calls.some((c) => c.args.join(' ') === `load -w ${PLIST}`)).toBe(true);
    expect(h.failed).toBe(false);
    expect(h.logText()).toContain('등록하고 시작');
  });

  it('install fails cleanly when launchctl load returns non-zero', async () => {
    const h = harness({ platform: 'darwin' });
    h.results.set(`launchctl load -w ${PLIST}`, { code: 1, stdout: '', stderr: 'Load failed' });
    await runServiceCommand(['install'], h.deps);
    expect(h.failed).toBe(true);
    expect(h.logText()).toContain('실패');
    expect(h.logText()).toContain('README');
  });

  it('uninstall unloads and removes the plist', async () => {
    const h = harness({ platform: 'darwin' });
    h.files.set(PLIST, { content: '<plist/>' }); // pretend it was installed
    await runServiceCommand(['uninstall'], h.deps);
    expect(h.ran('launchctl').some((c) => c.args.join(' ') === `unload -w ${PLIST}`)).toBe(true);
    expect(h.removed).toContain(PLIST);
    expect(h.files.has(PLIST)).toBe(false);
    expect(h.failed).toBe(false);
  });

  it('status reports running when launchctl list contains the label', async () => {
    const h = harness({ platform: 'darwin' });
    h.files.set(PLIST, { content: '<plist/>' });
    h.results.set('launchctl', { code: 0, stdout: `123\t0\t${SERVICE_LABEL}\n`, stderr: '' });
    await runServiceCommand(['status'], h.deps);
    expect(h.logText()).toContain('실행 중: 예');
    expect(h.logText()).toContain('있음');
    expect(h.failed).toBe(false);
  });

  it('status reports not running when the label is absent', async () => {
    const h = harness({ platform: 'darwin' });
    h.results.set('launchctl', { code: 0, stdout: 'PID\tStatus\tLabel\n', stderr: '' });
    await runServiceCommand(['status'], h.deps);
    expect(h.logText()).toContain('실행 중: 아니오');
    expect(h.logText()).toContain('없음');
  });

  it('restart unloads then loads', async () => {
    const h = harness({ platform: 'darwin' });
    await runServiceCommand(['restart'], h.deps);
    const calls = h.ran('launchctl');
    expect(calls.some((c) => c.args.join(' ') === `unload ${PLIST}`)).toBe(true);
    expect(calls.some((c) => c.args.join(' ') === `load -w ${PLIST}`)).toBe(true);
    expect(h.logText()).toContain('재시작');
    expect(h.failed).toBe(false);
  });
});

describe('buildRunScript', () => {
  it('prefers its install-time Node when nvm has no alias despite a system Node on PATH', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'dab-run-script-'));
    const home = path.join(root, 'home');
    const installBin = path.join(root, 'install-bin');
    const systemBin = path.join(root, 'system-bin');
    const runScript = path.join(root, 'run.sh');
    try {
      await mkdir(path.join(home, '.nvm'), { recursive: true });
      await mkdir(installBin);
      await mkdir(systemBin);
      await writeFile(
        path.join(home, '.nvm', 'nvm.sh'),
        'nvm() { [ "$1" = "which" ] && return 1; }\n',
        'utf8',
      );
      await writeExecutable(path.join(installBin, 'node'), '#!/bin/bash\necho install-node\n');
      await writeExecutable(path.join(systemBin, 'node'), '#!/bin/bash\necho system-node\n');
      await writeExecutable(path.join(installBin, 'discord-agent-bridge'), '#!/bin/bash\nnode\n');
      await writeExecutable(path.join(systemBin, 'discord-agent-bridge'), '#!/bin/bash\nnode\n');
      await writeExecutable(
        runScript,
        buildRunScript({ nodeDir: installBin } as ResolvedServiceDeps),
      );

      const { stdout } = await execFile('/bin/bash', [runScript], {
        env: { ...process.env, HOME: home, PATH: `${systemBin}:${process.env.PATH ?? ''}` },
      });
      expect(stdout.trim()).toBe('install-node');
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it('Swift installer renders a safe launcher with nvm and inherited-Node fallbacks', async () => {
    if (process.platform !== 'darwin') return;

    const root = await mkdtemp(path.join(tmpdir(), 'dab-swift-run-script-'));
    const home = path.join(root, 'home');
    const injectedMarker = path.join(root, 'must-not-exist');
    const installBin = path.join(root, 'install-$(touch "$DAB_TEST_MARKER")');
    const nvmBin = path.join(root, 'nvm-bin');
    const systemBin = path.join(root, 'system-bin');
    const helperBin = path.join(root, 'helper-bin');
    const binDir = path.join(home, '.dab', 'bin');
    let generatedDir: string | undefined;
    try {
      await mkdir(path.join(home, '.nvm'), { recursive: true });
      await Promise.all([mkdir(installBin), mkdir(nvmBin), mkdir(systemBin), mkdir(helperBin), mkdir(binDir, { recursive: true })]);
      await writeExecutable(path.join(installBin, 'node'), '#!/bin/bash\necho install-node\n');
      await writeExecutable(path.join(nvmBin, 'node'), '#!/bin/bash\necho nvm-node\n');
      await writeExecutable(path.join(systemBin, 'node'), '#!/bin/bash\necho system-node\n');
      await writeExecutable(path.join(binDir, 'dab'), '#!/bin/bash\nnode\n');
      // Preserve the dry-run artifact long enough to execute the actual rendered launcher.
      await writeExecutable(path.join(helperBin, 'rm'), '#!/bin/bash\nexit 0\n');
      const install = await execFile('/bin/bash', ['swift/scripts/install.sh', '--dry-run'], {
        env: {
          ...process.env,
          HOME: home,
          PATH: `${helperBin}:${installBin}:${systemBin}:${process.env.PATH ?? ''}`,
        },
      });
      const runScriptMatch = /^\s{2}generated \(temp\) run\.sh: (.+)$/m.exec(install.stdout);
      if (!runScriptMatch) throw new Error('Swift installer did not report generated run.sh.');
      const runScript = runScriptMatch[1];
      generatedDir = path.dirname(runScript);
      expect(await readFile(runScript, 'utf8')).toContain('install_node_dir=');

      await writeFile(
        path.join(home, '.nvm', 'nvm.sh'),
        'nvm() {\n  [ "$1" = "which" ] || return 1\n  [ "$2" = "node" ] || return 1\n  printf "%s\\n" "$NVM_NODE_PATH"\n}\n',
        'utf8',
      );
      let result = await execFile('/bin/bash', [runScript], {
        env: {
          ...process.env,
          HOME: home,
          DAB_TEST_MARKER: injectedMarker,
          PATH: `${systemBin}:${process.env.PATH ?? ''}`,
          NVM_NODE_PATH: path.join(nvmBin, 'node'),
        },
      });
      expect(result.stdout.trim()).toBe('nvm-node');

      await writeFile(path.join(home, '.nvm', 'nvm.sh'), 'nvm() { return 1; }\n', 'utf8');
      result = await execFile('/bin/bash', [runScript], {
        env: {
          ...process.env,
          HOME: home,
          DAB_TEST_MARKER: injectedMarker,
          PATH: `${systemBin}:${process.env.PATH ?? ''}`,
        },
      });
      expect(result.stdout.trim()).toBe('install-node');

      // If the captured install-time Node is later removed, preserve and use the inherited
      // system Node rather than emitting a broken PATH entry.
      await rm(path.join(installBin, 'node'));
      result = await execFile('/bin/bash', [runScript], {
        env: {
          ...process.env,
          HOME: home,
          DAB_TEST_MARKER: injectedMarker,
          PATH: `${systemBin}:${process.env.PATH ?? ''}`,
        },
      });
      expect(result.stdout.trim()).toBe('system-node');
      await expect(readFile(injectedMarker, 'utf8')).rejects.toThrow();
    } finally {
      if (generatedDir) await rm(generatedDir, { recursive: true, force: true });
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe('runServiceCommand — Linux (systemd --user)', () => {
  const UNIT = `/home/tester/.config/systemd/user/${SERVICE_NAME}.service`;

  it('install writes run.sh + unit and enables the service', async () => {
    const h = harness({ platform: 'linux' });
    await runServiceCommand(['install'], h.deps);

    expect(h.files.get(RUN_SH)?.mode).toBe(0o755);

    const unit = h.files.get(UNIT);
    expect(unit).toBeDefined();
    expect(unit?.content).toContain(`ExecStart=/bin/bash ${RUN_SH}`);
    expect(unit?.content).toContain('Restart=always');
    expect(unit?.content).toContain('WantedBy=default.target');

    const sc = h.ran('systemctl');
    expect(sc.some((c) => c.args.join(' ') === '--user daemon-reload')).toBe(true);
    expect(sc.some((c) => c.args.join(' ') === `--user enable --now ${SERVICE_NAME}`)).toBe(true);
    // Linger attempted for the resolved username.
    expect(h.ran('loginctl').some((c) => c.args.join(' ') === 'enable-linger tester')).toBe(true);
    expect(h.failed).toBe(false);
    expect(h.logText()).toContain('등록하고 시작');
  });

  it('install still succeeds but warns when enable-linger fails', async () => {
    const h = harness({ platform: 'linux' });
    h.results.set('loginctl enable-linger tester', { code: 1, stdout: '', stderr: 'denied' });
    await runServiceCommand(['install'], h.deps);
    expect(h.failed).toBe(false); // linger failure is non-fatal
    expect(h.logText()).toContain('enable-linger');
  });

  it('install fails when enable --now returns non-zero', async () => {
    const h = harness({ platform: 'linux' });
    h.results.set(`systemctl --user enable --now ${SERVICE_NAME}`, { code: 1, stdout: '', stderr: 'boom' });
    await runServiceCommand(['install'], h.deps);
    expect(h.failed).toBe(true);
    expect(h.logText()).toContain('README');
  });

  it('uninstall disables the unit and removes the file', async () => {
    const h = harness({ platform: 'linux' });
    h.files.set(UNIT, { content: '[Unit]' });
    await runServiceCommand(['uninstall'], h.deps);
    expect(h.ran('systemctl').some((c) => c.args.join(' ') === `--user disable --now ${SERVICE_NAME}`)).toBe(true);
    expect(h.removed).toContain(UNIT);
    expect(h.failed).toBe(false);
  });

  it('status prints systemctl output and stays a success even if the unit is inactive', async () => {
    const h = harness({ platform: 'linux' });
    h.results.set(`systemctl --user status ${SERVICE_NAME}`, {
      code: 3, // inactive → non-zero, but informational
      stdout: 'Active: inactive (dead)',
      stderr: '',
    });
    await runServiceCommand(['status'], h.deps);
    expect(h.logText()).toContain('Active: inactive');
    expect(h.failed).toBe(false);
  });

  it('restart runs systemctl restart', async () => {
    const h = harness({ platform: 'linux' });
    await runServiceCommand(['restart'], h.deps);
    expect(h.ran('systemctl').some((c) => c.args.join(' ') === `--user restart ${SERVICE_NAME}`)).toBe(true);
    expect(h.logText()).toContain('재시작');
  });
});

describe('runServiceCommand — Windows (schtasks)', () => {
  it('install creates an onlogon task running node + cli.js', async () => {
    const h = harness({ platform: 'win32' });
    await runServiceCommand(['install'], h.deps);
    const create = h.ran('schtasks').find((c) => c.args[0] === '/create');
    expect(create).toBeDefined();
    expect(create?.args).toEqual([
      '/create',
      '/tn',
      SERVICE_NAME,
      '/sc',
      'onlogon',
      '/tr',
      '"/opt/node/bin/node" "/opt/dab/dist/cli.js"',
      '/f',
    ]);
    expect(h.failed).toBe(false);
    // The crash-restart limitation is surfaced.
    expect(h.logText()).toContain('자동 재시작을 보장하지 않습니다');
  });

  it('install writes NO run.sh/plist/unit on Windows', async () => {
    const h = harness({ platform: 'win32' });
    await runServiceCommand(['install'], h.deps);
    expect(h.files.size).toBe(0);
  });

  it('install fails cleanly when schtasks /create returns non-zero', async () => {
    const h = harness({ platform: 'win32' });
    h.results.set('schtasks', { code: 1, stdout: '', stderr: 'Access denied' });
    await runServiceCommand(['install'], h.deps);
    expect(h.failed).toBe(true);
    expect(h.logText()).toContain('README');
  });

  it('uninstall deletes the task', async () => {
    const h = harness({ platform: 'win32' });
    await runServiceCommand(['uninstall'], h.deps);
    expect(h.ran('schtasks').some((c) => c.args.join(' ') === `/delete /tn ${SERVICE_NAME} /f`)).toBe(true);
    expect(h.failed).toBe(false);
  });

  it('status reports registered when query succeeds', async () => {
    const h = harness({ platform: 'win32' });
    h.results.set('schtasks', { code: 0, stdout: 'TaskName: discord-agent-bridge', stderr: '' });
    await runServiceCommand(['status'], h.deps);
    expect(h.logText()).toContain('있음');
  });

  it('status reports not registered when query fails', async () => {
    const h = harness({ platform: 'win32' });
    h.results.set('schtasks', { code: 1, stdout: '', stderr: 'not found' });
    await runServiceCommand(['status'], h.deps);
    expect(h.logText()).toContain('없음');
    expect(h.failed).toBe(false); // query miss is informational, not a failure
  });

  it('restart ends then runs the task', async () => {
    const h = harness({ platform: 'win32' });
    await runServiceCommand(['restart'], h.deps);
    const calls = h.ran('schtasks');
    expect(calls.some((c) => c.args.join(' ') === `/end /tn ${SERVICE_NAME}`)).toBe(true);
    expect(calls.some((c) => c.args.join(' ') === `/run /tn ${SERVICE_NAME}`)).toBe(true);
    expect(h.logText()).toContain('재시작');
  });
});
