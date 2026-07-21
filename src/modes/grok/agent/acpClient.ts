import { spawn as realSpawn } from 'node:child_process';
import type { Logger, PermissionDecision } from '../../../core/contracts.js';
import { redactString } from '../../../core/logger.js';
import { isGrokModel as defaultIsGrokModel } from '../catalog.js';

// The path-B ACP transport (WO-8): a BIDIRECTIONAL JSON-RPC 2.0 client over ONE long-lived
// `grok agent stdio` child (15-agent-mode.md). Unlike path A's per-turn `grok -p` (runner.ts),
// this process persists for the whole conversation: initialize → session/new → session/prompt…
//
// The doc's TS example (15-agent-mode.md:188-275) is NAIVE — a fixed id=1, a `rl.once` per
// request, and no handling of server→client requests. This client is correct instead: a
// monotonic request id with a pending-request map, notifications (session/update) dispatched to
// the active prompt stream, and server→client requests (tool-permission asks) answered with a
// JSON-RPC response carrying the SAME id. Every external touchpoint — the spawn, the model-known
// predicate — is injectable so the whole client runs under test against a MOCK stdio with no real
// `grok` process. Mirrors the spawn/line-buffer/stderr idioms of modes/grok/runner.ts.

// ---- Injectable child-process seam (mirrors runner.ts's SpawnFn/SpawnedProcess, plus stdin,
// which path B needs to write requests — runner.ts ignores stdin) -------------------------------
export interface AcpSpawnedProcess {
  stdin: NodeJS.WritableStream | null;
  stdout: NodeJS.ReadableStream | null;
  stderr: NodeJS.ReadableStream | null;
  on(event: 'error', listener: (err: Error) => void): void;
  on(event: 'close', listener: (code: number | null, signal: NodeJS.Signals | null) => void): void;
  kill(signal?: NodeJS.Signals): boolean;
}

export type AcpSpawnFn = (
  command: string,
  args: readonly string[],
  options: { cwd?: string; env?: NodeJS.ProcessEnv; stdio?: import('node:child_process').StdioOptions },
) => AcpSpawnedProcess;

// ---- session/update payloads (15-agent-mode.md:104-110). Discriminated by `sessionUpdate` so a
// consumer (WO-9) renders distinct panels. Only the fields the doc names are modeled; an unknown
// sessionUpdate value is still forwarded (cast) so a new kind is surfaced, not dropped. --------
export interface AcpContentBlock {
  type?: string;
  text?: string;
}
export interface AcpAgentMessageChunk {
  sessionUpdate: 'agent_message_chunk';
  content?: AcpContentBlock;
}
export interface AcpAgentThoughtChunk {
  sessionUpdate: 'agent_thought_chunk';
  content?: AcpContentBlock;
}
export interface AcpToolCallUpdate {
  sessionUpdate: 'tool_call';
  toolCallId?: string;
  title?: string;
  kind?: string;
  status?: string;
  rawInput?: unknown;
  // Optional parent tool id when the ACP host reports subagent nesting (top-level
  // or under _meta). Absent on current grok streams; spawn_subagent still works via name.
  parentToolId?: string;
}
export interface AcpToolCallStatusUpdate {
  sessionUpdate: 'tool_call_update';
  toolCallId?: string;
  status?: string;
  title?: string;
  content?: unknown;
  rawOutput?: unknown;
  parentToolId?: string;
}
export interface AcpPlanEntry {
  content?: string;
  status?: string;
  priority?: string;
}
export interface AcpPlanUpdate {
  sessionUpdate: 'plan';
  entries?: AcpPlanEntry[];
}
// grok pushes two update kinds the doc omits (measured, 0.2.103): `user_message_chunk` (grok
// echoing the user's OWN message) and `available_commands_update` (the slash-command list).
// Neither is agent output, so the consumer skips both — modeled here only so that skip is explicit.
export interface AcpUserMessageChunk {
  sessionUpdate: 'user_message_chunk';
}
export interface AcpAvailableCommandsUpdate {
  sessionUpdate: 'available_commands_update';
}
export type AcpUpdate =
  | AcpAgentMessageChunk
  | AcpAgentThoughtChunk
  | AcpToolCallUpdate
  | AcpToolCallStatusUpdate
  | AcpPlanUpdate
  | AcpUserMessageChunk
  | AcpAvailableCommandsUpdate;

