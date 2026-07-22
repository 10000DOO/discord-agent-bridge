import * as crypto from 'node:crypto';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import type {
  AgentEvent,
  ModeContext,
  ModeSession,
  PermissionDecision,
  TurnInput,
} from '../../../core/contracts.js';
import {
  GrokAcpClient,
  type AcpMcpServerConfig,
  type AcpPermissionRequest,
  type AcpPromptBlock,
  type AcpPromptResult,
  type AcpSessionMeta,
  type AcpUpdate,
  type GrokAcpClientOptions,
} from './acpClient.js';
import { grokConfigSource } from '../configSource.js';
import type { SendFileCallback, ShareDocumentCallback } from '../../claude/mcpFileTool.js';
import type { AttachGateway } from '../../../discord/attachGateway.js';
import { appendNonImageHints, classifyTurnFiles, readImageBase64 } from '../../shared/turnFiles.js';

// The path-B ModeSession (WO-9): a long-lived ACP conversation over ONE `grok agent stdio` child,
// consumed via GrokAcpClient (WO-8). Mirrors the lifecycle of modes/claude/session.ts ClaudeSession
// (onSessionIdReady-once, stop/interrupt, per-message → AgentEvent mapping) rather than path A's
// per-turn subprocess (modes/grok/index.ts GrokSession).
//
// LAZY-INIT is what gives path-A-parity interrupt: the client is not spawned until the first send(),
// and interrupt() simply CLOSES it (killing the child) while KEEPING the session context. The
// retained resumeId means the next send() re-inits the child and continues the same conversation via
// session/load — mirroring path A's kill-child + `-r <id>` on the next turn.

// The subset of GrokAcpClient this session drives. Structural so a test injects a fake client with
// no real `grok agent stdio` process (GrokAcpClient satisfies it with extra members).
export interface GrokAcpClientLike {
  initialize(): Promise<void>;
  sessionNew(cwd: string, meta?: AcpSessionMeta): Promise<string>;
  sessionLoad(sessionId: string, cwd: string): Promise<void>;
  prompt(input: string | AcpPromptBlock[]): AsyncIterableIterator<AcpUpdate>;
  onPermissionRequest(cb: (req: AcpPermissionRequest) => Promise<PermissionDecision>): void;
  close(): Promise<void>;
  readonly lastPromptResult: AcpPromptResult | null;
}

export type CreateGrokAcpClient = (options: GrokAcpClientOptions) => GrokAcpClientLike;

export interface GrokAcpSessionDeps {
  // Existing backend session id to resume; omitted for a fresh session.
  resumeId?: string;
  // Optional session/new `_meta` (rules / systemPromptOverride / agentProfile).
  meta?: AcpSessionMeta;
  // Injectable client factory (defaults to the real GrokAcpClient) so tests drive a fake.
  createClient?: CreateGrokAcpClient;
  // When both sendFile and attachGateway are set, register attach_file MCP for this session.
  sendFile?: SendFileCallback;
  attachGateway?: AttachGateway;
  // Sibling sink to sendFile: when set (alongside attachGateway), the same loopback MCP
  // server also exposes share_document, which posts a workspace markdown into a Discord
  // thread for THIS channel. Bound per session by the Discord layer (shareDocumentFor).
  shareDocument?: ShareDocumentCallback;
}

export class GrokAcpSession implements ModeSession {
  private readonly ctx: ModeContext;
  // Turn-invariant spawn inputs. ACP model/effort are fixed at spawn time (agent-wide flags before
  // the `stdio` subcommand), so a fresh client picks them up on (re-)init.
  private readonly cwd: string;
  private readonly model: string;
  private readonly effort: string;
  private readonly bypassPermissions: boolean;
  private readonly meta: AcpSessionMeta | undefined;
  private readonly createClient: CreateGrokAcpClient;
  private readonly sendFile: SendFileCallback | undefined;
  private readonly attachGateway: AttachGateway | undefined;
  private readonly shareDocument: ShareDocumentCallback | undefined;

