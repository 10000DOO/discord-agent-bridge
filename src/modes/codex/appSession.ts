import type { ModeContext, ModeSession, TurnInput } from '../../core/contracts.js';
import { isCodexEffort } from '../../core/providerCatalog.js';
import {
  CodexAppServerClient,
  type AppServerApprovalDecision,
  type AppServerApprovalRequest,
  type CodexAppServerClientOptions,
  type DynamicToolCallParams,
  type DynamicToolCallResult,
  type DynamicToolSpec,
} from './appServerClient.js';
import { mapAppServerNotification, type MapContext } from './eventMapper.js';
import { isAutoApprovePolicy, resolveThreadPolicy } from './policy.js';
import { resolveCodexHome } from './resolveHome.js';
import { attachFileConfined, type SendFileCallback } from '../claude/mcpFileTool.js';
import { appendNonImageHints, classifyTurnFiles } from '../shared/turnFiles.js';

// Long-lived Codex ModeSession over one `codex app-server` child. One user message =
// one turn/start; interrupt cancels the turn (process kept); stop kills the child.

export type CreateCodexAppServerClient = (options: CodexAppServerClientOptions) => CodexAppServerClientLike;

// Structural subset so tests inject a fake without a real process.
export interface CodexAppServerClientLike {
  initialize(clientInfo?: { name?: string; version?: string }): Promise<unknown>;
  threadStart(params: {
    cwd: string;
    approvalPolicy: string;
    sandbox: string;
    model?: string;
    dynamicTools?: DynamicToolSpec[];
  }): Promise<string>;
  threadResume(params: { threadId: string }): Promise<unknown>;
  turnStart(params: {
    threadId: string;
    input: Array<{ type: string; text?: string }>;
    effort?: string;
    model?: string;
  }): Promise<string>;
  turnInterrupt(params: { threadId: string; turnId: string }): Promise<unknown>;
  onNotification(handler: (method: string, params: unknown) => void): () => void;
  close(): Promise<void>;
  readonly isClosed?: boolean;
}

export interface CodexAppSessionDeps {
  resumeId?: string;
  createClient?: CreateCodexAppServerClient;
  // When set, register attach_file dynamic tool and handle item/tool/call.
  sendFile?: SendFileCallback;
}

const DEFAULT_CODEX_TIMEOUT_MS = 1_800_000;

const ATTACH_FILE_DYNAMIC_TOOL: DynamicToolSpec = {
  type: 'function',
  name: 'attach_file',
  description:
    'Send a file from the workspace to the Discord channel for this session. Path must be inside the workspace. Create the file first if needed.',
  inputSchema: {
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Workspace-relative or absolute path inside workspace' },
      filename: { type: 'string', description: 'Optional display name' },
    },
    required: ['path'],
  },
};

interface TurnWait {
  turnId: string;
  settle: () => void; // ends the send() wait (idempotent)
  unsub: () => void;
  timer: ReturnType<typeof setTimeout> | null;
}

export class CodexAppSession implements ModeSession {
  private readonly ctx: ModeContext;
  private readonly cwd: string;
  private readonly model: string;
  private effort: string;
  private readonly createClient: CreateCodexAppServerClient;
  private readonly sendFile: SendFileCallback | undefined;

  private client: CodexAppServerClientLike | null = null;
  private initialized = false;
  private threadReady = false;
  private sessionIdValue: string | null = null;

  private turnWait: TurnWait | null = null;
  private aborting = false;
  private closed = false;

  // childThreadId → spawn tool_use id (subagent Discord routing).
  private readonly parentByThread = new Map<string, string>();
  private toolSeq = 0;

  // Latest token-usage snapshot from thread/tokenUsage/updated this turn. Emitted
  // once as context_usage when the turn completes (result first, then panel).
  private lastTokenUsage: {
    totalTokens: number;
    maxTokens: number;
    percentage: number;
    model?: string;
  } | null = null;

  constructor(ctx: ModeContext, deps: CodexAppSessionDeps = {}) {
    this.ctx = ctx;
    this.cwd = ctx.cwd;
    this.model = ctx.config.codexModel ?? '';
    this.effort = ctx.effort ?? '';
    this.createClient =
      deps.createClient ??
      ((options) => new CodexAppServerClient(options));
    this.sendFile = deps.sendFile;
    if (deps.resumeId !== undefined) {
      this.sessionIdValue = deps.resumeId;
    }
  }

  get sessionId(): string | null {
    return this.sessionIdValue;
  }

