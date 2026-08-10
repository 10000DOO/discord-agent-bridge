// Host-side Claude sidecar client (CLAUDE_SIDECAR_PROTOCOL.md).
// Speaks NDJSON over a duplex (injected streams or child_process stdio).
// Implements ModeSession for one sidecar session handle.

import { spawn, type ChildProcess } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import type { Readable, Writable } from 'node:stream';
import type {
  AgentEvent,
  ModeContext,
  ModeSession,
  PermissionDecision,
  ResumableSession,
  TurnInput,
} from '../../core/contracts.js';
import type { ShareResult } from '../../discord/documentShare.js';
import type { SendFileCallback, ShareDocumentCallback } from './mcpFileTool.js';
import {
  type Envelope,
  type SessionStartParams,
  type SessionStartResult,
  type SessionsListResult,
  makeError,
  parseEnvelope,
  req,
  res,
  resError,
  serializeEnvelope,
  PROTOCOL_VERSION,
} from '../../sidecar/claude/protocol.js';

/** Per-session host handlers for sidecar → host reverse RPC and events. */
export interface SidecarSessionHandlers {
  onEvent: (ev: AgentEvent) => void;
  onBackendId?: (id: string) => void;
  /** host.file.attach — returns confirmation string for the model. */
  onFileAttach?: (path: string, name?: string) => Promise<string>;
  /** host.file.share — returns ShareResult for the model-facing mapper. */
  onFileShare?: (path: string) => Promise<ShareResult>;
}

export interface SidecarTransport {
  /** Host → sidecar (sidecar stdin). */
  input: Writable;
  /** Sidecar → host (sidecar stdout). */
  output: Readable;
  /** Optional cleanup when the client closes (e.g. kill child). */
  dispose?: () => void | Promise<void>;
}

export interface ClaudeSidecarClientOptions {
  transport?: SidecarTransport;
  /** Spawn command when transport is omitted. Default: node + this package's cli. */
  spawnCommand?: string;
  spawnArgs?: string[];
  /** Reject pending RPCs after this many ms (default 60s). */
  requestTimeoutMs?: number;
}

/**
 * Resolve how to spawn the Claude sidecar process.
 * - `DAB_CLAUDE_SIDECAR_CMD` space-split override (e.g. `node /path/cli.js`)
 * - else `node dist/sidecar/claude/cli.js` when built
 * - else `node node_modules/tsx/... src/sidecar/claude/cli.ts` for dev
 */
export function resolveClaudeSidecarSpawn(
  env: NodeJS.ProcessEnv = process.env,
): { command: string; args: string[] } {
  const override = env.DAB_CLAUDE_SIDECAR_CMD?.trim();
  if (override && override.length > 0) {
    const parts = override.split(/\s+/).filter((p) => p.length > 0);
    const command = parts[0] ?? process.execPath;
    return { command, args: parts.slice(1) };
  }

  // modes/claude → package root is ../../..
  const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
  const distCli = path.join(packageRoot, 'dist', 'sidecar', 'claude', 'cli.js');
  if (fs.existsSync(distCli)) {
    return { command: process.execPath, args: [distCli] };
  }

  const srcCli = path.join(packageRoot, 'src', 'sidecar', 'claude', 'cli.ts');
  const tsxCli = path.join(packageRoot, 'node_modules', 'tsx', 'dist', 'cli.mjs');
  if (fs.existsSync(srcCli) && fs.existsSync(tsxCli)) {
    return { command: process.execPath, args: [tsxCli, srcCli] };
  }

  // Last resort: dist path (spawn will fail with ENOENT — clearer than silent wrong path).
  return { command: process.execPath, args: [distCli] };
}

interface PendingRpc {
  method: string;
  resolve: (result: unknown) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

let reqSeq = 0;
function nextId(): string {
  return `h-${++reqSeq}-${Date.now().toString(36)}`;
}

export class SidecarRpcError extends Error {
  readonly code: string;
  readonly retryable: boolean;

  constructor(code: string, message: string, retryable = false) {
    super(message);
    this.name = 'SidecarRpcError';
    this.code = code;
    this.retryable = retryable;
  }
}

/**
 * Low-level NDJSON client: request/response + event/notify multiplexing.
 * One client maps to one sidecar process (multi-session capable).
 */
export class ClaudeSidecarClient {
  private readonly transport: SidecarTransport;
  private readonly requestTimeoutMs: number;
  private readonly pending = new Map<string, PendingRpc>();
  private readonly sessionHandlers = new Map<string, SidecarSessionHandlers>();
  private rl: readline.Interface | null = null;
  private ready = false;
  private readyWaiters: Array<() => void> = [];
  private closed = false;
  private writeChain: Promise<void> = Promise.resolve();
  private child: ChildProcess | null = null;