  // The live client, or null when none is spawned (before the first send, or after an interrupt /
  // a dead-child drop). resumeId is the id a re-init resumes: seeded from a resume, then set to the
  // fresh session/new id so an interrupt-then-send continues the same conversation.
  private client: GrokAcpClientLike | null = null;
  private sessionIdValue: string | null = null;
  private resumeId: string | null = null;

  // Stable fallback id for a tool_call the agent sends without a toolCallId (so tool_use/tool_result
  // still pair up in the renderers). A per-session counter is deterministic within the session.
  private toolCallSeq = 0;

  // Set by interrupt() so the resulting in-flight prompt error is treated as an intentional cancel,
  // not a failure to surface (reset at the start of every send). Mirrors ClaudeSession's aborted
  // check in its consume loop.
  private aborting = false;
  private closed = false;

  // Attach gateway token for this session (registered while a client is live).
  private attachToken: string | null = null;

  constructor(ctx: ModeContext, deps: GrokAcpSessionDeps = {}) {
    this.ctx = ctx;
    this.cwd = ctx.cwd;
    this.model = ctx.model ?? '';
    this.effort = ctx.effort ?? '';
    // Only 'bypassPermissions' maps to grok's `--always-approve`; every other mode leaves the
    // agent's interactive approval on (answered by the client's safe default until WO-10).
    this.bypassPermissions = ctx.permMode === 'bypassPermissions';
    this.meta = deps.meta;
    this.createClient = deps.createClient ?? ((options) => new GrokAcpClient(options));
    this.sendFile = deps.sendFile;
    this.attachGateway = deps.attachGateway;
    this.shareDocument = deps.shareDocument;
    if (deps.resumeId !== undefined) {
      // A resume knows its id upfront (like ClaudeSession/GrokSession) so onSessionIdReady is NOT
      // fired — the id is already persisted by the caller that chose to resume it.
      this.resumeId = deps.resumeId;
      this.sessionIdValue = deps.resumeId;
    }
  }

  get sessionId(): string | null {
    return this.sessionIdValue;
  }

  // Deliver one user turn. Lazily (re-)spawns the client, runs the prompt, and maps every ACP
  // update to a normalized AgentEvent. A stop()/interrupt() closes the client mid-turn on purpose,
  // so the resulting prompt error is swallowed; any other error surfaces once and drops the dead
  // client so the next send() re-inits (session/load keeps context).
  async send(turn: TurnInput): Promise<void> {
    if (this.closed) throw new Error('Grok agent session is closed.');
    this.aborting = false;
    try {
      const client = await this.ensureClient();
      for await (const update of client.prompt(buildGrokPromptBlocks(turn))) {
        this.mapUpdate(update);
      }
      this.emitResult(client.lastPromptResult);
    } catch (err) {
      if (this.closed || this.aborting) return; // intentional stop()/interrupt() teardown
      await this.dropClient();
      this.ctx.emit({
        kind: 'error',
        message: err instanceof Error ? err.message : String(err),
        retryable: false,
      });
    }
  }

