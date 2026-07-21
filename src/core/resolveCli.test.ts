import { describe, it, expect } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  resolveCliCommand,
  wellKnownUserBinDirs,
  augmentPath,
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
      path.join('/Users/alice', '.cargo', 'bin'),
      '/opt/homebrew/bin',
      '/usr/local/bin',
    ]);
  });

  it('lists portable home bins plus /usr/local and linuxbrew on linux (order)', () => {
    const dirs = wellKnownUserBinDirs({ homeDir: '/home/alice', platform: 'linux' });
    expect(dirs).toEqual([
      path.join('/home/alice', '.local', 'bin'),
      path.join('/home/alice', '.grok', 'bin'),
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
