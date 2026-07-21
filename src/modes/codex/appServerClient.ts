import { spawn as realSpawn } from 'node:child_process';
import type { Logger } from '../../core/contracts.js';
import { redactString } from '../../core/logger.js';

// Long-lived JSON-RPC client over one `codex app-server` child (stdio).
// Wire (codex 0.143.0, measured): newline-delimited JSON; responses/notifications may
// OMIT `"jsonrpc":"2.0"` (only `id`/`result` or `method`/`params`). Requests may include
// jsonrpc. Server→client requests (approval) carry method+id and must be answered.

// ---- Injectable child-process seam ----------------------------------------------------------

export interface AppServerSpawnedProcess {
  stdin: NodeJS.WritableStream | null;
  stdout: NodeJS.ReadableStream | null;
  stderr: NodeJS.ReadableStream | null;
  on(event: 'error', listener: (err: Error) => void): void;
  on(event: 'close', listener: (code: number | null, signal: NodeJS.Signals | null) => void): void;
  kill(signal?: NodeJS.Signals): boolean;
}

export type AppServerSpawnFn = (
  command: string,
  args: readonly string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; stdio?: import('node:child_process').StdioOptions },
) => AppServerSpawnedProcess;

// Decision returned to app-server for requestApproval methods (spike: accept / decline).
export type AppServerApprovalDecision = 'accept' | 'decline' | 'acceptForSession';

export interface AppServerApprovalRequest {
  requestId: number | string;
  method: string;
  params: unknown;
}

export type NotificationHandler = (method: string, params: unknown) => void;
export type ApprovalHandler = (req: AppServerApprovalRequest) => Promise<AppServerApprovalDecision>;

// Dynamic tool (attach_file etc.) server→client request params (schema DynamicToolCallParams).
export interface DynamicToolCallParams {
  tool: string;
  arguments: unknown;
  callId: string;
  threadId: string;
  turnId: string;
  namespace?: string;
}

export interface DynamicToolCallResult {
  success: boolean;
  contentItems: Array<{ type: 'inputText'; text: string } | { type: 'inputImage'; imageUrl: string }>;
}

export type DynamicToolCallHandler = (params: DynamicToolCallParams) => Promise<DynamicToolCallResult>;

// Function-shaped dynamic tool registered on thread/start (schema FunctionDynamicToolSpec).
export interface DynamicToolSpec {
  type: 'function';
  name: string;
  description: string;
  inputSchema: unknown;
  deferLoading?: boolean;
}

export interface CodexAppServerClientOptions {
  logger: Logger;
  cwd?: string;
  codexCommand?: string; // defaults to 'codex'
  codexHome?: string; // sets CODEX_HOME for the child
  env?: NodeJS.ProcessEnv;
  requestTimeoutMs?: number; // per control-request timeout (not turn wall-clock)
  spawn?: AppServerSpawnFn;
  // When the server asks for approval; without a handler, auto-accept so the agent never hangs.
  onApproval?: ApprovalHandler;
  // Dynamic tools (item/tool/call). Without a handler, respond success:false so the agent never hangs.
  onDynamicToolCall?: DynamicToolCallHandler;
}

export interface ThreadStartParams {
  cwd: string;
  approvalPolicy: string;
  sandbox: string;
  model?: string;
  dynamicTools?: DynamicToolSpec[];
  [key: string]: unknown;
}

export interface ThreadResumeParams {
  threadId: string;
  [key: string]: unknown;
}

export interface TurnStartParams {
  threadId: string;
  input: Array<{ type: string; text?: string; [key: string]: unknown }>;
  effort?: string;
  model?: string;
  [key: string]: unknown;
}

export interface TurnInterruptParams {
  threadId: string;
  turnId: string;
}

const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;
const STDERR_CAPTURE_CAP = 8 * 1024;
const STDERR_TAIL_CHARS = 500;

const NOT_INSTALLED_MESSAGE = '`codex` CLI를 찾을 수 없습니다. 설치 여부와 PATH를 확인하세요.';
const AUTH_FAILURE_RE = /\bnot authenticated\b|please log in|codex login|\bunauthorized\b|\bauthenticat/i;
const LOGIN_MESSAGE = 'Codex에 로그인되어 있지 않습니다. 터미널에서 `codex login`을 실행한 뒤 다시 시도하세요.';

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
}

