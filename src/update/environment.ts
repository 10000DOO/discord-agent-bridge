import * as path from 'node:path';
import { launchdPlistPath } from '../service/launchd.js';
import { systemdUnitPath } from '../service/systemd.js';

// Restart-strategy detection (§3). The core invariant: in a SUPERVISED environment
// (launchd KeepAlive / systemd Restart=always) the process must exit and let the
// supervisor relaunch the new version, so `service restart`/`uninstall` keep working;
// only an UNsupervised process (foreground / npx / Windows schtasks) may respawn itself.

// 'supervised' = method A (exit only, the supervisor relaunches).
// 'respawn'    = method B (spawn a detached new process, then exit).
export type RestartStrategy = 'supervised' | 'respawn';

export interface DetectDeps {
  platform: NodeJS.Platform;
  env: NodeJS.ProcessEnv;
  home: string;
  // File existence probe (injected so tests never touch the real filesystem).
  fileExists: (p: string) => boolean;
}

// Decide how to restart after an in-place upgrade (§3.3):
//   win32                          → respawn  (schtasks onlogon does NOT relaunch on exit)
//   DAB_SUPERVISED=1 marker        → supervised (run.sh sets it; only launchd/systemd run.sh)
//   plist(darwin)/unit(linux) file → supervised (old-install fallback: marker not yet present)
//   otherwise                      → respawn  (foreground / npx)
export function detectRestartStrategy(d: DetectDeps): RestartStrategy {
  // Windows: the scheduled task does not relaunch on exit, so exiting would leave the
  // bot dead until the next logon — must respawn (§6). It also never runs run.sh, so
  // the marker is naturally absent; this explicit branch documents the intent.
  if (d.platform === 'win32') return 'respawn';

  // Primary signal: the run.sh marker proves a KeepAlive/Restart supervisor launched us.
  if (d.env.DAB_SUPERVISED === '1') return 'supervised';

  // Old-install fallback (§3.2): a service installed before the marker existed has a
  // markerless run.sh. Detect the service file so we still choose supervised and never
  // escape the supervisor with a detached respawn.
  if (d.platform === 'darwin' && d.fileExists(launchdPlistPath(d.home))) return 'supervised';
  if (d.platform === 'linux' && d.fileExists(systemdUnitPath(d.home))) return 'supervised';

  // No supervisor detected: foreground/npx run — respawn a detached new process.
  return 'respawn';
}

// The PID file path inside the DAB base dir. Written at boot (§3.5) so a foreground
// operator can terminate a detached-respawned instance (`kill $(cat …/agent.pid)`).
export function pidFilePath(baseDir: string): string {
  return path.join(baseDir, 'agent.pid');
}