// The session/prompt RESPONSE (the turn terminator). grok 0.2.103 (measured) carries usage/cost
// under `result._meta` — NOT a top-level `result.usage`: `_meta.totalTokens`, `_meta.modelId`, and
// `_meta.usage.{costUsdTicks,inputTokens,outputTokens}` (1 USD = 1e10 ticks). extractPromptResult
// reads those into the fields below; the top-level `usage` passthrough is kept for compatibility.
export interface AcpPromptResult {
  stopReason?: string;
  usage?: unknown;
  costUsd?: number;
  totalTokens?: number;
  modelId?: string;
  tokensIn?: number;
  tokensOut?: number;
}

// Optional session/new `_meta` (15-agent-mode.md:151-159).
export interface AcpSessionMeta {
  rules?: string;
  systemPromptOverride?: string;
  agentProfile?: string | Record<string, unknown>;
}

// Multimodal prompt blocks for session/prompt (measured: text + image with data/mimeType).
export type AcpPromptBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; data: string; mimeType: string };

// A tool-permission request the agent pushes as a server→client request (see the Q4 adapter).
export interface AcpPermissionOption {
  optionId: string;
  name?: string;
  kind?: string;
}
export interface AcpPermissionRequest {
  requestId: number | string; // the JSON-RPC id the response must echo
  sessionId?: string;
  toolName?: string;
  toolCall?: unknown; // raw toolCall for the consumer
  input?: unknown; // toolCall.rawInput when present
  options: AcpPermissionOption[];
}

// MCP server entry passed to session/new and session/load (subprocess attach gateway).
// Grok ACP wire format (measured): `env` is an ARRAY of {name,value} — NOT a string map.
// A map triggers JSON-RPC -32602 "data did not match any variant of untagged enum McpServer".
export interface AcpMcpEnvVar {
  name: string;
  value: string;
}
export interface AcpMcpServerConfig {
  name: string;
  command: string;
  args?: string[];
  env?: AcpMcpEnvVar[];
}

export interface GrokAcpClientOptions {
  logger: Logger;
  cwd?: string; // spawn cwd for the child
  model?: string; // `-m` (only when isGrokModel accepts it)
  effort?: string; // `--reasoning-effort`
  bypassPermissions?: boolean; // `--always-approve`
  grokCommand?: string; // defaults to 'grok'
  env?: NodeJS.ProcessEnv;
  requestTimeoutMs?: number; // per control-request timeout (not applied to a prompt turn)
  // Injectables (default to the real implementations).
  spawn?: AcpSpawnFn;
  isGrokModel?: (m: string) => boolean; // `-m` guard; defaults to the catalog's isGrokModel
  // Aborting kills the child (SIGTERM), rejects pending requests, and ends the active prompt —
  // the ModeSession.stop() path. An already-aborted signal closes on the next tick (mirrors runner).
  signal?: AbortSignal;
  // Optional MCP servers (e.g. discord attach_file). Empty when fileAttach is not wired.
  mcpServers?: AcpMcpServerConfig[];
}

const PROTOCOL_VERSION = 1;
// Minimal client capabilities (Q5): we do NOT delegate fs/terminal — grok works with its own
// tools, and we only consume the update stream + answer permission asks. Declaring these off
// keeps grok from calling back into us for file I/O (§8 / D2).
const MINIMAL_CLIENT_CAPABILITIES = {
  fs: { readTextFile: false, writeTextFile: false },
  terminal: false,
};
const DEFAULT_REQUEST_TIMEOUT_MS = 60_000;
const STDERR_CAPTURE_CAP = 8 * 1024; // bounded stderr buffer — retain only the last ~8KB (runner idiom)
const STDERR_TAIL_CHARS = 500;