  constructor(opts: ClaudeSidecarClientOptions = {}) {
    this.requestTimeoutMs = opts.requestTimeoutMs ?? 60_000;
    if (opts.transport) {
      this.transport = opts.transport;
    } else {
      const resolved = resolveClaudeSidecarSpawn();
      const command = opts.spawnCommand ?? resolved.command;
      const args = opts.spawnArgs ?? resolved.args;
      const child = spawn(command, args, {
        stdio: ['pipe', 'pipe', 'inherit'],
        env: process.env,
      });
      if (!child.stdin || !child.stdout) {
        throw new Error('Claude sidecar spawn did not provide stdin/stdout pipes');
      }
      this.child = child;
      const stdin = child.stdin;
      const stdout = child.stdout;
      this.transport = {
        input: stdin,
        output: stdout,
        dispose: () => {
          if (!child.killed) child.kill('SIGTERM');
        },
      };
    }
  }

  /** Begin reading sidecar stdout. Resolves when sidecar.ready is seen (or already). */
  async connect(): Promise<void> {
    if (this.rl) return this.waitReady();
    this.rl = readline.createInterface({
      input: this.transport.output,
      crlfDelay: Infinity,
    });
    this.rl.on('line', (line) => {
      void this.onLine(line);
    });
    this.rl.on('close', () => {
      this.failAll(new SidecarRpcError('internal', 'sidecar stdout closed'));
    });
    return this.waitReady();
  }

  private waitReady(): Promise<void> {
    if (this.ready) return Promise.resolve();
    return new Promise((resolve) => {
      this.readyWaiters.push(resolve);
    });
  }

  private markReady(): void {
    this.ready = true;
    const waiters = this.readyWaiters;
    this.readyWaiters = [];
    for (const w of waiters) w();
  }

  private onLine(line: string): void {
    if (typeof line !== 'string' || line.trim().length === 0) return;
    let env: Envelope;
    try {
      env = parseEnvelope(line);
    } catch {
      return;
    }

    if (env.type === 'notify' && env.method === 'sidecar.ready') {
      this.markReady();
      return;
    }

    if (env.type === 'notify' && env.method === 'session.backend_id') {
      const session = env.session;
      const backendSessionId = env.params?.backendSessionId;
      if (typeof session === 'string' && typeof backendSessionId === 'string') {
        this.sessionHandlers.get(session)?.onBackendId?.(backendSessionId);
      }
      return;
    }

    if (env.type === 'event' && typeof env.session === 'string' && env.event) {
      this.sessionHandlers.get(env.session)?.onEvent(env.event);
      return;
    }

    if (env.type === 'req') {
      // Reverse-RPC from sidecar (host.file.*). Slice1: reject as unsupported.
      void this.handleReverseRpc(env);
      return;
    }

    if (env.type === 'res' && typeof env.id === 'string') {
      const pending = this.pending.get(env.id);
      if (!pending) return;
      this.pending.delete(env.id);
      clearTimeout(pending.timer);
      if (env.error) {
        pending.reject(
          new SidecarRpcError(
            env.error.code,
            env.error.message,
            env.error.retryable === true,
          ),
        );
      } else {
        pending.resolve(env.result);
      }
    }
  }

