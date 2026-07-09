import { describe, it, expect } from 'vitest';
import * as path from 'node:path';
import { detectRestartStrategy, pidFilePath, type DetectDeps } from './environment.js';

const HOME = '/home/op';
const PLIST = path.join(HOME, 'Library', 'LaunchAgents', 'com.discord-agent-bridge.plist');
const UNIT = path.join(HOME, '.config', 'systemd', 'user', 'discord-agent-bridge.service');

function deps(over: Partial<DetectDeps>): DetectDeps {
  return {
    platform: 'linux',
    env: {},
    home: HOME,
    fileExists: () => false,
    ...over,
  };
}

describe('detectRestartStrategy', () => {
  it('win32 → respawn even with the marker (schtasks does not relaunch on exit)', () => {
    expect(detectRestartStrategy(deps({ platform: 'win32', env: { DAB_SUPERVISED: '1' } }))).toBe('respawn');
  });

  it('marker present → supervised', () => {
    expect(detectRestartStrategy(deps({ platform: 'darwin', env: { DAB_SUPERVISED: '1' } }))).toBe('supervised');
    expect(detectRestartStrategy(deps({ platform: 'linux', env: { DAB_SUPERVISED: '1' } }))).toBe('supervised');
  });

  it('marker absent but a launchd plist exists (darwin) → supervised (old-install fallback)', () => {
    expect(detectRestartStrategy(deps({ platform: 'darwin', fileExists: (p) => p === PLIST }))).toBe('supervised');
  });

  it('marker absent but a systemd unit exists (linux) → supervised (old-install fallback)', () => {
    expect(detectRestartStrategy(deps({ platform: 'linux', fileExists: (p) => p === UNIT }))).toBe('supervised');
  });

  it('does not cross-check the other platform’s service file', () => {
    // A linux host with (somehow) only a darwin plist present → no supervisor detected.
    expect(detectRestartStrategy(deps({ platform: 'linux', fileExists: (p) => p === PLIST }))).toBe('respawn');
  });

  it('no marker and no service file → respawn (foreground / npx)', () => {
    expect(detectRestartStrategy(deps({ platform: 'darwin' }))).toBe('respawn');
    expect(detectRestartStrategy(deps({ platform: 'linux' }))).toBe('respawn');
  });
});

describe('pidFilePath', () => {
  it('is agent.pid inside the base dir', () => {
    expect(pidFilePath('/base')).toBe(path.join('/base', 'agent.pid'));
  });
});
