import { describe, it, expect, vi } from 'vitest';
import { EventEmitter } from 'node:events';
import * as os from 'node:os';
import type { AgentEvent, Logger } from '../../core/contracts.js';
import { mapCodexLine } from './eventMapper.js';
import { runCodexTurn, buildCodexArgs, permModeArgs, type SpawnFn, type SpawnedProcess } from './runner.js';

// ---- Test doubles ------------------------------------------------------------

// A recording logger: captures debug() calls so tests can assert non-silent
// handling of unrecognized/deprecation lines.
function makeLogger(): { logger: Logger; debugCalls: unknown[][] } {
  const debugCalls: unknown[][] = [];
  const logger: Logger = {
    debug: (...meta: unknown[]) => debugCalls.push(meta),
    info: () => {},
    warn: () => {},
    error: () => {},
  };
  return { logger, debugCalls };
}

// A fake ChildProcess: an EventEmitter with a stdout/stderr EventEmitter each.
// Tests push stdout lines then fire 'close'; `kill()` is recorded so a timeout
// test can assert the process was terminated.
class FakeChild extends EventEmitter {
  readonly stdout = new EventEmitter();
  readonly stderr = new EventEmitter();
  killed: NodeJS.Signals | undefined;
  kill(signal?: NodeJS.Signals): boolean {
    this.killed = signal;
    // A real SIGTERM ends the process; emulate the ensuing close.
    setImmediate(() => this.emit('close', null, signal ?? 'SIGTERM'));
    return true;
  }
}

// Build an injectable spawn that: records the argv/options, returns a FakeChild,
// and (after a tick, so the caller has attached its listeners) streams the
// scripted stdout chunks and fires 'close' with `exitCode`. If `stall` is true
// it never closes on its own — only kill() ends it (for the timeout test).
function fakeSpawn(opts: {
  stdoutChunks: string[];
  exitCode?: number;
  stall?: boolean;
  spawnError?: Error;
}): { spawn: SpawnFn; captured: { command?: string; args?: readonly string[]; env?: NodeJS.ProcessEnv }; child: FakeChild } {
  const child = new FakeChild();
  const captured: { command?: string; args?: readonly string[]; env?: NodeJS.ProcessEnv } = {};
  const spawn: SpawnFn = (command, args, options) => {
    captured.command = command;
    captured.args = args;
    captured.env = options.env;
    setImmediate(() => {
      if (opts.spawnError) {
        child.emit('error', opts.spawnError);
        return;
      }
      for (const chunk of opts.stdoutChunks) child.stdout.emit('data', Buffer.from(chunk, 'utf8'));
      if (!opts.stall) child.emit('close', opts.exitCode ?? 0, null);
    });
    return child as unknown as SpawnedProcess;
  };
  return { spawn, captured, child };
}

// A scripted `codex exec --json` stdout stream exercising every mapped kind:
// the deprecation warning (non-JSON), thread.started, item.started progress,
// item.completed agent_message + command_execution (exit 0 and non-0) +
// file_change + mcp_tool_call, an unknown-type line, and turn.completed w/ usage.
function scriptedStdout(): string {
  const lines = [
    'warning: `--full-auto` is deprecated; use `-a`/`-s` instead', // non-JSON deprecation
    JSON.stringify({ type: 'thread.started', thread_id: 'thread-xyz' }),
    JSON.stringify({ type: 'turn.started' }),
    JSON.stringify({ type: 'item.started', item: { type: 'command_execution', command: 'ls -la' } }),
    JSON.stringify({ type: 'item.completed', item: { type: 'agent_message', text: 'Here is the plan.' } }),
    JSON.stringify({
      type: 'item.completed',
      item: { type: 'command_execution', id: 'cmd-1', command: 'ls', aggregated_output: 'a\nb', exit_code: 0 },
    }),
    JSON.stringify({
      type: 'item.completed',
      item: { type: 'command_execution', id: 'cmd-2', command: 'false', aggregated_output: 'boom', exit_code: 1 },
    }),
    JSON.stringify({
      type: 'item.completed',
      item: { type: 'file_change', id: 'fc-1', changes: [{ path: 'src/a.ts', kind: 'update' }] },
    }),
    JSON.stringify({
      type: 'item.completed',
      item: { type: 'mcp_tool_call', id: 'mcp-1', tool: 'search', arguments: { q: 'hi' }, result: 'found', status: 'completed' },
    }),
    JSON.stringify({ type: 'item.completed', item: { type: 'reasoning', text: 'internal thoughts' } }),
    JSON.stringify({ type: 'some.future.event', item: { type: 'brand_new' } }), // unknown type
    JSON.stringify({ type: 'turn.completed', usage: { input_tokens: 120, output_tokens: 34, total_tokens: 154 } }),
  ];
  // Codex prints one JSON object per line; join and add a trailing newline so
  // the last real line is flushed before close.
  return lines.join('\n') + '\n';
}