  private async handleReverseRpc(env: Envelope): Promise<void> {
    const id = env.id;
    const method = env.method;
    if (typeof id !== 'string' || typeof method !== 'string') return;

    const session = typeof env.session === 'string' ? env.session : undefined;
    const handlers = session !== undefined ? this.sessionHandlers.get(session) : undefined;
    const params =
      env.params !== null && typeof env.params === 'object' && !Array.isArray(env.params)
        ? env.params
        : {};

    try {
      if (method === 'host.file.attach') {
        if (!handlers?.onFileAttach) {
          this.write(
            resError(
              id,
              method,
              makeError('unsupported', 'host.file.attach not wired for session'),
              session,
            ),
          );
          return;
        }
        const path = params.path;
        if (typeof path !== 'string' || path.length === 0) {
          this.write(
            resError(
              id,
              method,
              makeError('invalid_request', 'params.path required'),
              session,
            ),
          );
          return;
        }
        const name = typeof params.name === 'string' ? params.name : undefined;
        const message = await handlers.onFileAttach(path, name);
        this.write(res(id, method, { ok: true, message }, session));
        return;
      }

      if (method === 'host.file.share') {
        if (!handlers?.onFileShare) {
          this.write(
            resError(
              id,
              method,
              makeError('unsupported', 'host.file.share not wired for session'),
              session,
            ),
          );
          return;
        }
        const path = params.path;
        if (typeof path !== 'string' || path.length === 0) {
          this.write(
            resError(
              id,
              method,
              makeError('invalid_request', 'params.path required'),
              session,
            ),
          );
          return;
        }
        const shareResult = await handlers.onFileShare(path);
        this.write(res(id, method, shareResult, session));
        return;
      }

      this.write(
        resError(
          id,
          method,
          makeError('unsupported', `${method} not implemented on host`),
          session,
        ),
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.write(
        resError(id, method, makeError('internal', message), session),
      );
    }
  }

  private write(env: Envelope): void {
    const line = serializeEnvelope(env) + '\n';
    this.writeChain = this.writeChain.then(
      () =>
        new Promise<void>((resolve) => {
          if (this.closed) {
            resolve();
            return;
          }
          this.transport.input.write(line, () => resolve());
        }),
    );
  }

  async request(
    method: string,
    params?: Record<string, unknown>,
    session?: string,
  ): Promise<unknown> {
    await this.connect();
    const id = nextId();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new SidecarRpcError('internal', `RPC timeout: ${method}`, true));
      }, this.requestTimeoutMs);
      this.pending.set(id, { method, resolve, reject, timer });
      this.write(req(id, method, params, session));
    });
  }

  registerSessionHandlers(handle: string, handlers: SidecarSessionHandlers): void {
    this.sessionHandlers.set(handle, handlers);
  }

  unregisterSessionHandlers(handle: string): void {
    this.sessionHandlers.delete(handle);
  }

  async sessionStart(params: SessionStartParams): Promise<SessionStartResult> {
    const result = await this.request('session.start', params as unknown as Record<string, unknown>);
    return result as SessionStartResult;
  }

  async sessionResume(
    params: SessionStartParams & { backendSessionId: string },
  ): Promise<SessionStartResult> {
    const result = await this.request(
      'session.resume',
      params as unknown as Record<string, unknown>,
    );
    return result as SessionStartResult;
  }

  async sessionSend(
    handle: string,
    turn: TurnInput,
  ): Promise<void> {
    await this.request(
      'session.send',
      {
        session: handle,
        text: turn.text,
        ...(turn.files !== undefined ? { files: turn.files } : {}),
      },
      handle,
    );
  }

  async sessionStop(handle: string): Promise<void> {
    await this.request('session.stop', { session: handle }, handle);
  }

  async sessionInterrupt(handle: string): Promise<void> {
    await this.request('session.interrupt', { session: handle }, handle);
  }

  async sessionSetModel(handle: string, model?: string): Promise<void> {
    await this.request(
      'session.setModel',
      { session: handle, ...(model !== undefined ? { model } : {}) },
      handle,
    );
  }

  async sessionSetEffort(handle: string, effort?: string): Promise<void> {
    await this.request(
      'session.setEffort',
      { session: handle, ...(effort !== undefined ? { effort } : {}) },
      handle,
    );
  }

  async sessionPermission(
    handle: string,
    requestId: string,
    decision: PermissionDecision,
  ): Promise<void> {
    await this.request(
      'session.permission',
      {
        session: handle,
        requestId,
        behavior: decision.behavior,
        ...(decision.message !== undefined ? { message: decision.message } : {}),
      },
      handle,
    );
  }

  async sessionsList(cwd: string, limit?: number): Promise<ResumableSession[]> {
    const result = (await this.request('sessions.list', {
      cwd,
      ...(limit !== undefined ? { limit } : {}),
    })) as SessionsListResult;
    return result.sessions ?? [];
  }

  /**
   * Start (or resume) a sidecar session and return a ModeSession that forwards
   * events into `ctx` and round-trips permission_request via ctx.requestPermission.
   * Optional sendFile/shareDocument are registered as reverse-RPC handlers for
   * host.file.attach / host.file.share (MCP tools on the sidecar process).
   */
  async openModeSession(
    ctx: ModeContext,
    opts: {
      resumeId?: string;
      env?: Record<string, string | undefined>;
      sendFile?: SendFileCallback;
      shareDocument?: ShareDocumentCallback;
    } = {},
  ): Promise<ModeSession> {
    await this.connect();
    const startParams: SessionStartParams = {
      cwd: ctx.cwd,
      guildId: ctx.guildId,
      channelId: ctx.channelId,
      ownerId: ctx.ownerId,
      permMode: ctx.permMode,
      ...(ctx.model !== undefined ? { model: ctx.model } : {}),
      ...(ctx.effort !== undefined ? { effort: ctx.effort } : {}),
      config: {
        ...(ctx.config.allowedTools !== undefined
          ? { allowedTools: ctx.config.allowedTools }
          : {}),
        ...(ctx.config.autoAllowClaudeTools !== undefined
          ? { autoAllowClaudeTools: ctx.config.autoAllowClaudeTools }
          : {}),
        ...(ctx.config.permissionTimeoutSec !== undefined
          ? { permissionTimeoutSec: ctx.config.permissionTimeoutSec }
          : {}),
      },
      ...(opts.env !== undefined ? { env: opts.env } : {}),
    };

    const started =
      opts.resumeId !== undefined
        ? await this.sessionResume({ ...startParams, backendSessionId: opts.resumeId })
        : await this.sessionStart(startParams);

    return new SidecarModeSession(this, ctx, started.session, started.backendSessionId, {
      ...(opts.sendFile !== undefined ? { sendFile: opts.sendFile } : {}),
      ...(opts.shareDocument !== undefined ? { shareDocument: opts.shareDocument } : {}),
    });
  }

  private failAll(err: Error): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.failAll(new SidecarRpcError('internal', 'client closed'));
    this.rl?.close();
    this.rl = null;
    try {
      await this.transport.dispose?.();
    } catch {
      // ignore dispose errors
    }
    if (this.child && !this.child.killed) {
      this.child.kill('SIGTERM');
    }
  }
}

