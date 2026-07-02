import { spawn as realSpawn } from 'node:child_process';
import { readFile as realReadFile, mkdtemp as realMkdtemp, rm as realRm } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import * as os from 'node:os';
import * as path from 'node:path';
import type { AgentEvent, Logger, PermMode } from '../../core/contracts.js';
import { isCodexSandboxMode } from '../../core/providerCatalog.js';
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
  options: { cwd?: string; env?: NodeJS.ProcessEnv; stdio?: import('node:child_process').StdioOptions },
) => SpawnedProcess;

export type ReadFileFn = (filePath: string) => Promise<string>;

// ---- Public inputs / result -------------------------------------------------
export interface RunCodexTurnOptions {
  prompt: string; // may be '-' to read the prompt from stdin (see spec)
  cwd: string; // used only for a fresh turn (--cd); ignored on resume
  // Fresh-turn approval/sandbox mapping (ignored on resume). A Claude PermMode OR a
  // Codex-native sandbox mode (read-only / workspace-write / danger-full-access).
  permMode: string;
  model?: string;
  // Reasoning effort for a fresh turn → `-c model_reasoning_effort="…"`. Empty/absent
  // lets `codex` use its own config default.
  effort?: string;
  resumeId?: string; // when set, a `codex exec resume` turn (no -s/--cd; policy is the thread's)
  timeoutMs: number; // from config limits.codexTimeoutMs
  codexCommand?: string; // defaults to 'codex'
  codexHome?: string; // sets CODEX_HOME for the child
  emit: (ev: AgentEvent) => void; // → EventBus → Discord renderers
  logger: Logger;
  // When set, aborting it kills the in-flight `codex` child (SIGTERM) and the turn
  // resolves as 'aborted' — the ModeSession.stop() / kill-switch path (§7.5). An
  // already-aborted signal kills as soon as the child spawns. Optional so the
  // existing turn tests run unchanged.
  signal?: AbortSignal;
  // Injectables (default to the real implementations).
  spawn?: SpawnFn;
  readFile?: ReadFileFn;
  tmpDir?: string; // base dir for the -o temp file; defaults to os.tmpdir()
  now?: () => number; // clock; defaults to Date.now
}

export type CodexTurnStatus = 'completed' | 'error' | 'timeout' | 'aborted';

export interface RunCodexTurnResult {
  status: CodexTurnStatus;
  sessionId: string | null;
  finalMessage: string;
  exitCode: number | null;
}

// Permission choice → codex approval/sandbox flags for a FRESH turn (verified against
// codex CLI 0.142.4). `-a`/`--ask-for-approval` is a top-level TUI flag and is NOT
// accepted by `codex exec` (passing it fails the turn with exit 2), so the approval
// policy is set via `-c approval_policy="…"`; `-s`/`--sandbox` IS valid on exec.
//
// The wizard's Codex permission step offers Codex's OWN sandbox vocabulary
// (`read-only` / `workspace-write` / `danger-full-access`) rather than Claude's
// PermMode names. Those flow here on the same string channel; each maps to `-s <mode>`
// plus a sensible approval policy (danger-full-access → the single bypass flag). The
// legacy Claude PermMode values still map exactly as before, so a Claude-configured
// default that reaches a Codex session keeps working.
export function permModeArgs(permMode: string): string[] {
  // Codex-native sandbox modes (the wizard's Codex permission step).
  if (isCodexSandboxMode(permMode)) {
    switch (permMode) {
      case 'read-only':
        return ['-c', 'approval_policy="on-request"', '-s', 'read-only'];
      case 'danger-full-access':
        return ['--dangerously-bypass-approvals-and-sandbox'];
      case 'workspace-write':
      default:
        return ['-c', 'approval_policy="on-request"', '-s', 'workspace-write'];
    }
  }
  // Claude PermMode values (unchanged mapping).
  switch (permMode as PermMode) {
    case 'acceptEdits':
      return ['-c', 'approval_policy="never"', '-s', 'workspace-write'];
    case 'bypassPermissions':
      return ['--dangerously-bypass-approvals-and-sandbox'];
    case 'plan':
      return ['-c', 'approval_policy="on-request"', '-s', 'read-only'];
    case 'default':
    default:
      return ['-c', 'approval_policy="on-request"', '-s', 'workspace-write'];
  }
}

