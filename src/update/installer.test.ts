import { describe, it, expect, vi } from 'vitest';
import * as path from 'node:path';
import {
  installLatest,
  performRestart,
  writePidFile,
  removePidFile,
  type MinimalFs,
  type SpawnFn,
} from './installer.js';
import type { CommandResult, CommandRunner } from '../service/types.js';

describe('installLatest', () => {
  it('runs `npm i -g discord-agent-bridge@latest` on non-Windows', async () => {
    const calls: [string, readonly string[]][] = [];
    const run: CommandRunner = async (cmd, args) => {
      calls.push([cmd, args]);
      return { code: 0, stdout: '', stderr: '' };
    };
    const res = await installLatest(run, 'linux');
    expect(calls).toEqual([['npm', ['i', '-g', 'discord-agent-bridge@latest']]]);
    expect(res).toEqual({ ok: true, code: 0, stderr: '' });
  });

  it('uses npm.cmd on win32', async () => {
    const calls: string[] = [];
    const run: CommandRunner = async (cmd) => {
      calls.push(cmd);
      return { code: 0, stdout: '', stderr: '' };
    };
    await installLatest(run, 'win32');
    expect(calls).toEqual(['npm.cmd']);
  });

  it('maps a non-zero exit to ok:false and surfaces stderr', async () => {
    const run: CommandRunner = async () => ({ code: 243, stdout: '', stderr: 'EACCES' } as CommandResult);
    expect(await installLatest(run, 'linux')).toEqual({ ok: false, code: 243, stderr: 'EACCES' });
  });

  it('never throws when the runner rejects (npm missing) → ok:false, code:null', async () => {
    const run: CommandRunner = async () => {
      throw Object.assign(new Error('spawn npm ENOENT'), { code: 'ENOENT' });
    };
    const res = await installLatest(run, 'linux');
    expect(res.ok).toBe(false);
    expect(res.code).toBeNull();
    expect(res.stderr).toContain('ENOENT');
  });
});

describe('performRestart', () => {
  const base = {
    nodePath: '/usr/bin/node',
    cliEntry: '/pkg/dist/cli.js',
    env: { FOO: 'bar' } as NodeJS.ProcessEnv,
  };

  it('supervised: exits(0) only, never spawns', () => {
    const spawn = vi.fn() as unknown as SpawnFn;
    const exit = vi.fn() as unknown as (code: number) => never;
    performRestart({ strategy: 'supervised', spawn, exit, ...base });
    expect(spawn).not.toHaveBeenCalled();
    expect(exit).toHaveBeenCalledWith(0);
  });

  it('respawn: spawns a detached, I/O-less successor + unref, then exits(0)', () => {
    const unref = vi.fn();
    const spawn = vi.fn(() => ({ unref })) as unknown as SpawnFn;
    const exit = vi.fn() as unknown as (code: number) => never;
    performRestart({ strategy: 'respawn', spawn, exit, ...base });
    expect(spawn).toHaveBeenCalledWith('/usr/bin/node', ['/pkg/dist/cli.js'], {
      detached: true,
      stdio: 'ignore',
      env: base.env,
    });
    expect(unref).toHaveBeenCalledTimes(1);
    expect(exit).toHaveBeenCalledWith(0);
  });
});

describe('pid file helpers', () => {
  function fakeFs(): { fs: MinimalFs; files: Map<string, string> } {
    const files = new Map<string, string>();
    const fs: MinimalFs = {
      writeFileSync: (p, data) => void files.set(p, data),
      existsSync: (p) => files.has(p),
      rmSync: (p) => void files.delete(p),
    };
    return { fs, files };
  }

  it('writePidFile writes the pid to <baseDir>/agent.pid', () => {
    const { fs, files } = fakeFs();
    writePidFile('/base', 4242, fs);
    expect(files.get(path.join('/base', 'agent.pid'))).toBe('4242');
  });

  it('removePidFile deletes an existing pid file', () => {
    const { fs, files } = fakeFs();
    writePidFile('/base', 1, fs);
    removePidFile('/base', fs);
    expect(files.has(path.join('/base', 'agent.pid'))).toBe(false);
  });

  it('removePidFile is a no-op when the file is absent (never throws)', () => {
    const { fs } = fakeFs();
    expect(() => removePidFile('/base', fs)).not.toThrow();
  });
});