  // Abort the in-flight turn AND close the session (kill switch). A later send() throws.
  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.dropClient();
    this.unregisterAttach();
  }

  // Cancel the CURRENT turn only, keeping the session context: close the child (which ends the
  // in-flight prompt) but leave `closed` false so the next send() re-inits via session/load and
  // continues the same conversation (terminal-`grok` parity). Harmless when nothing is in flight.
  async interrupt(): Promise<void> {
    if (this.closed) return;
    this.aborting = true;
    await this.dropClient();
    // Keep attach token registered across interrupt so the next send reuses the same MCP config
    // token after re-register (dropClient does not unregister; stop does).
  }

  // setModel/setEffort are intentionally NOT implemented: ACP model/effort are spawn-time
  // (agent-wide flags before `stdio`), so changing them needs a client restart — out of WO-9 scope.
  // The orchestrator duck-types their absence as "unsupported".

  private async ensureClient(): Promise<GrokAcpClientLike> {
    if (this.client) return this.client;
    const mcpServers = await this.buildMcpServers();
    const client = this.createClient({
      logger: this.ctx.logger,
      cwd: this.cwd,
      ...(this.model.length > 0 ? { model: this.model } : {}),
      ...(this.effort.length > 0 ? { effort: this.effort } : {}),
      bypassPermissions: this.bypassPermissions,
      ...(mcpServers.length > 0 ? { mcpServers } : {}),
    });
    this.client = client;
    // Wire the tool-approval round-trip to Discord (mirrors modes/claude/permissions.ts makeCanUseTool):
    // when the agent asks, delegate to the GLOBAL permission seam (ctx.requestPermission → owner
    // Allow/Deny buttons), and its decision is mapped to the ACP outcome by the client's Q4 adapter,
    // which also safe-denies if this handler throws. toolName falls back to 'tool'; input to the raw
    // toolCall. ('bypassPermissions' still short-circuits inside grok via --always-approve, so no ask
    // reaches here in that mode.)
    client.onPermissionRequest(async (req) => {
      return this.ctx.requestPermission({
        toolName: req.toolName ?? 'tool',
        input: req.input ?? req.toolCall,
      });
    });
    await client.initialize();
    if (this.resumeId !== null) {
      await client.sessionLoad(this.resumeId, this.cwd);
    } else {
      this.captureSessionId(await client.sessionNew(this.cwd, this.meta));
    }
    return client;
  }

  private async buildMcpServers(): Promise<AcpMcpServerConfig[]> {
    if (!this.sendFile || !this.attachGateway) return [];
    await this.attachGateway.whenReady();
    // Fresh token per client spawn so a re-init after interrupt still has a live registration.
    this.unregisterAttach();
    const token = crypto.randomBytes(24).toString('hex');
    // Register the share_document sink on the SAME token/registration as attach_file when the
    // Discord layer wired one, so the loopback /share endpoint is authenticated identically and
    // is available (mirrors the fileAttach gating) exactly when both this callback and the
    // gateway are present. Absent → the gateway refuses /share for this token.
    this.attachGateway.register(token, {
      workspaceRoot: this.cwd,
      sendFile: this.sendFile,
      ...(this.shareDocument ? { shareDocument: this.shareDocument } : {}),
    });
    this.attachToken = token;
    const scriptPath = resolveAttachMcpScript();
    // env must be [{name,value},…] — Grok rejects Record maps with -32602 Invalid params.
    return [
      {
        name: 'discord',
        command: process.execPath,
        args: [scriptPath],
        env: [
          { name: 'DAB_ATTACH_URL', value: this.attachGateway.baseUrl },
          { name: 'DAB_ATTACH_TOKEN', value: token },
          { name: 'DAB_WORKSPACE', value: this.cwd },
        ],
      },
    ];
  }

  private unregisterAttach(): void {
    if (this.attachToken && this.attachGateway) {
      this.attachGateway.unregister(this.attachToken);
    }
    this.attachToken = null;
  }

  // Record the first backend sessionId: fire onSessionIdReady exactly once and retain it as the
  // resume id so a re-init after interrupt continues the same session. A no-op once known.
  private captureSessionId(id: string): void {
    if (this.sessionIdValue !== null) return;
    this.sessionIdValue = id;
    this.resumeId = id;
    this.ctx.onSessionIdReady?.(id);
  }

  // Close the current client (best-effort) and forget it so the next send() re-inits.
  private async dropClient(): Promise<void> {
    const client = this.client;
    this.client = null;
    if (!client) return;
    try {
      await client.close();
    } catch {
      // Closing an already-dead child is a no-op we can ignore (mirrors ClaudeSession.stop).
    }
  }

  // One ACP session/update → zero or one AgentEvent (D5), reusing existing kinds only (no contracts
  // change). An unknown/unhandled update is debug-logged and skipped so a new kind never throws.
  private mapUpdate(update: AcpUpdate): void {
    switch (update.sessionUpdate) {
      case 'agent_message_chunk': {
        const text = update.content?.text ?? '';
        if (text.length > 0) this.ctx.emit({ kind: 'text', text, delta: true });
        return;
      }
      case 'agent_thought_chunk': {
        const text = update.content?.text ?? '';
        if (text.length > 0) this.ctx.emit({ kind: 'thinking', text, delta: true });
        return;
      }
      case 'tool_call': {
        const parent =
          typeof update.parentToolId === 'string' && update.parentToolId.length > 0
            ? { parentToolUseId: update.parentToolId }
            : {};
        this.ctx.emit({
          kind: 'tool_use',
          id: update.toolCallId ?? `grok-tool-${++this.toolCallSeq}`,
          name: normalizeGrokToolName(update.title, update.kind),
          input: normalizeGrokToolInput(update.rawInput),
          ...parent,
        });
        return;
      }
      case 'tool_call_update': {
        // grok sends tool_call_update TWICE per tool (measured, 0.2.103): first an INTERMEDIATE
        // update with NO status (carrying the diff content), then a TERMINAL one with
        // status completed/failed. Only the terminal update is a real result — emitting on the
        // intermediate would surface a spurious ok:false before the tool actually finished. So
        // emit a tool_result ONLY on a terminal status; a non-terminal update is skipped.
        const status = update.status;
        if (status !== 'completed' && status !== 'failed') {
          this.ctx.logger.debug('grok acp: skipping non-terminal tool_call_update', {
            toolCallId: update.toolCallId,
            status,
          });
          return;
        }
        const parent =
          typeof update.parentToolId === 'string' && update.parentToolId.length > 0
            ? { parentToolUseId: update.parentToolId }
            : {};
        this.ctx.emit({
          kind: 'tool_result',
          id: update.toolCallId ?? '',
          ok: status === 'completed',
          content: stringifyContent(update.content ?? update.rawOutput ?? ''),
          ...parent,
        });
        return;
      }
      case 'plan': {
        // WO-11 (Q3): reuse the existing `progress` kind (no dedicated `{kind:'plan'}` event) —
        // format each plan entry into one status-marked line. Entries without content are skipped;
        // an empty/absent list still surfaces a bare "Plan" progress (never throws).
        const lines = (update.entries ?? [])
          .filter((e) => (e.content ?? '').trim().length > 0)
          .map((e) => `${planStatusMark(e.status)} ${e.content ?? ''}`.trim());
        this.ctx.emit({
          kind: 'progress',
          label: 'Plan',
          ...(lines.length > 0 ? { detail: lines.join('\n') } : {}),
        });
        return;
      }
      case 'user_message_chunk':
      case 'available_commands_update':
        // grok echoes the user's own message / slash-command list back as updates — not agent
        // output; do not re-render.
        return;
      default: {
        this.ctx.logger.debug('grok acp: unmapped session update', {
          sessionUpdate: (update as { sessionUpdate?: string }).sessionUpdate,
        });
      }
    }
  }

  // Best-effort turn-end result from the prompt response. grok 0.2.103 carries cost/usage under
  // result._meta (parsed by acpClient.extractPromptResult into costUsd/totalTokens/modelId/tokens);
  // cost/tokens prefer those measured fields and fall back to the top-level `usage` passthrough
  // (path-A shape {input_tokens,output_tokens,total_cost_usd}) for compatibility. Then, when the
  // response reports a positive totalTokens, emit a context_usage panel (R9/D6, mirroring
  // runner.ts): resolve the serving model (session model → response modelId → grok default) and its
  // context window; skip the panel when no window is known (a 0-denominator gauge is worse than
  // none). Defensive throughout — never throws.
  private emitResult(result: AcpPromptResult | null): void {
    const rawUsage = isObject(result?.usage) ? result.usage : undefined;
    const legacyCost =
      rawUsage &&
      typeof rawUsage.total_cost_usd === 'number' &&
      rawUsage.cost_is_partial !== true &&
      rawUsage.usage_is_incomplete !== true
        ? rawUsage.total_cost_usd
        : undefined;
    const tokensIn =
      typeof result?.tokensIn === 'number'
        ? result.tokensIn
        : rawUsage && typeof rawUsage.input_tokens === 'number'
          ? rawUsage.input_tokens
          : undefined;
    const tokensOut =
      typeof result?.tokensOut === 'number'
        ? result.tokensOut
        : rawUsage && typeof rawUsage.output_tokens === 'number'
          ? rawUsage.output_tokens
          : undefined;
    const costUsd = typeof result?.costUsd === 'number' ? result.costUsd : legacyCost;
    const event: Extract<AgentEvent, { kind: 'result' }> = {
      kind: 'result',
      ...(tokensIn !== undefined ? { tokensIn } : {}),
      ...(tokensOut !== undefined ? { tokensOut } : {}),
      ...(costUsd !== undefined ? { costUsd } : {}),
    };
    this.ctx.emit(event);

    const totalTokens = result?.totalTokens;
    if (typeof totalTokens === 'number' && totalTokens > 0) {
      const model = this.model.length > 0 ? this.model : result?.modelId ?? grokConfigSource.defaultModel();
      const maxTokens = grokConfigSource.contextWindow(model);
      if (typeof maxTokens === 'number' && maxTokens > 0) {
        this.ctx.emit({
          kind: 'context_usage',
          totalTokens,
          maxTokens,
          percentage: Math.min(100, Math.round((totalTokens / maxTokens) * 100)),
          model,
        });
      }
    }
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

// Compact marker for one plan entry's status in the human-readable plan summary (WO-11):
// completed → ✓, in_progress → ▶, pending / unknown / absent → •.
function planStatusMark(status?: string): string {
  switch (status) {
    case 'completed':
      return '✓';
    case 'in_progress':
      return '▶';
    default:
      return '•';
  }
}

// Flatten an ACP tool_call_update `content`/`rawOutput` into a plain string for the normalized
// tool_result event: pass a string through, JSON-stringify an object, String() anything else.
function stringifyContent(content: unknown): string {
  if (typeof content === 'string') return content;
  try {
    return JSON.stringify(content);
  } catch {
    return String(content);
  }
}

// Multimodal prompt: text + base64 images (ACP image block measured on grok agent stdio).
function buildGrokPromptBlocks(turn: TurnInput): AcpPromptBlock[] {
  const classified = classifyTurnFiles(turn.files);
  const images = classified.filter((f) => f.isImage);
  const nonImages = classified.filter((f) => !f.isImage);
  const text = appendNonImageHints(turn.text, nonImages);
  const blocks: AcpPromptBlock[] = [{ type: 'text', text: text.trim().length > 0 ? text : ' ' }];
  for (const img of images) {
    blocks.push({ type: 'image', data: readImageBase64(img.path), mimeType: img.mime });
  }
  return blocks;
}

// Map grok tool titles/kinds onto DiffView FILE_EDIT_TOOLS names (Edit/Write) when obvious.
function normalizeGrokToolName(title?: string, kind?: string): string {
  const t = (title ?? '').trim();
  const k = (kind ?? '').trim().toLowerCase();
  if (k === 'edit' || /^edit\b/i.test(t)) return 'Edit';
  if (k === 'write' || /^write\b/i.test(t)) return 'Write';
  if (t.length > 0) return t;
  if (kind && kind.length > 0) return kind;
  return 'tool';
}

// Normalize rawInput so DiffView sees file_path / old_string / new_string / content.
function normalizeGrokToolInput(rawInput: unknown): unknown {
  if (!isObject(rawInput)) return rawInput ?? {};
  const out: Record<string, unknown> = { ...rawInput };
  if (typeof out.file_path !== 'string' && typeof out.path === 'string') {
    out.file_path = out.path;
  }
  if (typeof out.old_string !== 'string' && typeof out.oldText === 'string') {
    out.old_string = out.oldText;
  }
  if (typeof out.new_string !== 'string' && typeof out.newText === 'string') {
    out.new_string = out.newText;
  }
  return out;
}

// scripts/dab-discord-attach-mcp.mjs next to the package root (works for src/ and dist/).
function resolveAttachMcpScript(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  // .../src|dist/modes/grok/agent → package root
  return path.resolve(here, '../../../../scripts/dab-discord-attach-mcp.mjs');
}
