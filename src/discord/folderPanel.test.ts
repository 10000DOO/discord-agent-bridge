import { describe, it, expect, vi } from 'vitest';
import { EventEmitter } from 'node:events';
import { createMacFolderPanelOpener, type PanelProcess, type PanelSpawn } from './folderPanel.js';

// A fake osascript process the opener drives exactly like a real ChildProcess: stdout/
// stderr data events, a close event with an exit code, and kill() (recorded so the
// timeout test can assert the panel was actually closed).
function fakeProcess(): {
  proc: PanelProcess;
  emit: { stdout: (s: string) => void; stderr: (s: string) => void; close: (code: number | null) => void; error: (e: Error) => void };
  killed: () => string | undefined;
} {
  const events = new EventEmitter();
  const stdout = new EventEmitter();
  const stderr = new EventEmitter();
  let killSignal: string | undefined;
  const proc = {
    stdout: { on: (event: 'data', listener: (chunk: Buffer | string) => void) => stdout.on(event, listener) },
    stderr: { on: (event: 'data', listener: (chunk: Buffer | string) => void) => stderr.on(event, listener) },
    on: (event: 'error' | 'close', listener: (arg?: unknown) => void) => events.on(event, listener),
    kill: (signal?: NodeJS.Signals) => {
      killSignal = signal;
    },
  } as unknown as PanelProcess;
  return {
    proc,
    emit: {
      stdout: (s) => stdout.emit('data', s),
      stderr: (s) => stderr.emit('data', s),
      close: (code) => events.emit('close', code),
      error: (e) => events.emit('error', e),
    },
    killed: () => killSignal,
  };
}

describe('createMacFolderPanelOpener', () => {
  it('spawns osascript with an escaped choose-folder script and resolves the picked path', async () => {
    const fake = fakeProcess();
    const calls: { command: string; args: string[] }[] = [];
    const spawnFn: PanelSpawn = (command, args) => {
      calls.push({ command, args });
      return fake.proc;
    };
    const open = createMacFolderPanelOpener(spawnFn);
    const result = open('/Users/me/My "Quoted" Dir', 'Pick a folder', 60_000);
    fake.emit.stdout('/Users/me/project/\n');
    fake.emit.close(0);
    await expect(result).resolves.toBe('/Users/me/project/');
    // One osascript -e <script> invocation; quotes in the start dir are escaped so the
    // AppleScript source stays well-formed (no injection through a weird folder name).
    expect(calls).toHaveLength(1);
    expect(calls[0].command).toBe('osascript');
    expect(calls[0].args[0]).toBe('-e');
    expect(calls[0].args[1]).toContain('choose folder');
    expect(calls[0].args[1]).toContain('\\"Quoted\\"');
  });

  it('resolves null when the operator cancels (AppleScript error -128)', async () => {
    const fake = fakeProcess();
    const open = createMacFolderPanelOpener(() => fake.proc);
    const result = open('/tmp', 'Pick', 60_000);
    fake.emit.stderr('execution error: User canceled. (-128)\n');
    fake.emit.close(1);
    await expect(result).resolves.toBeNull();
  });

  it('kills the process and rejects with "timeout" when the dialog outlives timeoutMs', async () => {
    vi.useFakeTimers();
    try {
      const fake = fakeProcess();
      const open = createMacFolderPanelOpener(() => fake.proc);
      const result = open('/tmp', 'Pick', 5_000);
      vi.advanceTimersByTime(5_001);
      expect(fake.killed()).toBe('SIGKILL'); // the panel was actually closed
      fake.emit.close(null); // the kill surfaces as a close
      await expect(result).rejects.toThrow('timeout');
    } finally {
      vi.useRealTimers();
    }
  });

  it('rejects with stderr on any other non-zero exit', async () => {
    const fake = fakeProcess();
    const open = createMacFolderPanelOpener(() => fake.proc);
    const result = open('/tmp', 'Pick', 60_000);
    fake.emit.stderr('osascript: some real failure\n');
    fake.emit.close(2);
    await expect(result).rejects.toThrow('some real failure');
  });
});