/** ModeSession backed by a sidecar session handle. */
export class SidecarModeSession implements ModeSession {
  sessionId: string | null;
  private readonly client: ClaudeSidecarClient;
  private readonly ctx: ModeContext;
  private readonly handle: string;
  private closed = false;

  constructor(
    client: ClaudeSidecarClient,
    ctx: ModeContext,
    handle: string,
    backendSessionId: string | null,
    fileCbs: {
      sendFile?: SendFileCallback;
      shareDocument?: ShareDocumentCallback;
    } = {},
  ) {
    this.client = client;
    this.ctx = ctx;
    this.handle = handle;
    this.sessionId = backendSessionId;

    client.registerSessionHandlers(handle, {
      onEvent: (ev) => this.onEvent(ev),
      onBackendId: (id) => {
        const first = this.sessionId === null;
        this.sessionId = id;
        if (first) this.ctx.onSessionIdReady?.(id);
      },
      ...(fileCbs.sendFile !== undefined
        ? {
            onFileAttach: async (path: string, name?: string) =>
              fileCbs.sendFile!(path, name),
          }
        : {}),
      ...(fileCbs.shareDocument !== undefined
        ? {
            onFileShare: async (path: string) => fileCbs.shareDocument!(path),
          }
        : {}),
    });
    // start/resume may already know the backend id; notify host without waiting for
    // a later session.backend_id (which can race before handlers are registered).
    if (backendSessionId) {
      this.ctx.onSessionIdReady?.(backendSessionId);
    }
  }

  private onEvent(ev: AgentEvent): void {
    if (this.closed) return;
    if (ev.kind === 'permission_request') {
      // Host resolves via Discord buttons (or test double); answer the sidecar.
      void this.ctx
        .requestPermission({ toolName: ev.toolName, input: ev.input })
        .then((decision) => this.client.sessionPermission(this.handle, ev.id, decision))
        .catch(async () => {
          try {
            await this.client.sessionPermission(this.handle, ev.id, {
              behavior: 'deny',
              message: 'Host permission failed.',
            });
          } catch {
            // sidecar may already be gone
          }
        });
      // Do not also emit: wiring.requestPermission owns the UI path.
      return;
    }
    this.ctx.emit(ev);
  }

  async send(turn: TurnInput): Promise<void> {
    if (this.closed) throw new Error('Sidecar session is closed.');
    await this.client.sessionSend(this.handle, turn);
  }

  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.client.unregisterSessionHandlers(this.handle);
    try {
      await this.client.sessionStop(this.handle);
    } catch {
      // stop is best-effort on a dead sidecar
    }
  }

  async interrupt(): Promise<void> {
    if (this.closed) return;
    await this.client.sessionInterrupt(this.handle);
  }

  async setModel(model?: string): Promise<void> {
    if (this.closed) throw new Error('Sidecar session is closed.');
    await this.client.sessionSetModel(this.handle, model);
  }

  async setEffort(effort?: string): Promise<void> {
    if (this.closed) throw new Error('Sidecar session is closed.');
    await this.client.sessionSetEffort(this.handle, effort);
  }
}

/** Whether the process should prefer the Claude sidecar (opt-in). */
export function isClaudeSidecarEnabled(
  env: NodeJS.ProcessEnv = process.env,
): boolean {
  return env.DAB_CLAUDE_SIDECAR === '1' || env.DAB_CLAUDE_SIDECAR === 'true';
}

export { PROTOCOL_VERSION };
