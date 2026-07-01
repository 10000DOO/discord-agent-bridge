import { spawn as realSpawn } from 'node:child_process';
import { readFile as realReadFile, mkdtemp as realMkdtemp, rm as realRm } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import * as os from 'node:os';
import * as path from 'node:path';
import type { AgentEvent, Logger, PermMode } from '../../core/contracts.js';
import { mapCodexLine } from './eventMapper.js';

// One `codex exec` turn: build argv from the resolved PermMode (fresh vs
// resume), spawn the CLI with `--json`, stream stdout line-by-line through the
// event mapper, forward each AgentEvent, capture the session id from
// `thread.started`, read the final message from the `-o` temp file
// (authoritative), and enforce a timeout (§5b, §7A). Every external touchpoint
// — spawn, readFile, tmp dir, the clock — is injectable so the whole turn can
// run under test with no real `codex` process and no network.

// ---- Injectable child-process seam ------------------------------------------
// A narrow view of the pieces of a spawned process we consume. The real
// node:child_process.ChildProcess satisfies this; tests supply a fake.
export interface SpawnedProcess {
  stdout: NodeJS.ReadableStream | null;
  stderr: NodeJS.ReadableStream | null;
  on(event: 'error', listener: (err: Error) => void): void;
  on(event: 'close', listener: (code: number | null, signal: NodeJS.Signals | null) => void): void;
  kill(signal?: NodeJS.Signals): boolean;
}

export type SpawnFn = (
  command: string,
  args: readonly string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv },
) => SpawnedProcess;

export type ReadFileFn = (filePath: string) => Promise<string>;

// ---- Public inputs / result -------------------------------------------------
export interface RunCodexTurnOptions {
  prompt: string; // may be '-' to read the prompt from stdin (see spec)
  cwd: string; // used only for a fresh turn (--cd); ignored on resume
  permMode: PermMode; // fresh-turn approval/sandbox mapping (ignored on resume)
  model?: string;
  resumeId?: string; // when set, a `codex exec resume` turn (no -a/-s/--cd)
  timeoutMs: number; // from config limits.codexTimeoutMs
  codexCommand?: string; // defaults to 'codex'
  codexHome?: string; // sets CODEX_HOME for the child
  emit: (ev: AgentEvent) => void; // → EventBus → Discord renderers
  logger: Logger;
  // Injectables (default to the real implementations).
  spawn?: SpawnFn;
  readFile?: ReadFileFn;
  tmpDir?: string; // base dir for the -o temp file; defaults to os.tmpdir()
  now?: () => number; // clock; defaults to Date.now
}

export type CodexTurnStatus = 'completed' | 'error' | 'timeout';

export interface RunCodexTurnResult {
  status: CodexTurnStatus;
  sessionId: string | null;
  finalMessage: string;
  exitCode: number | null;
}

// PermMode → codex approval/sandbox flags for a FRESH turn (verified against
// codex CLI 0.142.4; --full-auto is deprecated and intentionally unused).
// bypassPermissions omits -a/-s and passes the single bypass flag — that mode is
// gated behind an admin check elsewhere (§7A), not here.
export function permModeArgs(permMode: PermMode): string[] {
  switch (permMode) {
    case 'acceptEdits':
      return ['-a', 'never', '-s', 'workspace-write'];
    case 'bypassPermissions':
      return ['--dangerously-bypass-approvals-and-sandbox'];
    case 'plan':
      return ['-a', 'on-request', '-s', 'read-only'];
    case 'default':
    default:
      return ['-a', 'on-request', '-s', 'workspace-write'];
  }
}

// Build the full argv (excluding the command itself). Fresh and resume differ:
// resume takes the session id positionally and does NOT accept -a/-s/--cd — the
// thread's persisted approval/sandbox policy governs it, so we deliberately omit
// those flags on resume and rely on the thread's stored policy (§5b).
export function buildCodexArgs(opts: {
  prompt: string;
  cwd: string;
  permMode: PermMode;
  model?: string;
  resumeId?: string;
  outputPath: string;
}): string[] {
  const modelArgs = opts.model ? ['-m', opts.model] : [];

  if (opts.resumeId) {
    return ['exec', 'resume', '--json', opts.resumeId, ...modelArgs, '-o', opts.outputPath, opts.prompt];
  }

  return [
    'exec',
    '--json',
    ...permModeArgs(opts.permMode),
    ...modelArgs,
    '--skip-git-repo-check',
    '--cd',
    opts.cwd,
    '-o',
    opts.outputPath,
    opts.prompt,
  ];
}

