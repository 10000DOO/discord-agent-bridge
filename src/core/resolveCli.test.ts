import { describe, it, expect } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  resolveCliCommand,
  wellKnownUserBinDirs,
  augmentPath,
  resolveClaudeExecutable,
  cliVersionAtLeast,
  type ResolveCliOptions,
} from './resolveCli.js';

function resolve(
  command: string,
  overrides: ResolveCliOptions & { existing?: string[] } = {},
): string {
  const existing = new Set(overrides.existing ?? []);
  const { existing: _e, ...rest } = overrides;
  return resolveCliCommand(command, {
    env: rest.env ?? {},
    homeDir: rest.homeDir ?? '/home/alice',
    platform: rest.platform ?? 'linux',
    pathExists: rest.pathExists ?? ((p) => existing.has(p)),
  });
}

describe('wellKnownUserBinDirs', () => {
  it('lists portable home bins plus darwin Homebrew paths (order)', () => {
    const dirs = wellKnownUserBinDirs({ homeDir: '/Users/alice', platform: 'darwin' });
    expect(dirs).toEqual([
      path.join('/Users/alice', '.local', 'bin'),
      path.join('/Users/alice', '.grok', 'bin'),
      path.join('/Users/alice', '.dab', 'bin'),
      path.join('/Users/alice', '.cargo', 'bin'),
      '/opt/homebrew/bin',
      '/usr/local/bin',
    ]);
  });

  it('includes ~/.dab/bin on darwin (dab CLI install location)', () => {
    const dirs = wellKnownUserBinDirs({ homeDir: '/Users/alice', platform: 'darwin' });
    expect(dirs).toContain(path.join('/Users/alice', '.dab', 'bin'));
  });

  it('lists portable home bins plus /usr/local and linuxbrew on linux (order)', () => {
    const dirs = wellKnownUserBinDirs({ homeDir: '/home/alice', platform: 'linux' });
    expect(dirs).toEqual([
      path.join('/home/alice', '.local', 'bin'),
      path.join('/home/alice', '.grok', 'bin'),
      path.join('/home/alice', '.dab', 'bin'),
      path.join('/home/alice', '.cargo', 'bin'),
      '/usr/local/bin',
      '/home/linuxbrew/.linuxbrew/bin',
    ]);
  });

  it('includes cargo and LOCALAPPDATA Programs on win32', () => {
    const home = 'C:\\Users\\alice';
    const local = 'C:\\Users\\alice\\AppData\\Local';
    const dirs = wellKnownUserBinDirs({
      homeDir: home,
      platform: 'win32',
      env: { LOCALAPPDATA: local },
    });
    expect(dirs).toEqual([
      path.join(home, '.local', 'bin'),
      path.join(home, '.grok', 'bin'),
      path.join(home, '.dab', 'bin'),
      path.join(home, '.cargo', 'bin'),
      path.join(local, 'Programs'),
    ]);
  });

  it('omits Programs when LOCALAPPDATA is absent on win32', () => {
    const home = 'C:\\Users\\alice';
    const dirs = wellKnownUserBinDirs({
      homeDir: home,
      platform: 'win32',
      env: {},
    });
    // May still pick up process.env.LOCALAPPDATA on a real Windows host; on non-win
    // CI process.env.LOCALAPPDATA is usually unset → cargo ends the list.
    expect(dirs[0]).toBe(path.join(home, '.local', 'bin'));
    expect(dirs).toContain(path.join(home, '.cargo', 'bin'));
    expect(dirs).toContain(path.join(home, '.grok', 'bin'));
    expect(dirs).toContain(path.join(home, '.dab', 'bin'));
  });
});

describe('augmentPath', () => {
  it('prepends new dirs and dedupes against existing PATH', () => {
    const result = augmentPath('/usr/bin:/bin', ['/opt/homebrew/bin', '/usr/bin'], ':');
    expect(result).toBe('/opt/homebrew/bin:/usr/bin:/bin');
  });

  it('handles undefined PATH', () => {
    expect(augmentPath(undefined, ['/a', '/b'], ':')).toBe('/a:/b');
  });
});