// Actionable-hint messages for a dead child, mirroring runner.ts's classification idea (R5).
const ACP_LOGIN_MESSAGE = 'Grok에 로그인되어 있지 않습니다. 터미널에서 `grok login`을 실행한 뒤 다시 시도하세요.';
const ACP_NOT_INSTALLED_MESSAGE = '`grok` CLI를 찾을 수 없습니다. 설치 여부와 PATH를 확인하세요.';
const AUTH_FAILURE_RE = /\bnot authenticated\b|please log in|grok login|\bunauthorized\b|\bauthenticat/i;

// Q4: CONFIRMED live (grok 0.2.103) — method `session/request_permission` (a server→client
// request), params {sessionId, toolCall{toolCallId,kind,title,rawInput,_meta}, options[]}, option
// kinds allow_once/allow_always/reject_once/reject_always, response
// {outcome:{outcome:'selected',optionId}}; this adapter is verified correct against the capture.
// Everything the client needs to know about that wire shape stays ISOLATED in this adapter (method
// name, param parse, outcome build) — search `// Q4:` for the spots.
// WO-10: grok also pre-announces the ask via a `_x.ai/session_notification`
// {sessionUpdate:'pending_interaction',kind:'permission'} notification, which we intentionally
// ignore — the `session/request_permission` request itself is authoritative.
const PERMISSION_METHOD = 'session/request_permission';

function isPermissionMethod(method: string): boolean {
  return method === PERMISSION_METHOD;
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
}

interface ActivePrompt {
  id: number;
  queue: AcpUpdate[]; // updates buffered until the async iterator pulls them
  wake: (() => void) | null; // resolves the iterator's park promise when work arrives
  done: boolean; // the session/prompt response (or a child exit) has arrived
  error: Error | null; // set on child exit / prompt error → thrown from the iterator
  result: AcpPromptResult | null;
}

export class GrokAcpClient {
  private readonly logger: Logger;
  private readonly child: AcpSpawnedProcess;
  private readonly requestTimeoutMs: number;
  private readonly mcpServers: AcpMcpServerConfig[];

  private nextId = 1; // monotonic JSON-RPC request id (NOT the doc's fixed id=1)
  private readonly pending = new Map<number, PendingRequest>(); // client→server requests awaiting a response
  private readonly pendingPermissions = new Map<number | string, AcpPermissionRequest>(); // unanswered permission asks
  private activePrompt: ActivePrompt | null = null; // the one in-flight prompt turn (serialized upstream)
  private permissionHandler: ((req: AcpPermissionRequest) => Promise<PermissionDecision>) | null = null;

  private lineBuffer = ''; // partial-chunk line assembly (runner idiom)
  private stderrBuf = ''; // bounded stderr capture, surfaced on a dead child (R5)
  private closed = false;

  private sessionIdValue: string | null = null;
  private initializeResultValue: unknown = null;
  private lastPromptResultValue: AcpPromptResult | null = null;