function collect(): { emit: (ev: AgentEvent) => void; events: AgentEvent[] } {
  const events: AgentEvent[] = [];
  return { emit: (ev) => events.push(ev), events };
}

// ---- eventMapper (pure core) -------------------------------------------------

describe('mapCodexLine', () => {
  const idFor = (item: Record<string, unknown>): string => (typeof item.id === 'string' ? item.id : 'gen');

  it('captures the sessionId from thread.started without emitting an event', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'thread.started', thread_id: 't-1' }), logger, idFor);
    expect(r.sessionId).toBe('t-1');
    expect(r.events).toEqual([]);
  });

  it('maps agent_message to a non-delta text event', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'item.completed', item: { type: 'agent_message', text: 'hi' } }), logger, idFor);
    expect(r.events).toEqual([{ kind: 'text', text: 'hi', delta: false }]);
  });

  it('drops reasoning items (thinking is unsupported)', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'item.completed', item: { type: 'reasoning', text: 'x' } }), logger, idFor);
    expect(r.events).toEqual([]);
  });

  it('maps command_execution to a tool_use + tool_result pair sharing one id', () => {
    const { logger } = makeLogger();
    const ok = mapCodexLine(
      JSON.stringify({ type: 'item.completed', item: { type: 'command_execution', id: 'c1', command: 'ls', aggregated_output: 'out', exit_code: 0 } }),
      logger,
      idFor,
    );
    expect(ok.events).toEqual([
      { kind: 'tool_use', id: 'c1', name: 'shell', input: { command: 'ls' } },
      { kind: 'tool_result', id: 'c1', ok: true, content: 'out' },
    ]);

    const fail = mapCodexLine(
      JSON.stringify({ type: 'item.completed', item: { type: 'command_execution', id: 'c2', command: 'false', aggregated_output: 'err', exit_code: 1 } }),
      logger,
      idFor,
    );
    expect(fail.events).toContainEqual({ kind: 'tool_result', id: 'c2', ok: false, content: 'err' });
  });

  it('maps file_change to an apply_patch tool_use carrying the changes', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(
      JSON.stringify({ type: 'item.completed', item: { type: 'file_change', id: 'f1', changes: [{ path: 'a.ts', kind: 'add' }] } }),
      logger,
      idFor,
    );
    expect(r.events).toEqual([{ kind: 'tool_use', id: 'f1', name: 'apply_patch', input: { changes: [{ path: 'a.ts', kind: 'add' }] } }]);
  });

  it('maps mcp_tool_call to a tool_use (+ tool_result when a result is present)', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(
      JSON.stringify({ type: 'item.completed', item: { type: 'mcp_tool_call', id: 'm1', tool: 'search', arguments: { q: 'x' }, result: 'ok', status: 'completed' } }),
      logger,
      idFor,
    );
    expect(r.events).toEqual([
      { kind: 'tool_use', id: 'm1', name: 'search', input: { q: 'x' } },
      { kind: 'tool_result', id: 'm1', ok: true, content: 'ok' },
    ]);
  });

  it('maps a web_search item to a web_search tool_use', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'item.completed', item: { type: 'web_search', id: 'w1', query: 'cats' } }), logger, idFor);
    expect(r.events).toEqual([{ kind: 'tool_use', id: 'w1', name: 'web_search', input: { query: 'cats' } }]);
  });

  it('maps turn.completed usage to a result with token counts only (no usage panel)', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'turn.completed', usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } }), logger, idFor);
    expect(r.events).toEqual([{ kind: 'result', tokensIn: 10, tokensOut: 5 }]);
    // Never a context_usage event for Codex.
    expect(r.events.some((e) => e.kind === 'context_usage')).toBe(false);
  });

  it('maps turn.failed / thread.failed to a non-retryable error', () => {
    const { logger } = makeLogger();
    const turn = mapCodexLine(JSON.stringify({ type: 'turn.failed', error: { message: 'nope' } }), logger, idFor);
    expect(turn.events).toEqual([{ kind: 'error', message: 'nope', retryable: false }]);
    const thread = mapCodexLine(JSON.stringify({ type: 'thread.failed', error: { message: 'boom' } }), logger, idFor);
    expect(thread.events).toEqual([{ kind: 'error', message: 'boom', retryable: false }]);
  });

  it('maps an error item to a non-retryable error event', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'item.completed', item: { type: 'error', message: 'kaput' } }), logger, idFor);
    expect(r.events).toEqual([{ kind: 'error', message: 'kaput', retryable: false }]);
  });

  it('classifies item.started as a progress event', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'item.started', item: { type: 'command_execution', command: 'ls' } }), logger, idFor);
    expect(r.events).toEqual([{ kind: 'progress', label: '명령 실행 중', detail: 'ls' }]);
  });

  it('logs a non-JSON line at debug and emits nothing (never throws)', () => {
    const { logger, debugCalls } = makeLogger();
    const r = mapCodexLine('warning: `--full-auto` is deprecated', logger, idFor);
    expect(r.events).toEqual([]);
    expect(debugCalls.length).toBe(1);
    expect(debugCalls[0]?.[0]).toBe('unrecognized codex event');
  });

  it('logs an unknown JSON type at debug and emits nothing', () => {
    const { logger, debugCalls } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'brand.new.thing' }), logger, idFor);
    expect(r.events).toEqual([]);
    expect(debugCalls.length).toBe(1);
  });

  it('understands the alternate event_msg agent-message shape (stream drift)', () => {
    const { logger } = makeLogger();
    const r = mapCodexLine(JSON.stringify({ type: 'event_msg', payload: { type: 'agent_message', message: 'drifted' } }), logger, idFor);
    expect(r.events).toEqual([{ kind: 'text', text: 'drifted', delta: false }]);
  });
});

