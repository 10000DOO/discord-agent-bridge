// NDJSON stdin/stdout loop for the Claude sidecar (CLAUDE_SIDECAR_PROTOCOL.md).

import * as readline from 'node:readline';
import type { Readable, Writable } from 'node:stream';
import type { Logger } from '../../core/contracts.js';
import {
  type Envelope,
  type SessionResumeParams,
  type SessionStartParams,
  makeError,
  notify,
  parseEnvelope,
  ProtocolParseError,
  req,
  res,
  resError,
  serializeEnvelope,
} from './protocol.js';
import {
  SessionBridge,
  type SessionFactory,
  type SessionBridgeDeps,
} from './sessionBridge.js';
import type { ListSessionsFn } from '../../modes/claude/index.js';

export interface SidecarServerDeps {
  input: Readable;
  output: Writable;
  createSession?: SessionFactory;
  listSessionsFn?: ListSessionsFn;
  logger?: Logger;
  /** When true (default), emit sidecar.ready on start. */
  announceReady?: boolean;
  /** Reject reverse-RPC (host.file.*) after this many ms (default 60s). */
  reverseTimeoutMs?: number;
}

interface ReversePending {
  method: string;
  resolve: (result: unknown) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

let reverseSeq = 0;
function nextReverseId(): string {
  return `r-${++reverseSeq}-${Date.now().toString(36)}`;
}

const stderrLogger: Logger = {
  debug(msg, ...meta) {
    console.error('[sidecar:debug]', msg, ...meta);
  },
  info(msg, ...meta) {
    console.error('[sidecar:info]', msg, ...meta);
  },
  warn(msg, ...meta) {
    console.error('[sidecar:warn]', msg, ...meta);
  },
  error(msg, ...meta) {
    console.error('[sidecar:error]', msg, ...meta);
  },
};

function asRecord(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : {};
}

function requireString(params: Record<string, unknown>, key: string): string {
  const v = params[key];
  if (typeof v !== 'string' || v.length === 0) {
    throw Object.assign(new Error(`missing or invalid params.${key}`), {
      code: 'invalid_request',
    });
  }
  return v;
}

function optionalString(params: Record<string, unknown>, key: string): string | undefined {
  const v = params[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') {
    throw Object.assign(new Error(`invalid params.${key}`), { code: 'invalid_request' });
  }
  return v;
}

function sessionHandle(env: Envelope, params: Record<string, unknown>): string {
  const fromParams = optionalString(params, 'session');
  if (fromParams) return fromParams;
  if (typeof env.session === 'string' && env.session.length > 0) return env.session;
  throw Object.assign(new Error('missing session handle'), { code: 'invalid_request' });
}

function parseStartParams(params: Record<string, unknown>): SessionStartParams {
  const configRaw = params.config;
  let config: SessionStartParams['config'];
  if (configRaw !== undefined && configRaw !== null) {
    if (typeof configRaw !== 'object' || Array.isArray(configRaw)) {
      throw Object.assign(new Error('invalid params.config'), { code: 'invalid_request' });
    }
    const c = configRaw as Record<string, unknown>;
    config = {
      ...(Array.isArray(c.allowedTools)
        ? { allowedTools: c.allowedTools.filter((t): t is string => typeof t === 'string') }
        : {}),
      ...(Array.isArray(c.autoAllowClaudeTools)
        ? {
            autoAllowClaudeTools: c.autoAllowClaudeTools.filter(
              (t): t is string => typeof t === 'string',
            ),
          }
        : {}),
      ...(typeof c.permissionTimeoutSec === 'number'
        ? { permissionTimeoutSec: c.permissionTimeoutSec }
        : {}),
    };
  }
  const envRaw = params.env;
  let env: SessionStartParams['env'];
  if (envRaw !== undefined && envRaw !== null) {
    if (typeof envRaw !== 'object' || Array.isArray(envRaw)) {
      throw Object.assign(new Error('invalid params.env'), { code: 'invalid_request' });
    }
    env = envRaw as Record<string, string | undefined>;
  }
  return {
    cwd: requireString(params, 'cwd'),
    guildId: requireString(params, 'guildId'),
    channelId: requireString(params, 'channelId'),
    ...(optionalString(params, 'ownerId') !== undefined
      ? { ownerId: optionalString(params, 'ownerId') }
      : {}),
    ...(optionalString(params, 'model') !== undefined
      ? { model: optionalString(params, 'model') }
      : {}),
    ...(optionalString(params, 'effort') !== undefined
      ? { effort: optionalString(params, 'effort') }
      : {}),
    permMode: requireString(params, 'permMode'),
    ...(config !== undefined ? { config } : {}),
    ...(env !== undefined ? { env } : {}),
  };
}

export class SidecarServer {
  private readonly input: Readable;
  private readonly output: Writable;
  private readonly bridge: SessionBridge;
  private readonly logger: Logger;
  private readonly announceReady: boolean;
  private readonly reverseTimeoutMs: number;
  private readonly reversePending = new Map<string, ReversePending>();
  private rl: readline.Interface | null = null;
  private closed = false;
  private writeChain: Promise<void> = Promise.resolve();
  /** In-flight request handlers — send may return while permission waits; do not serialize. */
  private readonly inflight = new Set<Promise<void>>();