  async send(turn: TurnInput): Promise<void> {
    if (this.closed) throw new Error('Codex session is closed.');
    this.aborting = false;
    // Fresh turn: drop any leftover snapshot from a prior interrupted/failed turn.
    this.lastTokenUsage = null;

    const timeoutMs = this.ctx.config.codexTimeoutMs ?? DEFAULT_CODEX_TIMEOUT_MS;

    try {
      const client = await this.ensureClient();
      await this.ensureThread(client);

      const threadId = this.sessionIdValue;
      if (!threadId) throw new Error('Codex session has no thread id.');

      const turnParams: {
        threadId: string;
        input: Array<{ type: string; text?: string; path?: string }>;
        effort?: string;
        model?: string;
      } = {
        threadId,
        input: buildCodexTurnInput(turn),
      };
      if (this.effort.trim().length > 0) turnParams.effort = this.effort.trim();
      if (this.model.length > 0) turnParams.model = this.model;

      const turnId = await client.turnStart(turnParams);

      const mapCtx: MapContext = {
        mainThreadId: threadId,
        parentByThread: this.parentByThread,
        onSpawnThread: (childThreadId, spawnToolId) => {
          this.parentByThread.set(childThreadId, spawnToolId);
        },
        logger: this.ctx.logger,
        idFor: (item) => {
          if (typeof item.id === 'string' && item.id.length > 0) return item.id;
          if (typeof item.itemId === 'string' && item.itemId.length > 0) return item.itemId;
          return `codex-tool-${++this.toolSeq}`;
        },
      };

      await new Promise<void>((resolve) => {
        let settled = false;
        let unsub: () => void = () => {};
        let timer: ReturnType<typeof setTimeout> | null = null;

        const settle = (): void => {
          if (settled) return;
          settled = true;
          if (this.turnWait?.turnId === turnId) this.turnWait = null;
          unsub();
          if (timer) clearTimeout(timer);
          resolve();
        };

        unsub = client.onNotification((method, params) => {
          if (this.closed) return;
          const mapped = mapAppServerNotification(method, params, mapCtx);
          // turn/started clears any stale snapshot so a retry mid-session stays clean.
          if (method === 'turn/started') this.lastTokenUsage = null;
          if (mapped.tokenUsage) this.lastTokenUsage = mapped.tokenUsage;
          // Emit mapped events first (result / error), then one context_usage at turn end.
          for (const ev of mapped.events) this.ctx.emit(ev);
          if (mapped.turnCompleted) {
            if (this.lastTokenUsage) {
              this.ctx.emit({ kind: 'context_usage', ...this.lastTokenUsage });
              this.lastTokenUsage = null;
            }
            if (!mapped.turnId || mapped.turnId === turnId) settle();
          }
        });

        timer = setTimeout(() => {
          void (async () => {
            try {
              await client.turnInterrupt({ threadId, turnId });
            } catch {
              // best-effort
            }
            this.ctx.emit({
              kind: 'error',
              message: `Codex turn timed out after ${timeoutMs}ms.`,
              retryable: true,
            });
            settle();
          })();
        }, timeoutMs);
        timer.unref?.();

        this.turnWait = { turnId, settle, unsub, timer };
      });
    } catch (err) {
      if (this.closed || this.aborting) return;
      this.ctx.emit({
        kind: 'error',
        message: err instanceof Error ? err.message : String(err),
        retryable: false,
      });
      await this.dropClient();
    }
  }

  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.aborting = true;
    this.finishTurnWait();
    await this.dropClient();
  }

  async interrupt(): Promise<void> {
    if (this.closed) return;
    this.aborting = true;
    const wait = this.turnWait;
    const client = this.client;
    if (wait && client && this.sessionIdValue) {
      try {
        await client.turnInterrupt({ threadId: this.sessionIdValue, turnId: wait.turnId });
      } catch {
        // best-effort
      }
    }
    // End the in-flight send() without closing the session/client.
    this.finishTurnWait();
  }

  async setEffort(effort?: string): Promise<void> {
    const level = (effort ?? '').trim();
    if (level.length > 0 && !isCodexEffort(level)) {
      throw new Error(`Unsupported reasoning effort level for Codex: ${level}`);
    }
    this.effort = level;
  }

  // ---- private ------------------------------------------------------------------------------

  private finishTurnWait(): void {
    const w = this.turnWait;
    if (!w) return;
    this.turnWait = null;
    w.settle();
  }

  private async ensureClient(): Promise<CodexAppServerClientLike> {
    if (this.client && !this.client.isClosed) return this.client;

    const policy = resolveThreadPolicy(this.ctx.permMode);
    const codexHome =
      this.ctx.config.codexHome !== undefined
        ? resolveCodexHome(this.ctx.config.codexHome)
        : undefined;

    const clientOptions: CodexAppServerClientOptions = {
      logger: this.ctx.logger,
      cwd: this.cwd,
      ...(this.ctx.config.codexCliCommand !== undefined
        ? { codexCommand: this.ctx.config.codexCliCommand }
        : {}),
      ...(codexHome !== undefined ? { codexHome } : {}),
      onApproval: async (req) => this.handleApproval(req, policy.approvalPolicy),
    };
    if (this.sendFile) {
      clientOptions.onDynamicToolCall = (params) => this.handleDynamicToolCall(params);
    }

    const client = this.createClient(clientOptions);
    this.client = client;
    this.initialized = false;
    this.threadReady = false;

    await client.initialize();
    this.initialized = true;
    return client;
  }

  private async ensureThread(client: CodexAppServerClientLike): Promise<void> {
    if (this.threadReady && this.sessionIdValue) return;

    const policy = resolveThreadPolicy(this.ctx.permMode);

    if (this.sessionIdValue) {
      // thread/resume typically does not re-register dynamicTools; attach remains
      // for fresh starts. Resume path still answers item/tool/call if the process
      // re-requests (handler is on the client).
      await client.threadResume({ threadId: this.sessionIdValue });
      this.threadReady = true;
      return;
    }

    const startParams: {
      cwd: string;
      approvalPolicy: string;
      sandbox: string;
      model?: string;
      dynamicTools?: DynamicToolSpec[];
    } = {
      cwd: this.cwd,
      approvalPolicy: policy.approvalPolicy,
      sandbox: policy.sandbox,
    };
    if (this.model.length > 0) startParams.model = this.model;
    if (this.sendFile) startParams.dynamicTools = [ATTACH_FILE_DYNAMIC_TOOL];

    const threadId = await client.threadStart(startParams);
    this.captureSessionId(threadId);
    this.threadReady = true;
  }

  private captureSessionId(id: string): void {
    if (this.sessionIdValue !== null) return;
    this.sessionIdValue = id;
    this.ctx.onSessionIdReady?.(id);
  }

  private async handleDynamicToolCall(params: DynamicToolCallParams): Promise<DynamicToolCallResult> {
    const toolId = params.callId || `attach-${++this.toolSeq}`;
    const args = asRecord(params.arguments) ?? {};
    const requestedPath = typeof args.path === 'string' ? args.path : '';
    const filename = typeof args.filename === 'string' ? args.filename : undefined;

    this.ctx.emit({
      kind: 'tool_use',
      id: toolId,
      name: params.tool || 'attach_file',
      input: { path: requestedPath, ...(filename !== undefined ? { filename } : {}) },
    });

    if (!this.sendFile) {
      const text = 'attach_file is not available in this session.';
      this.ctx.emit({ kind: 'tool_result', id: toolId, ok: false, content: text });
      return { success: false, contentItems: [{ type: 'inputText', text }] };
    }

    if (params.tool !== 'attach_file') {
      const text = `Unknown dynamic tool: ${params.tool}`;
      this.ctx.emit({ kind: 'tool_result', id: toolId, ok: false, content: text });
      return { success: false, contentItems: [{ type: 'inputText', text }] };
    }

    if (requestedPath.length === 0) {
      const text = 'attach_file requires a path.';
      this.ctx.emit({ kind: 'tool_result', id: toolId, ok: false, content: text });
      return { success: false, contentItems: [{ type: 'inputText', text }] };
    }

    const result = await attachFileConfined(this.cwd, this.sendFile, requestedPath, filename);
    const text = result.content.map((c) => c.text).join('\n') || (result.isError ? 'failed' : 'ok');
    const success = !result.isError;
    this.ctx.emit({ kind: 'tool_result', id: toolId, ok: success, content: text });
    return {
      success,
      contentItems: [{ type: 'inputText', text }],
    };
  }

  private async handleApproval(
    req: AppServerApprovalRequest,
    approvalPolicy: string,
  ): Promise<AppServerApprovalDecision> {
    if (approvalPolicy === 'never' || isAutoApprovePolicy(resolveThreadPolicy(this.ctx.permMode))) {
      return 'accept';
    }
    const toolName = deriveApprovalToolName(req);
    const decision = await this.ctx.requestPermission({
      toolName,
      input: req.params ?? {},
    });
    return decision.behavior === 'allow' ? 'accept' : 'decline';
  }

  private async dropClient(): Promise<void> {
    const client = this.client;
    this.client = null;
    this.initialized = false;
    this.threadReady = false;
    // Keep sessionIdValue so the next ensureThread does thread/resume.
    if (!client) return;
    try {
      await client.close();
    } catch {
      // ignore
    }
  }
}

// Multimodal turn input: text + localImage paths (Codex UserInput localImage).
function buildCodexTurnInput(
  turn: TurnInput,
): Array<{ type: string; text?: string; path?: string }> {
  const classified = classifyTurnFiles(turn.files);
  const images = classified.filter((f) => f.isImage);
  const nonImages = classified.filter((f) => !f.isImage);
  const text = appendNonImageHints(turn.text, nonImages);
  const input: Array<{ type: string; text?: string; path?: string }> = [];
  if (text.trim().length > 0) input.push({ type: 'text', text });
  for (const img of images) input.push({ type: 'localImage', path: img.path });
  if (input.length === 0) input.push({ type: 'text', text: ' ' });
  return input;
}

function deriveApprovalToolName(req: AppServerApprovalRequest): string {
  const p = req.params;
  if (p !== null && typeof p === 'object' && !Array.isArray(p)) {
    const rec = p as Record<string, unknown>;
    if (typeof rec.command === 'string') return 'shell';
    if (typeof rec.tool === 'string') return rec.tool;
    if (typeof rec.name === 'string') return rec.name;
  }
  if (req.method.includes('commandExecution')) return 'shell';
  if (req.method.includes('fileChange')) return 'apply_patch';
  return 'tool';
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}