describe('resolveCliCommand', () => {
  it('hits PATH first', () => {
    const bin = path.join('/opt/tools/bin', 'grok');
    const found = resolve('grok', {
      env: { PATH: '/opt/tools/bin:/usr/bin' },
      existing: [bin],
      homeDir: '/home/alice',
      platform: 'linux',
    });
    expect(found).toBe(bin);
  });

  it('hits ~/.grok/bin when PATH is empty', () => {
    const home = '/home/alice';
    const bin = path.join(home, '.grok', 'bin', 'grok');
    const found = resolve('grok', {
      env: { PATH: '' },
      existing: [bin],
      homeDir: home,
      platform: 'linux',
    });
    expect(found).toBe(bin);
  });

  it('returns bare name when missing', () => {
    const found = resolve('grok', {
      env: { PATH: '/usr/bin' },
      existing: [],
      homeDir: '/home/alice',
      platform: 'linux',
    });
    expect(found).toBe('grok');
  });

  it('returns absolute path as-is without probing', () => {
    const abs = '/usr/local/bin/grok';
    const found = resolve(abs, {
      env: { PATH: '' },
      existing: [],
      homeDir: '/home/alice',
      platform: 'linux',
    });
    expect(found).toBe(abs);
  });

  it('returns absolute missing path as-is (spawn will fail)', () => {
    const abs = '/does/not/exist/grok';
    const found = resolve(abs, {
      env: { PATH: '/usr/bin' },
      existing: [],
      homeDir: '/home/alice',
      platform: 'linux',
    });
    expect(found).toBe(abs);
  });

  it('prefers PATH over well-known dirs', () => {
    const home = '/home/alice';
    const pathHit = path.join('/opt/tools', 'grok');
    const homeHit = path.join(home, '.grok', 'bin', 'grok');
    const found = resolve('grok', {
      env: { PATH: '/opt/tools' },
      existing: [pathHit, homeHit],
      homeDir: home,
      platform: 'linux',
    });
    expect(found).toBe(pathHit);
  });

  it('finds darwin Homebrew path via well-known dirs', () => {
    const bin = path.join('/opt/homebrew/bin', 'grok');
    const found = resolve('grok', {
      env: { PATH: '' },
      existing: [bin],
      homeDir: '/Users/alice',
      platform: 'darwin',
    });
    expect(found).toBe(bin);
  });

  it('finds dab in ~/.dab/bin via well-known dirs', () => {
    const bin = path.join('/home/alice', '.dab', 'bin', 'dab');
    const found = resolve('dab', {
      env: { PATH: '' },
      pathExists: (p) => p.endsWith(path.join('.dab', 'bin', 'dab')),
      homeDir: '/home/alice',
      platform: 'darwin',
    });
    expect(found).toBe(bin);
  });

  it('finds linuxbrew path via well-known dirs', () => {
    const bin = path.join('/home/linuxbrew/.linuxbrew/bin', 'grok');
    const found = resolve('grok', {
      env: { PATH: '' },
      existing: [bin],
      homeDir: '/home/alice',
      platform: 'linux',
    });
    expect(found).toBe(bin);
  });

  it('on win32 tries .exe when bare name is missing', () => {
    const home = 'C:\\Users\\alice';
    const bin = path.join(home, '.grok', 'bin', 'grok.exe');
    const found = resolve('grok', {
      env: { PATH: '' },
      existing: [bin],
      homeDir: home,
      platform: 'win32',
    });
    expect(found).toBe(bin);
  });

  it('uses env.HOME when homeDir is omitted', () => {
    const customHome = '/var/custom-homes/devbox42';
    const bin = path.join(customHome, '.local', 'bin', 'grok');
    const found = resolveCliCommand('grok', {
      env: { PATH: '', HOME: customHome },
      platform: 'linux',
      pathExists: (p) => p === bin,
    });
    expect(found).toBe(bin);
  });

  it('resolution logic does not embed hardcoded /Users/ expectations', () => {
    // homeDir is injected; resolution must work for ANY home string, not a fixed username.
    const customHome = '/var/custom-homes/devbox42';
    const bin = path.join(customHome, '.local', 'bin', 'grok');
    const found = resolve('grok', {
      env: { PATH: '' },
      existing: [bin],
      homeDir: customHome,
      platform: 'linux',
    });
    expect(found).toBe(bin);
    expect(found).not.toMatch(/^\/Users\//);
  });

  it('default checker accepts executable files and rejects directories / non-executables', () => {
    // Integration against the real default pathExists (no inject). Skip on win32
    // where execute-bit semantics differ.
    if (process.platform === 'win32') return;

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'resolve-cli-'));
    try {
      const binDir = path.join(tmp, 'bin');
      fs.mkdirSync(binDir);
      const fileOk = path.join(binDir, 'tool-ok');
      const fileNoX = path.join(binDir, 'tool-nox');
      const asDir = path.join(binDir, 'tool-dir');
      fs.writeFileSync(fileOk, '#!/bin/sh\n');
      fs.chmodSync(fileOk, 0o755);
      fs.writeFileSync(fileNoX, '#!/bin/sh\n');
      fs.chmodSync(fileNoX, 0o644);
      fs.mkdirSync(asDir);

      // Only tool-ok is runnable; search via PATH.
      expect(
        resolveCliCommand('tool-ok', {
          env: { PATH: binDir },
          homeDir: '/no/home',
          platform: process.platform,
        }),
      ).toBe(fileOk);

      expect(
        resolveCliCommand('tool-nox', {
          env: { PATH: binDir },
          homeDir: '/no/home',
          platform: process.platform,
        }),
      ).toBe('tool-nox');

      expect(
        resolveCliCommand('tool-dir', {
          env: { PATH: binDir },
          homeDir: '/no/home',
          platform: process.platform,
        }),
      ).toBe('tool-dir');
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });
});