// ---- permModeArgs / buildCodexArgs ------------------------------------------

describe('permModeArgs (PermMode → codex flags, fresh turn)', () => {
  it('maps default to on-request + workspace-write', () => {
    expect(permModeArgs('default')).toEqual(['-a', 'on-request', '-s', 'workspace-write']);
  });
  it('maps acceptEdits to never + workspace-write', () => {
    expect(permModeArgs('acceptEdits')).toEqual(['-a', 'never', '-s', 'workspace-write']);
  });
  it('maps bypassPermissions to the single bypass flag (no -a/-s)', () => {
    expect(permModeArgs('bypassPermissions')).toEqual(['--dangerously-bypass-approvals-and-sandbox']);
  });
  it('maps plan to on-request + read-only', () => {
    expect(permModeArgs('plan')).toEqual(['-a', 'on-request', '-s', 'read-only']);
  });
});

describe('buildCodexArgs', () => {
  it('builds a fresh-turn argv with permission flags, model, --cd, and -o', () => {
    const args = buildCodexArgs({
      prompt: 'do it',
      cwd: '/tmp/ws',
      permMode: 'default',
      model: 'gpt-5-codex',
      outputPath: '/tmp/out.txt',
    });
    expect(args).toEqual([
      'exec',
      '--json',
      '-a',
      'on-request',
      '-s',
      'workspace-write',
      '-m',
      'gpt-5-codex',
      '--skip-git-repo-check',
      '--cd',
      '/tmp/ws',
      '-o',
      '/tmp/out.txt',
      'do it',
    ]);
  });

  it('each fresh PermMode produces the correct -a/-s (or bypass) argv', () => {
    const base = { prompt: 'p', cwd: '/ws', outputPath: '/o.txt' };
    expect(buildCodexArgs({ ...base, permMode: 'default' })).toContain('on-request');
    expect(buildCodexArgs({ ...base, permMode: 'acceptEdits' })).toEqual(
      expect.arrayContaining(['-a', 'never', '-s', 'workspace-write']),
    );
    expect(buildCodexArgs({ ...base, permMode: 'plan' })).toEqual(
      expect.arrayContaining(['-a', 'on-request', '-s', 'read-only']),
    );
    const bypass = buildCodexArgs({ ...base, permMode: 'bypassPermissions' });
    expect(bypass).toContain('--dangerously-bypass-approvals-and-sandbox');
    expect(bypass).not.toContain('-a');
    expect(bypass).not.toContain('-s');
  });

  it('builds a resume argv that omits -a/-s/--cd and passes the session id positionally', () => {
    const args = buildCodexArgs({
      prompt: 'continue',
      cwd: '/tmp/ws',
      permMode: 'bypassPermissions', // must be ignored on resume
      model: 'gpt-5-codex',
      resumeId: 'thread-xyz',
      outputPath: '/tmp/out.txt',
    });
    expect(args).toEqual(['exec', 'resume', '--json', 'thread-xyz', '-m', 'gpt-5-codex', '-o', '/tmp/out.txt', 'continue']);
    expect(args).not.toContain('-a');
    expect(args).not.toContain('-s');
    expect(args).not.toContain('--cd');
    expect(args).not.toContain('--dangerously-bypass-approvals-and-sandbox');
  });
});