  constructor(options: GrokAcpClientOptions) {
    this.logger = options.logger;
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
    this.mcpServers = options.mcpServers ?? [];
    const spawn = options.spawn ?? (realSpawn as unknown as AcpSpawnFn);
    const grokCommand = options.grokCommand ?? 'grok';
    const isKnownModel = options.isGrokModel ?? defaultIsGrokModel;

    // Agent-wide options go BEFORE the `stdio` subcommand (15-agent-mode.md:35). `-m` is added
    // only for a real grok model so a leaked Claude default is dropped (the runner's guard).
    const args: string[] = ['agent'];
    if (options.model && isKnownModel(options.model)) args.push('-m', options.model);
    if (options.effort && options.effort.trim().length > 0) args.push('--reasoning-effort', options.effort.trim());
    if (options.bypassPermissions) args.push('--always-approve');
    args.push('stdio');

    this.child = spawn(grokCommand, args, {
      ...(options.cwd !== undefined ? { cwd: options.cwd } : {}),
      ...(options.env !== undefined ? { env: options.env } : {}),
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    this.child.stdout?.on('data', (chunk: Buffer | string) => this.onStdout(chunk));
    this.child.stderr?.on('data', (chunk: Buffer | string) => {
      this.stderrBuf += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
      if (this.stderrBuf.length > STDERR_CAPTURE_CAP) this.stderrBuf = this.stderrBuf.slice(-STDERR_CAPTURE_CAP);
    });
    this.child.on('error', (err) => this.onChildError(err));
    this.child.on('close', (code, signal) => this.onChildClose(code, signal));

    // No auto-reconnect (Out of scope): an abort just closes.
    if (options.signal) {
      const onAbort = (): void => void this.close();
      if (options.signal.aborted) setImmediate(onAbort);
      else options.signal.addEventListener('abort', onAbort, { once: true });
    }
  }

  get sessionId(): string | null {
    return this.sessionIdValue;
  }

  // The raw `initialize` result (server capabilities / discovered methods). Exposed so WO-10 can
  // confirm the real permission method (Q4) from what grok advertises.
  get initializeResult(): unknown {
    return this.initializeResultValue;
  }

  // stopReason/usage from the most recent completed prompt turn (null until one completes).
  get lastPromptResult(): AcpPromptResult | null {
    return this.lastPromptResultValue;
  }

  // ---- Public API ------------------------------------------------------------------------

  // Handshake with MINIMAL client capabilities (Q5). Stores the result for later discovery.
  async initialize(): Promise<void> {
    const result = await this.sendRequest('initialize', {
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: MINIMAL_CLIENT_CAPABILITIES,
    });
    this.initializeResultValue = result;
  }

  // Create a fresh session; returns the backend sessionId. `_meta` (rules/systemPromptOverride/
  // agentProfile) is attached only when provided (15-agent-mode.md:151-159).
  // mcpServers come from client options (discord attach when fileAttach is wired).
  async sessionNew(cwd: string, meta?: AcpSessionMeta): Promise<string> {
    const params = {
      cwd,
      mcpServers: this.mcpServers as unknown[],
      ...(meta ? { _meta: meta } : {}),
    };
    const result = await this.sendRequest('session/new', params);
    const sid = extractSessionId(result);
    if (sid === null) throw new Error('grok agent stdio: session/new returned no sessionId.');
    this.sessionIdValue = sid;
    return sid;
  }

  // Resume an existing session (15-agent-mode.md — session/load).
  async sessionLoad(sessionId: string, cwd: string): Promise<void> {
    await this.sendRequest('session/load', {
      sessionId,
      cwd,
      mcpServers: this.mcpServers as unknown[],
    });
    this.sessionIdValue = sessionId;
  }

  // Run ONE prompt turn. Yields each session/update's `params.update`, completing when the matching
  // session/prompt RESPONSE arrives (stopReason/usage then readable via lastPromptResult). One
  // prompt in flight at a time (turns are serialized by the orchestrator). A child exit ends the
  // iterator with an error rather than hanging.
  // `input` may be a plain string or multimodal blocks (text + image base64 — measured wire:
  // { type:'image', data, mimeType }).
  prompt(input: string | AcpPromptBlock[]): AsyncIterableIterator<AcpUpdate> {
    if (this.closed) throw new Error('Grok ACP client is closed.');
    if (this.activePrompt) throw new Error('A grok prompt is already in flight.');
    if (this.sessionIdValue === null) throw new Error('No grok session — call sessionNew or sessionLoad first.');
    const id = this.nextId++;
    const active: ActivePrompt = { id, queue: [], wake: null, done: false, error: null, result: null };
    this.activePrompt = active;
    this.lastPromptResultValue = null;
    const blocks: AcpPromptBlock[] =
      typeof input === 'string' ? [{ type: 'text', text: input }] : input.length > 0 ? input : [{ type: 'text', text: ' ' }];
    this.write({
      jsonrpc: '2.0',
      id,
      method: 'session/prompt',
      params: { sessionId: this.sessionIdValue, prompt: blocks },
    });
    return this.drainPrompt(active);
  }

  // Register the tool-permission handler. When the agent asks (a server→client request), the
  // handler's returned decision is sent back as the JSON-RPC response. Without a handler, a
  // permission ask still gets a safe default (cancelled) so the agent never hangs.
  onPermissionRequest(cb: (req: AcpPermissionRequest) => Promise<PermissionDecision>): void {
    this.permissionHandler = cb;
  }

  // Low-level responder for a pending permission ask (Q4 adapter builds the wire outcome). The
  // single place that writes a permission response, so the cb-return path and any out-of-band
  // caller can't double-respond (the id is cleared on first use).
  respondPermission(requestId: number | string, decision: PermissionDecision): void {
    const req = this.pendingPermissions.get(requestId);
    if (!req) return; // already answered / unknown id
    this.pendingPermissions.delete(requestId);
    if (this.closed) return; // child gone — nothing to answer
    this.write({ jsonrpc: '2.0', id: requestId, result: buildPermissionResult(decision, req) });
  }

  // Kill the child (SIGTERM), reject every pending request, and end the active prompt. Idempotent.
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.child.kill('SIGTERM');
    this.rejectInFlight(new Error('Grok ACP client was closed.'));
  }

  // ---- Transport internals ---------------------------------------------------------------

  private sendRequest(method: string, params: unknown): Promise<unknown> {
    if (this.closed) return Promise.reject(new Error('Grok ACP client is closed.'));
    const id = this.nextId++;
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`grok agent stdio: ${method} timed out after ${this.requestTimeoutMs}ms.`));
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
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }

  private write(msg: Record<string, unknown>): void {
    const stdin = this.child.stdin;
    if (!stdin) return;
    stdin.write(JSON.stringify(msg) + '\n');
  }

  // Line-buffered stdout: split on newlines, keep a trailing partial for the next chunk (mirrors
  // runner.ts). A malformed/non-JSON line is logged at debug and skipped — never thrown.
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
      this.logger.debug('grok acp: skipping non-JSON stdout line', { preview: trimmed.slice(0, 120) });
      return;
    }
    if (!isObject(msg)) {
      this.logger.debug('grok acp: skipping non-object message');
      return;
    }

    const rawId = (msg as { id?: unknown }).id;
    const id = typeof rawId === 'number' || typeof rawId === 'string' ? rawId : undefined;
    const method = typeof (msg as { method?: unknown }).method === 'string' ? (msg as { method: string }).method : undefined;
    const hasResult = 'result' in msg;
    const hasError = 'error' in msg;

    // (1) Response: an id we issued + result/error, no method.
    if (id !== undefined && method === undefined && (hasResult || hasError)) {
      this.handleResponse(id, msg);
      return;
    }
    // (2) Server→client request: id + method → must be answered with the SAME id.
    if (id !== undefined && method !== undefined) {
      this.handleServerRequest(id, method, msg);
      return;
    }
    // (3) Notification: method, no id.
    if (id === undefined && method !== undefined) {
      this.handleNotification(method, msg);
      return;
    }
    this.logger.debug('grok acp: skipping unclassifiable message', { hasId: id !== undefined, hasMethod: method !== undefined });
  }

  private handleResponse(id: number | string, msg: Record<string, unknown>): void {
    // A prompt response terminates the active prompt stream (it is not a pending-map entry).
    if (this.activePrompt && this.activePrompt.id === id) {
      this.finalizePrompt(msg);
      return;
    }
    if (typeof id !== 'number') {
      this.logger.debug('grok acp: response for unknown (non-numeric) id', { id });
      return;
    }
    const pending = this.pending.get(id);
    if (!pending) {
      this.logger.debug('grok acp: response for unknown id', { id });
      return;
    }
    this.pending.delete(id);
    const error = (msg as { error?: unknown }).error;
    if (error !== undefined) pending.reject(new Error(formatRpcError(error)));
    else pending.resolve((msg as { result?: unknown }).result);
  }

  private handleServerRequest(id: number | string, method: string, msg: Record<string, unknown>): void {
    if (isPermissionMethod(method)) {
      // Q4: route the permission ask through the adapter; always answered (even with no handler).
      void this.handlePermission(id, (msg as { params?: unknown }).params);
      return;
    }
    // Any other server→client request has no handler here — answer with method-not-found so the
    // agent isn't left waiting (we deliberately do NOT delegate fs/terminal, Q5).
    this.logger.debug('grok acp: unhandled server request', { method });
    this.write({ jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${method}` } });
  }

  private handleNotification(method: string, msg: Record<string, unknown>): void {
    if (method === 'session/update' || method === 'x.ai/session/update') {
      const update = extractUpdate((msg as { params?: unknown }).params);
      if (update) this.pushUpdate(update);
      else this.logger.debug('grok acp: session/update without a params.update', { method });
      return;
    }
    // x.ai/* and any other notification: debug only, never crash (the set is non-exhaustive).
    this.logger.debug('grok acp: unhandled notification', { method });
  }

  private async handlePermission(id: number | string, params: unknown): Promise<void> {
    const req = parsePermissionRequest(id, params);
    this.pendingPermissions.set(id, req);
    if (!this.permissionHandler) {
      // Nothing wired → safe default so the agent never hangs (§ API: deny/cancelled).
      this.respondPermission(id, { behavior: 'deny', message: 'No grok permission handler configured.' });
      return;
    }
    let decision: PermissionDecision;
    try {
      decision = await this.permissionHandler(req);
    } catch (err) {
      this.logger.debug('grok acp: permission handler threw; denying', { error: err instanceof Error ? err.message : String(err) });
      decision = { behavior: 'deny' };
    }
    // The handler may have answered out-of-band via respondPermission — only answer if still pending.
    if (this.pendingPermissions.has(id)) this.respondPermission(id, decision);
  }

  private finalizePrompt(msg: Record<string, unknown>): void {
    const active = this.activePrompt;
    if (!active) return;
    const error = (msg as { error?: unknown }).error;
    if (error !== undefined) {
      active.error = new Error(formatRpcError(error));
    } else {
      active.result = extractPromptResult((msg as { result?: unknown }).result);
      this.lastPromptResultValue = active.result;
    }
    active.done = true;
    const wake = active.wake;
    active.wake = null;
    wake?.();
  }

  private pushUpdate(update: AcpUpdate): void {
    const active = this.activePrompt;
    if (!active) {
      // A session/update with no turn in flight (e.g. between turns) can't be delivered.
      this.logger.debug('grok acp: session/update with no active prompt; dropping', { sessionUpdate: update.sessionUpdate });
      return;
    }
    active.queue.push(update);
    const wake = active.wake;
    active.wake = null;
    wake?.();
  }

  private async *drainPrompt(active: ActivePrompt): AsyncGenerator<AcpUpdate> {
    try {
      // Yield buffered updates first; park when empty; break once the turn is done AND drained.
      while (true) {
        const next = active.queue.shift();
        if (next !== undefined) {
          yield next;
          continue;
        }
        if (active.done) break;
        await new Promise<void>((resolve) => {
          active.wake = resolve;
        });
      }
      if (active.error) throw active.error;
    } finally {
      if (this.activePrompt === active) this.activePrompt = null;
      active.wake = null;
    }
  }

  private onChildError(err: Error): void {
    if (this.closed) return;
    this.closed = true;
    const code = (err as NodeJS.ErrnoException).code;
    const message = classifyAcpFailure(err.message, code) ?? redactString(err.message);
    this.rejectInFlight(new Error(message));
  }

  private onChildClose(code: number | null, signal: NodeJS.Signals | null): void {
    if (this.closed) return; // expected shutdown from close()
    this.closed = true;
    this.rejectInFlight(this.buildExitError(code, signal));
  }

  // Turn a dead child into an actionable error: an auth/install hint when the stderr shows one,
  // else a generic "exited" message with a REDACTED stderr tail (raw grok stderr can carry a key).
  private buildExitError(code: number | null, signal: NodeJS.Signals | null): Error {
    const actionable = classifyAcpFailure(this.stderrBuf);
    if (actionable) return new Error(actionable);
    const tail = redactString(stderrTail(this.stderrBuf));
    const suffix = tail.length > 0 ? ` ${tail}` : '';
    const codeStr = code === null ? `signal ${signal ?? 'unknown'}` : `code ${code}`;
    return new Error(`grok agent stdio exited unexpectedly (${codeStr}).${suffix}`);
  }

  private rejectInFlight(err: Error): void {
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
    const active = this.activePrompt;
    if (active && !active.done) {
      active.error = err;
      active.done = true;
      const wake = active.wake;
      active.wake = null;
      wake?.();
    }
    this.pendingPermissions.clear();
  }
}

// ---- Pure helpers -----------------------------------------------------------------------------

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function extractSessionId(result: unknown): string | null {
  if (!isObject(result)) return null;
  const sid = result.sessionId;
  return typeof sid === 'string' && sid.length > 0 ? sid : null;
}

function extractUpdate(params: unknown): AcpUpdate | null {
  if (!isObject(params)) return null;
  const update = params.update;
  if (!isObject(update)) return null;
  if (typeof update.sessionUpdate !== 'string') return null;
  // Lift parentToolId from top-level or _meta when present so consumers can route nested
  // tool calls without re-parsing raw ACP shapes. Other fields stay as cast-through.
  const meta = isObject(update._meta) ? update._meta : undefined;
  const parentFromMeta =
    meta && typeof meta.parentToolId === 'string'
      ? meta.parentToolId
      : meta && typeof meta.parent_tool_use_id === 'string'
        ? meta.parent_tool_use_id
        : undefined;
  const parentTop =
    typeof update.parentToolId === 'string'
      ? update.parentToolId
      : typeof update.parent_tool_use_id === 'string'
        ? update.parent_tool_use_id
        : undefined;
  const parentToolId = parentTop ?? parentFromMeta;
  if (typeof parentToolId === 'string' && parentToolId.length > 0) {
    return { ...(update as object), parentToolId } as unknown as AcpUpdate;
  }
  // A known sessionUpdate matches the union; an unknown value is still forwarded so the consumer
  // (which switches with a default) can decide — the cast is intentional and documented.
  return update as unknown as AcpUpdate;
}

function extractPromptResult(result: unknown): AcpPromptResult {
  if (!isObject(result)) return {};
  const out: AcpPromptResult = {};
  if (typeof result.stopReason === 'string') out.stopReason = result.stopReason;
  if (result.usage !== undefined) out.usage = result.usage; // top-level passthrough (compat)
  // grok 0.2.103 puts usage/cost under result._meta, not a top-level result.usage. Read it
  // defensively — every field optional, never throw on a missing/odd shape.
  const meta = isObject(result._meta) ? result._meta : undefined;
  if (meta) {
    if (typeof meta.modelId === 'string') out.modelId = meta.modelId;
    if (typeof meta.totalTokens === 'number') out.totalTokens = meta.totalTokens;
    const usage = isObject(meta.usage) ? meta.usage : undefined;
    if (usage) {
      // 1 USD = 1e10 cost ticks (confirmed by path A's total_cost_usd_ticks).
      if (typeof usage.costUsdTicks === 'number' && Number.isFinite(usage.costUsdTicks)) {
        out.costUsd = usage.costUsdTicks / 1e10;
      }
      if (typeof usage.inputTokens === 'number') out.tokensIn = usage.inputTokens;
      if (typeof usage.outputTokens === 'number') out.tokensOut = usage.outputTokens;
    }
  }
  return out;
}

function formatRpcError(error: unknown): string {
  if (isObject(error)) {
    const code = typeof error.code === 'number' ? error.code : 'unknown';
    const message = typeof error.message === 'string' ? redactString(error.message) : 'unknown error';
    return `grok agent stdio error ${code}: ${message}`;
  }
  return `grok agent stdio error: ${redactString(String(error))}`;
}

// Q4: parse the standard `session/request_permission` params into a normalized request.
function parsePermissionRequest(requestId: number | string, params: unknown): AcpPermissionRequest {
  const p = isObject(params) ? params : {};
  const sessionId = typeof p.sessionId === 'string' ? p.sessionId : undefined;
  const toolCall = p.toolCall;
  const toolName = deriveToolName(toolCall);
  const input = isObject(toolCall) ? (toolCall as { rawInput?: unknown }).rawInput : undefined;
  return {
    requestId,
    ...(sessionId !== undefined ? { sessionId } : {}),
    ...(toolName !== undefined ? { toolName } : {}),
    ...(toolCall !== undefined ? { toolCall } : {}),
    ...(input !== undefined ? { input } : {}),
    options: parsePermissionOptions(p.options),
  };
}

function parsePermissionOptions(raw: unknown): AcpPermissionOption[] {
  if (!Array.isArray(raw)) return [];
  const out: AcpPermissionOption[] = [];
  for (const item of raw) {
    if (!isObject(item)) continue;
    if (typeof item.optionId !== 'string') continue;
    const option: AcpPermissionOption = { optionId: item.optionId };
    if (typeof item.name === 'string') option.name = item.name;
    if (typeof item.kind === 'string') option.kind = item.kind;
    out.push(option);
  }
  return out;
}

function deriveToolName(toolCall: unknown): string | undefined {
  if (!isObject(toolCall)) return undefined;
  const title = toolCall.title;
  if (typeof title === 'string' && title.length > 0) return title;
  const name = toolCall.name;
  if (typeof name === 'string' && name.length > 0) return name;
  const kind = toolCall.kind;
  if (typeof kind === 'string' && kind.length > 0) return kind;
  return undefined;
}

// Q4: map a PermissionDecision onto the standard ACP response outcome. Allow selects an
// allow-kind option (else the first offered option, else a bare 'allow'); deny selects a
// reject-kind option when offered, else the neutral 'cancelled' outcome.
function buildPermissionResult(decision: PermissionDecision, req: AcpPermissionRequest): Record<string, unknown> {
  if (decision.behavior === 'allow') {
    const option = req.options.find((o) => (o.kind ?? '').startsWith('allow')) ?? req.options[0];
    return { outcome: { outcome: 'selected', optionId: option?.optionId ?? 'allow' } };
  }
  const reject = req.options.find((o) => (o.kind ?? '').startsWith('reject'));
  if (reject) return { outcome: { outcome: 'selected', optionId: reject.optionId } };
  return { outcome: { outcome: 'cancelled' } };
}

// Classify a dead child (spawn error message + code, or captured stderr) into a user-actionable
// hint, or undefined when it is neither a missing-binary nor an auth failure (runner idiom, R5).
function classifyAcpFailure(text: string, code?: string): string | undefined {
  if (code === 'ENOENT' || /\bENOENT\b/.test(text)) return ACP_NOT_INSTALLED_MESSAGE;
  if (AUTH_FAILURE_RE.test(text)) return ACP_LOGIN_MESSAGE;
  return undefined;
}

function stderrTail(stderr: string): string {
  const trimmed = stderr.trim();
  return trimmed.length > STDERR_TAIL_CHARS ? `…${trimmed.slice(-STDERR_TAIL_CHARS)}` : trimmed;
}
