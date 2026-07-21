import { spawn } from 'node:child_process';

// Native host-side folder picker for the channel wizard's folder step (dir:panel).
// On macOS the bot usually runs in the operator's GUI session (LaunchAgent /
// foreground terminal), so we can open a real "choose folder" dialog (an NSOpenPanel
// via osascript) ON the host and let the operator pick with Finder instead of typing
// an absolute path into a Discord modal. The picked path then drives the SAME
// DirectoryBrowser.goTo confinement as manual/click navigation — this module only
// produces a path, it grants nothing.
//
// Design notes:
// - Deliberately NO `tell application "System Events"` block: sending Apple Events
//   from a background LaunchAgent would trip the TCC Automation consent prompt (and
//   hang the first use if it cannot be shown). A plain `choose folder` runs in
//   osascript's own context and needs no permission; the trade-off is that the panel
//   may occasionally open behind other windows.
// - The dialog is only useful when the operator is physically AT the host, so the
//   caller supplies a timeout; on expiry the osascript process is killed, which closes
//   the panel — a tap from mobile can never leave a stray dialog open on an unattended
//   machine.

// The shape the router depends on: resolve the picked POSIX path, resolve null when
// the operator cancelled, reject with Error('timeout') on expiry (the caller words
// that case differently from a real failure).
export type FolderPanelOpener = (startDir: string, prompt: string, timeoutMs: number) => Promise<string | null>;

// A minimal slice of node:child_process's ChildProcess (structurally satisfied by the
// real thing) so unit tests drive a fake process without spawning anything.
export interface PanelProcess {
  stdout: { on(event: 'data', listener: (chunk: Buffer | string) => void): unknown } | null;
  stderr: { on(event: 'data', listener: (chunk: Buffer | string) => void): unknown } | null;
  on(event: 'error', listener: (err: Error) => void): unknown;
  on(event: 'close', listener: (code: number | null) => void): unknown;
  kill(signal?: NodeJS.Signals): unknown;
}

export type PanelSpawn = (command: string, args: string[]) => PanelProcess;

// AppleScript string literal escaping: backslash first, then double quotes. The prompt
// and start dir are interpolated into the script source, so this is what keeps a path
// like `/Volumes/My "Weird" Drive` from breaking (or injecting into) the script.
function escapeAppleScript(s: string): string {
  return s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

// Build the macOS opener. `spawnFn` is injectable for tests; production uses the real
// child_process.spawn. Cancel is AppleScript error -128 (osascript exits non-zero with
// the code in stderr) → resolves null. Any other non-zero exit rejects with stderr.
export function createMacFolderPanelOpener(spawnFn: PanelSpawn = spawn): FolderPanelOpener {
  return (startDir: string, prompt: string, timeoutMs: number): Promise<string | null> => {
    const script =
      `POSIX path of (choose folder with prompt "${escapeAppleScript(prompt)}"` +
      ` default location (POSIX file "${escapeAppleScript(startDir)}"))`;
    return new Promise((resolve, reject) => {
      const child = spawnFn('osascript', ['-e', script]);
      let out = '';
      let err = '';
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        child.kill('SIGKILL'); // closes the panel
      }, timeoutMs);
      child.stdout?.on('data', (d) => (out += String(d)));
      child.stderr?.on('data', (d) => (err += String(d)));
      child.on('error', (e) => {
        clearTimeout(timer);
        reject(e);
      });
      child.on('close', (code) => {
        clearTimeout(timer);
        if (timedOut) {
          reject(new Error('timeout'));
          return;
        }
        if (code === 0) {
          resolve(out.trim());
          return;
        }
        if (err.includes('-128')) {
          resolve(null); // the operator pressed Cancel
          return;
        }
        reject(new Error(err.trim() || `osascript exited ${String(code)}`));
      });
    });
  };
}