// ---- runCodexTurn (end-to-end with a mocked child process) -------------------

describe('runCodexTurn', () => {
  const tmpDir = os.tmpdir();

  it('streams the scripted stdout into ordered AgentEvents and reads the -o final message', async () => {
    const { logger, debugCalls } = makeLogger();
    const { emit, events } = collect();
    const { spawn } = fakeSpawn({ stdoutChunks: [scriptedStdout()], exitCode: 0 });
    const readFile = vi.fn().mockResolvedValue('FINAL MESSAGE FROM FILE\n');

    const result = await runCodexTurn({
      prompt: 'hello',
      cwd: '/tmp/ws',
      permMode: 'default',
      timeoutMs: 5_000,
      emit,
      logger,
      spawn,
      readFile,
      tmpDir,
    });

    // sessionId captured from thread.started.
    expect(result.sessionId).toBe('thread-xyz');
    // status completed on exit 0.
    expect(result.status).toBe('completed');
    expect(result.exitCode).toBe(0);
    // final message comes from the -o file, NOT reconstructed from the stream.
    expect(result.finalMessage).toBe('FINAL MESSAGE FROM FILE');
    expect(readFile).toHaveBeenCalledTimes(1);

    // Ordered AgentEvents: progress → text → shell(ok) → shell(fail) → apply_patch
    // → mcp tool_use+result → result(tokens). reasoning + unknown are absent.
    expect(events).toEqual([
      { kind: 'progress', label: '명령 실행 중', detail: 'ls -la' },
      { kind: 'text', text: 'Here is the plan.', delta: false },
      { kind: 'tool_use', id: 'cmd-1', name: 'shell', input: { command: 'ls' } },
      { kind: 'tool_result', id: 'cmd-1', ok: true, content: 'a\nb' },
      { kind: 'tool_use', id: 'cmd-2', name: 'shell', input: { command: 'false' } },
      { kind: 'tool_result', id: 'cmd-2', ok: false, content: 'boom' },
      { kind: 'tool_use', id: 'fc-1', name: 'apply_patch', input: { changes: [{ path: 'src/a.ts', kind: 'update' }] } },
      { kind: 'tool_use', id: 'mcp-1', name: 'search', input: { q: 'hi' } },
      { kind: 'tool_result', id: 'mcp-1', ok: true, content: 'found' },
      { kind: 'result', tokensIn: 120, tokensOut: 34 },
    ]);

    // No usage/context_usage event ever emitted for Codex.
    expect(events.some((e) => e.kind === 'context_usage')).toBe(false);

    // Both the deprecation warning and the unknown-type line were logged (not
    // crashed, not silently dropped). Filter to the mapper's debug calls.
    const unrecognized = debugCalls.filter((c) => c[0] === 'unrecognized codex event');
    expect(unrecognized.length).toBe(2);
  });

  it('passes CODEX_HOME through to the child env and the model into argv', async () => {
    const { logger } = makeLogger();
    const { emit } = collect();
    const { spawn, captured } = fakeSpawn({ stdoutChunks: [scriptedStdout()], exitCode: 0 });
    await runCodexTurn({
      prompt: 'hi',
      cwd: '/tmp/ws',
      permMode: 'plan',
      model: 'gpt-5-codex',
      codexHome: '/custom/.codex',
      timeoutMs: 5_000,
      emit,
      logger,
      spawn,
      readFile: async () => 'ok',
      tmpDir,
    });
    expect(captured.env?.CODEX_HOME).toBe('/custom/.codex');
    expect(captured.args).toEqual(expect.arrayContaining(['-m', 'gpt-5-codex', '-a', 'on-request', '-s', 'read-only']));
  });

  it('reports status:error and emits an error event on a non-zero exit', async () => {
    const { logger } = makeLogger();
    const { emit, events } = collect();
    const { spawn } = fakeSpawn({
      stdoutChunks: [JSON.stringify({ type: 'thread.started', thread_id: 't' }) + '\n'],
      exitCode: 2,
    });
    const result = await runCodexTurn({
      prompt: 'hi',
      cwd: '/tmp/ws',
      permMode: 'default',
      timeoutMs: 5_000,
      emit,
      logger,
      spawn,
      readFile: async () => '',
      tmpDir,
    });
    expect(result.status).toBe('error');
    expect(result.exitCode).toBe(2);
    expect(events.some((e) => e.kind === 'error' && !e.retryable)).toBe(true);
  });

  it('kills the process and emits an error on timeout', async () => {
    const { logger } = makeLogger();
    const { emit, events } = collect();
    const { spawn, child } = fakeSpawn({ stdoutChunks: [], stall: true });
    const result = await runCodexTurn({
      prompt: 'hi',
      cwd: '/tmp/ws',
      permMode: 'default',
      timeoutMs: 20, // short: the stalled child never closes on its own
      emit,
      logger,
      spawn,
      readFile: async () => 'should-not-be-used',
      tmpDir,
    });
    expect(result.status).toBe('timeout');
    expect(child.killed).toBe('SIGTERM');
    const errs = events.filter((e) => e.kind === 'error');
    expect(errs.length).toBe(1);
    expect(errs[0]).toMatchObject({ kind: 'error', retryable: true });
    expect((errs[0] as { message: string }).message).toMatch(/timed out/);
  });

  it('reports status:error when the child fails to spawn', async () => {
    const { logger } = makeLogger();
    const { emit, events } = collect();
    const { spawn } = fakeSpawn({ stdoutChunks: [], spawnError: new Error('ENOENT: codex not found') });
    const result = await runCodexTurn({
      prompt: 'hi',
      cwd: '/tmp/ws',
      permMode: 'default',
      timeoutMs: 5_000,
      emit,
      logger,
      spawn,
      readFile: async () => '',
      tmpDir,
    });
    expect(result.status).toBe('error');
    expect(result.exitCode).toBe(null);
    expect(events).toContainEqual({ kind: 'error', message: 'ENOENT: codex not found', retryable: false });
  });

  it('aborts an in-flight turn: kills the child and resolves as status:aborted', async () => {
    const { logger } = makeLogger();
    const { emit, events } = collect();
    const { spawn, child } = fakeSpawn({ stdoutChunks: [], stall: true });
    const controller = new AbortController();
    // Abort shortly after the run starts (the stalled child never closes on its own).
    setTimeout(() => controller.abort(), 10);

    const result = await runCodexTurn({
      prompt: 'hi',
      cwd: '/tmp/ws',
      permMode: 'default',
      timeoutMs: 5_000, // long: the abort, not the timeout, must end it
      emit,
      logger,
      spawn,
      readFile: async () => 'should-not-be-used',
      tmpDir,
      signal: controller.signal,
    });

    expect(result.status).toBe('aborted');
    expect(child.killed).toBe('SIGTERM');
    const errs = events.filter((e) => e.kind === 'error');
    expect(errs.length).toBe(1);
    expect(errs[0]).toMatchObject({ kind: 'error', retryable: false });
    expect((errs[0] as { message: string }).message).toMatch(/stopped/);
  });

  it('an already-aborted signal kills the child before it can complete', async () => {
    const { logger } = makeLogger();
    const { emit } = collect();
    const { spawn, child } = fakeSpawn({ stdoutChunks: [], stall: true });
    const controller = new AbortController();
    controller.abort(); // pre-aborted

    const result = await runCodexTurn({
      prompt: 'hi',
      cwd: '/tmp/ws',
      permMode: 'default',
      timeoutMs: 5_000,
      emit,
      logger,
      spawn,
      readFile: async () => '',
      tmpDir,
      signal: controller.signal,
    });

    expect(result.status).toBe('aborted');
    expect(child.killed).toBe('SIGTERM');
  });

  it('resumes with the session id and omits -a/-s/--cd in the spawned argv', async () => {
    const { logger } = makeLogger();
    const { emit } = collect();
    const { spawn, captured } = fakeSpawn({ stdoutChunks: [scriptedStdout()], exitCode: 0 });
    const result = await runCodexTurn({
      prompt: 'more',
      cwd: '/tmp/ws',
      permMode: 'bypassPermissions', // ignored on resume
      resumeId: 'thread-xyz',
      timeoutMs: 5_000,
      emit,
      logger,
      spawn,
      readFile: async () => 'resumed final',
      tmpDir,
    });
    expect(result.finalMessage).toBe('resumed final');
    expect(captured.args?.slice(0, 4)).toEqual(['exec', 'resume', '--json', 'thread-xyz']);
    expect(captured.args).not.toContain('-a');
    expect(captured.args).not.toContain('--cd');
  });
});