describe('resolveClaudeExecutable', () => {
  const base = { env: {}, homeDir: '/home/alice', platform: 'linux' as const, execPath: '/opt/node/bin/node', listDir: () => [] };

  it('returns undefined when nothing is installed (SDK keeps its bundled CLI)', () => {
    expect(resolveClaudeExecutable({ ...base, pathExists: () => false })).toBeUndefined();
  });

  it('returns the native installer path, prefers the running node bin over older nvm versions, and unwraps .js / Windows .cmd', () => {
    const native = path.join('/home/alice', '.local', 'bin', 'claude');
    expect(resolveClaudeExecutable({ ...base, pathExists: (p) => p === native, realpath: (p) => p })).toBe(native);

    const nvmNode = path.join('/home/alice', '.nvm', 'versions', 'node');
    const running = path.join(nvmNode, 'v20.1.0', 'bin', 'claude');
    const newest = path.join(nvmNode, 'v22.0.0', 'bin', 'claude');
    const both = new Set([running, newest]);
    const nvm = { ...base, execPath: path.join(nvmNode, 'v20.1.0', 'bin', 'node'), listDir: () => ['v9.0.0', 'v22.0.0', 'v20.1.0'], pathExists: (p: string) => both.has(p), realpath: (p: string) => p };
    expect(resolveClaudeExecutable(nvm)).toBe(running);
    expect(resolveClaudeExecutable({ ...nvm, execPath: '/usr/bin/node' })).toBe(newest);

    const cliJs = '/opt/node/lib/node_modules/@anthropic-ai/claude-code/cli.js';
    expect(resolveClaudeExecutable({ ...base, pathExists: (p) => p === path.join('/opt/node/bin', 'claude'), realpath: () => cliJs })).toBe(cliJs);

    const npmDir = path.join('C:\\Users\\alice\\AppData\\Roaming', 'npm');
    const exe = path.join(npmDir, 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe');
    const win = new Set([path.join(npmDir, 'claude.cmd'), exe]);
    expect(resolveClaudeExecutable({ ...base, platform: 'win32', homeDir: 'C:\\Users\\alice', env: { APPDATA: 'C:\\Users\\alice\\AppData\\Roaming' }, pathExists: (p) => win.has(p) })).toBe(exe);
  });
});

describe('cliVersionAtLeast', () => {
  it('compares X.Y.Z numerically against the bundled version; unparsable or missing → false', () => {
    expect(cliVersionAtLeast('2.1.284 (Claude Code)\n', '2.1.284')).toBe(true);
    expect(cliVersionAtLeast('2.2.0 (Claude Code)', '2.1.284')).toBe(true);
    expect(cliVersionAtLeast('10.0.0', '9.9.9')).toBe(true);
    expect(cliVersionAtLeast('2.1.99 (Claude Code)', '2.1.284')).toBe(false);
    expect(cliVersionAtLeast('2.0.77 (Claude Code)', '2.1.284')).toBe(false);
    expect(cliVersionAtLeast('', '2.1.284')).toBe(false);
    expect(cliVersionAtLeast('oops', '2.1.284')).toBe(false);
    expect(cliVersionAtLeast('2.1.284', undefined)).toBe(false);
  });
});