// The reasoning-effort argv for a fresh turn: `-c model_reasoning_effort="<level>"`
// (verified against developers.openai.com/codex/config-reference; accepts minimal /
// low / medium / high / xhigh). Empty/undefined → no flag, so `codex` uses its own
// config default (the operator's config.toml model_reasoning_effort).
export function effortArgs(effort?: string): string[] {
  const trimmed = (effort ?? '').trim();
  return trimmed.length > 0 ? ['-c', `model_reasoning_effort="${trimmed}"`] : [];
}

// Build the full argv (excluding the command itself). Fresh and resume differ:
// resume takes the session id positionally and does NOT accept -s/--cd — the
// thread's persisted approval/sandbox policy governs it, so we deliberately omit
// those flags on resume and rely on the thread's stored policy (§5b). Both put a
// `--` before the prompt so a prompt that begins with `-` can't be parsed as a
// flag.
export function buildCodexArgs(opts: {
  prompt: string;
  cwd: string;
  permMode: string;
  model?: string;
  effort?: string;
  resumeId?: string;
  outputPath: string;
}): string[] {
  const modelArgs = opts.model ? ['-m', opts.model] : [];

  if (opts.resumeId) {
    return ['exec', 'resume', '--json', '--skip-git-repo-check', opts.resumeId, ...modelArgs, '-o', opts.outputPath, '--', opts.prompt];
  }

  return [
    'exec',
    '--json',
    ...permModeArgs(opts.permMode),
    ...effortArgs(opts.effort),
    ...modelArgs,
    '--skip-git-repo-check',
    '--cd',
    opts.cwd,
    '-o',
    opts.outputPath,
    '--',
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
    ...(opts.effort !== undefined ? { effort: opts.effort } : {}),
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
  let aborted = false;

  try {
    // Ignore the child's stdin: the prompt is passed as an argv positional, but
    // `codex exec` still waits for stdin EOF ("Reading additional input from
    // stdin…") and would otherwise hang until the timeout.
    const child = spawn(codexCommand, args, {
      cwd: opts.cwd,
      env: { ...process.env, ...(opts.codexHome ? { CODEX_HOME: opts.codexHome } : {}) },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const closeResult = await new Promise<{ code: number | null; spawnError?: Error }>((resolve) => {
      let settled = false;
      const done = (r: { code: number | null; spawnError?: Error }): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (onAbort) opts.signal?.removeEventListener('abort', onAbort);
        resolve(r);
      };

      const timer = setTimeout(() => {
        timedOut = true;
        child.kill('SIGTERM');
      }, opts.timeoutMs);

      // Kill on external abort (ModeSession.stop / kill switch). If the signal is
      // already aborted, kill on the next tick so the child's close still drains.
      const onAbort = opts.signal
        ? (): void => {
            aborted = true;
            child.kill('SIGTERM');
          }
        : undefined;
      if (opts.signal && onAbort) {
        if (opts.signal.aborted) setImmediate(onAbort);
        else opts.signal.addEventListener('abort', onAbort, { once: true });
      }

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

    // An external abort (stop/kill switch) is expected shutdown, surfaced as a
    // non-retryable error and reported as 'aborted' (checked before the timeout so
    // a kill-triggered close is not misreported as a natural timeout).
    if (aborted && !timedOut) {
      opts.emit({ kind: 'error', message: 'Codex turn was stopped.', retryable: false });
      return { status: 'aborted', sessionId, finalMessage: '', exitCode: closeResult.code };
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