  constructor(deps: SidecarServerDeps) {
    this.input = deps.input;
    this.output = deps.output;
    this.logger = deps.logger ?? stderrLogger;
    this.announceReady = deps.announceReady !== false;
    this.reverseTimeoutMs = deps.reverseTimeoutMs ?? 60_000;
    const bridgeDeps: SessionBridgeDeps = {
      write: (env) => this.write(env),
      requestHost: (method, params, session) => this.requestHost(method, params, session),
      ...(deps.createSession !== undefined ? { createSession: deps.createSession } : {}),
      ...(deps.listSessionsFn !== undefined ? { listSessionsFn: deps.listSessionsFn } : {}),
      logger: this.logger,
    };
    this.bridge = new SessionBridge(bridgeDeps);
  }

  /**
   * Sidecar → Host reverse RPC (CLAUDE_SIDECAR_PROTOCOL.md §3.8).
   * Writes a `req` and waits for a matching host `res`.
   */
  requestHost(
    method: string,
    params?: Record<string, unknown>,
    session?: string,
  ): Promise<unknown> {
    if (this.closed) {
      return Promise.reject(
        Object.assign(new Error('sidecar closed'), { code: 'internal' }),
      );
    }
    const id = nextReverseId();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.reversePending.delete(id);
        reject(
          Object.assign(new Error(`reverse RPC timeout: ${method}`), {
            code: 'internal',
          }),
        );
      }, this.reverseTimeoutMs);
      this.reversePending.set(id, { method, resolve, reject, timer });
      this.write(req(id, method, params, session));
    });
  }

  /** Start the readline loop. Resolves when stdin ends (or stop() is called). */
  async run(): Promise<void> {
    if (this.announceReady) {
      this.write(notify('sidecar.ready', { v: 1 }));
    }

    this.rl = readline.createInterface({ input: this.input, crlfDelay: Infinity });
    // Concurrent dispatch: session.send may park on canUseTool while host answers
    // session.permission on another line. Awaiting each line would deadlock §5.
    for await (const line of this.rl) {
      if (this.closed) break;
      if (typeof line !== 'string' || line.trim().length === 0) continue;
      const p = this.handleLine(line).catch((err) => {
        this.logger.warn('handleLine failed', { err: String(err) });
      });
      this.inflight.add(p);
      void p.finally(() => this.inflight.delete(p));
    }

    await Promise.all([...this.inflight]);
    await this.shutdown('stdin_eof');
  }

  async stop(): Promise<void> {
    await this.shutdown('stop');
  }

  private async shutdown(reason: string): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.write(notify('sidecar.shutdown', { reason }));
    for (const [, p] of this.reversePending) {
      clearTimeout(p.timer);
      p.reject(Object.assign(new Error('sidecar shutdown'), { code: 'internal' }));
    }
    this.reversePending.clear();
    try {
      await this.bridge.stopAll();
    } catch (err) {
      this.logger.warn('stopAll failed', { err: String(err) });
    }
    this.rl?.close();
    this.rl = null;
  }

  private write(env: Envelope): void {
    const line = serializeEnvelope(env) + '\n';
    // Serialize writes so concurrent events do not interleave bytes.
    this.writeChain = this.writeChain.then(
      () =>
        new Promise<void>((resolve) => {
          if (this.closed && env.type !== 'notify') {
            resolve();
            return;
          }
          this.output.write(line, (err) => {
            if (err) this.logger.warn('write failed', { err: String(err) });
            resolve();
          });
        }),
    );
  }

  private async handleLine(line: string): Promise<void> {
    let env: Envelope;
    try {
      env = parseEnvelope(line);
    } catch (err) {
      const message = err instanceof ProtocolParseError ? err.message : String(err);
      this.logger.warn('parse error', { message, line: line.slice(0, 200) });
      // No id to reply to for a corrupt line.
      return;
    }

    if (env.type === 'res') {
      // Host responses to reverse-RPC (host.file.attach / host.file.share).
      if (typeof env.id !== 'string' || env.id.length === 0) return;
      const pending = this.reversePending.get(env.id);
      if (!pending) {
        this.logger.debug('host res with no pending reverse RPC', {
          id: env.id,
          method: env.method,
        });
        return;
      }
      this.reversePending.delete(env.id);
      clearTimeout(pending.timer);
      if (env.error) {
        pending.reject(
          Object.assign(new Error(env.error.message), {
            code: env.error.code,
            retryable: env.error.retryable === true,
          }),
        );
      } else {
        pending.resolve(env.result);
      }
      return;
    }

    if (env.type !== 'req') {
      this.logger.debug('ignoring non-req', { type: env.type });
      return;
    }

    const id = env.id;
    const method = env.method;
    if (typeof id !== 'string' || id.length === 0 || typeof method !== 'string') {
      return;
    }

    try {
      const result = await this.dispatch(env, method);
      this.write(res(id, method, result, typeof env.session === 'string' ? env.session : undefined));
    } catch (err) {
      const code =
        err && typeof err === 'object' && 'code' in err && typeof (err as { code: unknown }).code === 'string'
          ? (err as { code: string }).code
          : 'internal';
      const message = err instanceof Error ? err.message : String(err);
      const retryable = code === 'sdk_error';
      this.write(
        resError(
          id,
          method,
          makeError(code, message, retryable),
          typeof env.session === 'string' ? env.session : undefined,
        ),
      );
    }
  }

  private async dispatch(env: Envelope, method: string): Promise<unknown> {
    const params = asRecord(env.params);

    switch (method) {
      case 'session.start': {
        const start = parseStartParams(params);
        return this.bridge.start(start);
      }
      case 'session.resume': {
        const start = parseStartParams(params);
        const backendSessionId = requireString(params, 'backendSessionId');
        const resume: SessionResumeParams = { ...start, backendSessionId };
        return this.bridge.resume(resume);
      }
      case 'session.send': {
        const handle = sessionHandle(env, params);
        const text = requireString(params, 'text');
        const filesRaw = params.files;
        let files: { path: string; mime?: string }[] | undefined;
        if (Array.isArray(filesRaw)) {
          files = filesRaw
            .filter((f): f is Record<string, unknown> => f !== null && typeof f === 'object')
            .map((f) => ({
              path: String(f.path ?? ''),
              ...(typeof f.mime === 'string' ? { mime: f.mime } : {}),
            }))
            .filter((f) => f.path.length > 0);
        }
        await this.bridge.send(handle, text, files);
        return { ok: true };
      }
      case 'session.stop': {
        const handle = sessionHandle(env, params);
        await this.bridge.stop(handle);
        return { ok: true };
      }
      case 'session.interrupt': {
        const handle = sessionHandle(env, params);
        await this.bridge.interrupt(handle);
        return { ok: true };
      }
      case 'session.setModel': {
        const handle = sessionHandle(env, params);
        await this.bridge.setModel(handle, optionalString(params, 'model'));
        return { ok: true };
      }
      case 'session.setEffort': {
        const handle = sessionHandle(env, params);
        await this.bridge.setEffort(handle, optionalString(params, 'effort'));
        return { ok: true };
      }
      case 'session.permission': {
        const handle = sessionHandle(env, params);
        const requestId = requireString(params, 'requestId');
        const behavior = requireString(params, 'behavior');
        if (behavior !== 'allow' && behavior !== 'deny') {
          throw Object.assign(new Error('behavior must be allow|deny'), {
            code: 'invalid_request',
          });
        }
        const message = optionalString(params, 'message');
        this.bridge.resolvePermission(handle, requestId, {
          behavior,
          ...(message !== undefined ? { message } : {}),
        });
        return { ok: true };
      }
      case 'sessions.list': {
        const cwd = requireString(params, 'cwd');
        const limit =
          typeof params.limit === 'number' && Number.isFinite(params.limit)
            ? params.limit
            : undefined;
        return this.bridge.listSessions(cwd, limit);
      }
      case 'host.file.attach':
      case 'host.file.share':
        // Reverse-RPC is Host-bound; if Host sends these, reject.
        throw Object.assign(new Error(`${method} is host-bound reverse RPC`), {
          code: 'unsupported',
        });
      default:
        throw Object.assign(new Error(`unknown method: ${method}`), {
          code: 'unsupported',
        });
    }
  }
}