export class CodexAppServerClient {
  private readonly logger: Logger;
  private readonly child: AppServerSpawnedProcess;
  private readonly requestTimeoutMs: number;
  private readonly approvalHandler: ApprovalHandler | null;
  private readonly dynamicToolHandler: DynamicToolCallHandler | null;

  private nextId = 1;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly notificationHandlers: NotificationHandler[] = [];

  private lineBuffer = '';
  private stderrBuf = '';
  private closed = false;
  private initializeResultValue: unknown = null;

  constructor(options: CodexAppServerClientOptions) {
    this.logger = options.logger;
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    this.approvalHandler = options.onApproval ?? null;
    this.dynamicToolHandler = options.onDynamicToolCall ?? null;

    const spawn = options.spawn ?? (realSpawn as unknown as AppServerSpawnFn);
    const codexCommand = options.codexCommand ?? 'codex';
    const args = ['app-server'];

    this.child = spawn(codexCommand, args, {
      ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
      env: {
        ...process.env,
        ...(options.env ?? {}),
        ...(options.codexHome ? { CODEX_HOME: options.codexHome } : {}),
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    this.child.stdout?.on('data', (chunk: Buffer | string) => this.onStdout(chunk));
    this.child.stderr?.on('data', (chunk: Buffer | string) => {
      this.stderrBuf += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
      if (this.stderrBuf.length > STDERR_CAPTURE_CAP) this.stderrBuf = this.stderrBuf.slice(-STDERR_CAPTURE_CAP);
    });
    this.child.on('error', (err) => this.onChildError(err));
    this.child.on('close', (code, signal) => this.onChildClose(code, signal));
  }

  get initializeResult(): unknown {
    return this.initializeResultValue;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  // Multicast notification subscription. Returns an unsubscribe function.
  onNotification(handler: NotificationHandler): () => void {
    this.notificationHandlers.push(handler);
    return () => {
      const i = this.notificationHandlers.indexOf(handler);
      if (i >= 0) this.notificationHandlers.splice(i, 1);
    };
  }

  async initialize(clientInfo?: { name?: string; version?: string }): Promise<unknown> {
    const result = await this.request('initialize', {
      clientInfo: {
        name: clientInfo?.name ?? 'discord-agent-bridge',
        version: clientInfo?.version ?? '0.0.0',
      },
      capabilities: { experimentalApi: true },
    });
    this.initializeResultValue = result;
    return result;
  }

  // Returns the thread id from result.thread.id.
  async threadStart(params: ThreadStartParams): Promise<string> {
    const result = await this.request('thread/start', params);
    const id = extractThreadId(result);
    if (id === null) throw new Error('codex app-server: thread/start returned no thread.id.');
    return id;
  }

  async threadResume(params: ThreadResumeParams): Promise<unknown> {
    return this.request('thread/resume', params);
  }

  // Returns the turn id from result.turn.id (or result.id when nested shape varies).
  async turnStart(params: TurnStartParams): Promise<string> {
    const result = await this.request('turn/start', params);
    const id = extractTurnId(result);
    if (id === null) throw new Error('codex app-server: turn/start returned no turn.id.');
    return id;
  }

  async turnInterrupt(params: TurnInterruptParams): Promise<unknown> {
    return this.request('turn/interrupt', params);
  }

  // Low-level request/response. Response may omit jsonrpc (spike).
  request(method: string, params?: unknown): Promise<unknown> {
    if (this.closed) return Promise.reject(new Error('Codex app-server client is closed.'));
    const id = this.nextId++;
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) {
          reject(new Error(`codex app-server: ${method} timed out after ${this.requestTimeoutMs}ms.`));
        }
      }, this.requestTimeoutMs);
      timer.unref?.();
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (err) => {
          clearTimeout(timer);
          reject(err);
        },
      });
      const msg: Record<string, unknown> = { jsonrpc: '2.0', id, method };
      if (params !== undefined) msg.params = params;
      this.write(msg);
    });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    try {
      this.child.stdin?.end();
    } catch {
      // ignore
    }
    this.child.kill('SIGTERM');
    this.rejectInFlight(new Error('Codex app-server client was closed.'));
  }

  // ---- Transport internals ------------------------------------------------------------------

  private write(msg: Record<string, unknown>): void {
    const stdin = this.child.stdin;
    if (!stdin) return;
    stdin.write(JSON.stringify(msg) + '\n');
  }

  private onStdout(chunk: Buffer | string): void {
    this.lineBuffer += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    const lines = this.lineBuffer.split(/\r?\n/);
    this.lineBuffer = lines.pop() ?? '';
    for (const line of lines) this.onLine(line);
  }

  private onLine(line: string): void {
    const trimmed = line.trim();
    if (trimmed.length === 0) return;
    let msg: unknown;
    try {
      msg = JSON.parse(trimmed);
    } catch {
      this.logger.debug('codex app-server: skipping non-JSON stdout line', { preview: trimmed.slice(0, 120) });
      return;
    }
    if (!isObject(msg)) {
      this.logger.debug('codex app-server: skipping non-object message');
      return;
    }

    const rawId = msg.id;
    const id = typeof rawId === 'number' || typeof rawId === 'string' ? rawId : undefined;
    const method = typeof msg.method === 'string' ? msg.method : undefined;
    const hasResult = 'result' in msg;
    const hasError = 'error' in msg;

    // (1) Response: id + result/error, no method. jsonrpc optional (spike).
    if (id !== undefined && method === undefined && (hasResult || hasError)) {
      this.handleResponse(id, msg);
      return;
    }
    // (2) Server→client request: id + method (approvals).
    if (id !== undefined && method !== undefined) {
      void this.handleServerRequest(id, method, msg);
      return;
    }
    // (3) Notification: method, no id.
    if (id === undefined && method !== undefined) {
      this.dispatchNotification(method, msg.params);
      return;
    }
    this.logger.debug('codex app-server: skipping unclassifiable message', {
      hasId: id !== undefined,
      hasMethod: method !== undefined,
    });
  }

  private handleResponse(id: number | string, msg: Record<string, unknown>): void {
    if (typeof id !== 'number') {
      this.logger.debug('codex app-server: response for non-numeric id', { id });
      return;
    }
    const pending = this.pending.get(id);
    if (!pending) {
      this.logger.debug('codex app-server: response for unknown id', { id });
      return;
    }
    this.pending.delete(id);
    if (msg.error !== undefined) pending.reject(new Error(formatRpcError(msg.error)));
    else pending.resolve(msg.result);
  }

  private async handleServerRequest(id: number | string, method: string, msg: Record<string, unknown>): Promise<void> {
    if (isApprovalMethod(method)) {
      const decision = await this.resolveApproval({ requestId: id, method, params: msg.params });
      if (this.closed) return;
      this.write({ id, result: { decision } });
      return;
    }
    if (method === 'item/tool/call') {
      const result = await this.resolveDynamicToolCall(msg.params);
      if (this.closed) return;
      this.write({ id, result });
      return;
    }
    this.logger.debug('codex app-server: unhandled server request', { method });
    this.write({ id, error: { code: -32601, message: `Method not found: ${method}` } });
  }

  private async resolveDynamicToolCall(params: unknown): Promise<DynamicToolCallResult> {
    const parsed = parseDynamicToolCallParams(params);
    if (!parsed) {
      return {
        success: false,
        contentItems: [{ type: 'inputText', text: 'Invalid item/tool/call params.' }],
      };
    }
    if (!this.dynamicToolHandler) {
      return {
        success: false,
        contentItems: [{ type: 'inputText', text: `No handler for dynamic tool "${parsed.tool}".` }],
      };
    }
    try {
      return await this.dynamicToolHandler(parsed);
    } catch (err) {
      this.logger.debug('codex app-server: dynamic tool handler threw', {
        tool: parsed.tool,
        error: err instanceof Error ? err.message : String(err),
      });
      return {
        success: false,
        contentItems: [
          {
            type: 'inputText',
            text: `Dynamic tool failed: ${err instanceof Error ? err.message : String(err)}`,
          },
        ],
      };
    }
  }

  private async resolveApproval(req: AppServerApprovalRequest): Promise<AppServerApprovalDecision> {
    if (!this.approvalHandler) return 'accept';
    try {
      return await this.approvalHandler(req);
    } catch (err) {
      this.logger.debug('codex app-server: approval handler threw; declining', {
        error: err instanceof Error ? err.message : String(err),
      });
      return 'decline';
    }
  }

  private dispatchNotification(method: string, params: unknown): void {
    for (const h of this.notificationHandlers) {
      try {
        h(method, params);
      } catch (err) {
        this.logger.debug('codex app-server: notification handler threw', {
          method,
          error: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }

  private onChildError(err: Error): void {
    if (this.closed) return;
    this.closed = true;
    const code = (err as NodeJS.ErrnoException).code;
    const message = classifyFailure(err.message, code) ?? redactString(err.message);
    this.rejectInFlight(new Error(message));
  }

  private onChildClose(code: number | null, signal: NodeJS.Signals | null): void {
    if (this.closed) return;
    this.closed = true;
    this.rejectInFlight(this.buildExitError(code, signal));
  }

  private buildExitError(code: number | null, signal: NodeJS.Signals | null): Error {
    const actionable = classifyFailure(this.stderrBuf);
    if (actionable) return new Error(actionable);
    const tail = redactString(stderrTail(this.stderrBuf));
    const suffix = tail.length > 0 ? ` ${tail}` : '';
    const codeStr = code === null ? `signal ${signal ?? 'unknown'}` : `code ${code}`;
    return new Error(`codex app-server exited unexpectedly (${codeStr}).${suffix}`);
  }

  private rejectInFlight(err: Error): void {
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
  }
}

// ---- Pure helpers ---------------------------------------------------------------------------

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isApprovalMethod(method: string): boolean {
  return method.includes('requestApproval') || /Approval$/i.test(method);
}

function parseDynamicToolCallParams(params: unknown): DynamicToolCallParams | null {
  if (!isObject(params)) return null;
  const tool = typeof params.tool === 'string' ? params.tool : undefined;
  const callId = typeof params.callId === 'string' ? params.callId : undefined;
  const threadId = typeof params.threadId === 'string' ? params.threadId : undefined;
  const turnId = typeof params.turnId === 'string' ? params.turnId : undefined;
  if (!tool || !callId || !threadId || !turnId) return null;
  const out: DynamicToolCallParams = {
    tool,
    arguments: params.arguments,
    callId,
    threadId,
    turnId,
  };
  if (typeof params.namespace === 'string') out.namespace = params.namespace;
  return out;
}

function extractThreadId(result: unknown): string | null {
  if (!isObject(result)) return null;
  const thread = isObject(result.thread) ? result.thread : null;
  if (thread && typeof thread.id === 'string' && thread.id.length > 0) return thread.id;
  if (typeof result.threadId === 'string' && result.threadId.length > 0) return result.threadId;
  if (typeof result.id === 'string' && result.id.length > 0) return result.id;
  return null;
}

function extractTurnId(result: unknown): string | null {
  if (!isObject(result)) return null;
  const turn = isObject(result.turn) ? result.turn : null;
  if (turn && typeof turn.id === 'string' && turn.id.length > 0) return turn.id;
  if (typeof result.turnId === 'string' && result.turnId.length > 0) return result.turnId;
  if (typeof result.id === 'string' && result.id.length > 0) return result.id;
  return null;
}

function formatRpcError(error: unknown): string {
  if (isObject(error)) {
    const code = typeof error.code === 'number' ? error.code : 'unknown';
    const message = typeof error.message === 'string' ? redactString(error.message) : 'unknown error';
    return `codex app-server error ${code}: ${message}`;
  }
  return `codex app-server error: ${redactString(String(error))}`;
}

function classifyFailure(text: string, code?: string): string | undefined {
  if (code === 'ENOENT' || /\bENOENT\b/.test(text)) return NOT_INSTALLED_MESSAGE;
  if (AUTH_FAILURE_RE.test(text)) return LOGIN_MESSAGE;
  return undefined;
}

function stderrTail(stderr: string): string {
  const trimmed = stderr.trim();
  return trimmed.length > STDERR_TAIL_CHARS ? `…${trimmed.slice(-STDERR_TAIL_CHARS)}` : trimmed;
}