export async function runCodexTurn(opts: RunCodexTurnOptions): Promise<RunCodexTurnResult> {
  const spawn = opts.spawn ?? (realSpawn as unknown as SpawnFn);
  const readFile = opts.readFile ?? ((p: string) => realReadFile(p, 'utf8'));
  const now = opts.now ?? Date.now;
  const codexCommand = opts.codexCommand ?? 'codex';
  const baseTmp = opts.tmpDir ?? os.tmpdir();

  const tempRoot = await realMkdtemp(path.join(baseTmp, 'dab-codex-'));
  const outputPath = path.join(tempRoot, `${randomBytes(8).toString('hex')}.txt`);

  const args = buildCodexArgs({
    prompt: opts.prompt,
    cwd: opts.cwd,
    permMode: opts.permMode,
    ...(opts.model !== undefined ? { model: opts.model } : {}),
    ...(opts.resumeId !== undefined ? { resumeId: opts.resumeId } : {}),
    outputPath,
  });

  // Correlate tool_use/tool_result across the two events a command_execution or
  // mcp_tool_call produces: reuse the item's own id when present, else mint a
  // stable per-item counter so the pair shares one id.
  let toolSeq = 0;
  const idFor = (item: Record<string, unknown>): string =>
    typeof item.id === 'string' && item.id.length > 0 ? item.id : `codex-tool-${++toolSeq}`;

  const start = now();
  let sessionId: string | null = opts.resumeId ?? null;
  let timedOut = false;

  try {
    const child = spawn(codexCommand, args, {
      cwd: opts.cwd,
      env: { ...process.env, ...(opts.codexHome ? { CODEX_HOME: opts.codexHome } : {}) },
    });

    const closeResult = await new Promise<{ code: number | null; spawnError?: Error }>((resolve) => {
      let settled = false;
      const done = (r: { code: number | null; spawnError?: Error }): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(r);
      };

      const timer = setTimeout(() => {
        timedOut = true;
        child.kill('SIGTERM');
      }, opts.timeoutMs);

      let lineBuffer = '';
      const consumeLine = (line: string): void => {
        const mapped = mapCodexLine(line, opts.logger, idFor);
        if (mapped.sessionId) sessionId = mapped.sessionId;
        for (const ev of mapped.events) opts.emit(ev);
      };

      child.stdout?.on('data', (chunk: Buffer | string) => {
        lineBuffer += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
        const lines = lineBuffer.split(/\r?\n/);
        lineBuffer = lines.pop() ?? '';
        for (const line of lines) consumeLine(line);
      });

      // Drain stderr so a full pipe never stalls the child; not surfaced as
      // events (the deprecation warning et al. live here and on stdout).
      child.stderr?.on('data', () => {});

      child.on('error', (err) => done({ code: null, spawnError: err }));
      child.on('close', (code) => {
        if (lineBuffer.trim().length > 0) consumeLine(lineBuffer);
        lineBuffer = '';
        done({ code });
      });
    });

    if (closeResult.spawnError) {
      opts.emit({ kind: 'error', message: closeResult.spawnError.message, retryable: false });
      return { status: 'error', sessionId, finalMessage: '', exitCode: null };
    }

    if (timedOut) {
      opts.emit({
        kind: 'error',
        message: `Codex turn timed out after ${opts.timeoutMs}ms.`,
        retryable: true,
      });
      return { status: 'timeout', sessionId, finalMessage: '', exitCode: closeResult.code };
    }

    // The -o file is the authoritative final message (not reconstructed from the
    // stream). A missing/unreadable file degrades to empty rather than throwing.
    const finalMessage = (await readFile(outputPath).catch(() => '')).trimEnd();
    const exitCode = closeResult.code;

    if (exitCode !== 0) {
      opts.emit({
        kind: 'error',
        message: `Codex exited with code ${exitCode ?? 'unknown'}.`,
        retryable: false,
      });
      return { status: 'error', sessionId, finalMessage, exitCode };
    }

    opts.logger.debug('codex turn completed', { durationMs: now() - start });
    return { status: 'completed', sessionId, finalMessage, exitCode };
  } finally {
    await realRm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
