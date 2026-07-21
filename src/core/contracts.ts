// THE seam. Every backend implements AgentMode; Discord renders only what
// Capabilities declares. See docs/DESIGN.md §5 (Contracts).
// Type declarations only — no logic lives here.

import type { PermissionMode } from '@anthropic-ai/claude-agent-sdk';

// ---- Capabilities: sole purpose is "render only what this mode supports" ----
export interface Capabilities {
  streaming: boolean; // live token-by-token text deltas
  thinking: boolean; // extended-thinking stream
  toolThreads: boolean; // per-tool-call Discord threads + tool results
  permissionPrompts: boolean; // interactive Allow/Deny before a tool runs (Claude 'default' mode)
  progress: boolean; // coarse operation-progress ("editing file…")
  transcript: boolean; // post-hoc message/transcript feed
  sessionResume: boolean; // can resume a prior session
  fileAttach: boolean; // agent can push files to the channel
  fileDiff: boolean; // can surface file-change diffs (Claude)
  usagePanel: boolean; // supports the usage/limits panel (Claude only; Codex=false)
  permissionModes: PermMode[]; // which permission modes this backend accepts (see below)
}

// Permission modes — DERIVED from the installed SDK's PermissionMode so the two never
// drift: if the SDK adds/removes a mode on upgrade, PermMode changes with it and the
// providerCatalog `satisfies` guards surface it. Passed straight to the Claude SDK
// `permissionMode`; Codex maps the subset it supports onto its own approval-policy +
// sandbox flags (see modes/codex/policy.ts resolveThreadPolicy). As of the installed SDK:
//   'default'           Claude: interactive canUseTool Allow/Deny buttons
//   'acceptEdits'       Claude: auto-approve file edits
//   'bypassPermissions' Claude: auto-approve all  (⚠ dangerous)
//   'plan'              Claude: read-only / planning
//   'dontAsk'           Claude: don't prompt; deny if not pre-approved (Claude-only)
//   'auto'              Claude: model-classifier decides approve/deny (Claude-only)
export type PermMode = PermissionMode;

// Codex's OWN permission vocabulary is sandbox-based, not Claude's PermMode names. The
// `/agent start` wizard's Codex permission step offers these `-s`/--sandbox values
// directly (see core/providerCatalog CODEX_SANDBOX_MODES); the codex runner maps each
// to sandbox + approval flags (modes/codex/policy resolveThreadPolicy). Kept as its own type so
// the Claude PermMode path is untouched.
export type CodexSandboxMode = 'read-only' | 'workspace-write' | 'danger-full-access';

// The permission value carried on a SESSION (binding/context/start): either a Claude
// PermMode or a Codex sandbox mode. Only the mode that receives it (Claude SDK vs
// Codex app-server) interprets it — the carrier fields stay backend-agnostic. Config
// DEFAULTS remain PermMode-only (the /config panel is Claude's vocabulary).
export type SessionPermMode = PermMode | CodexSandboxMode;

// ---- Normalized event stream every mode emits (superset union) ----
export type AgentEvent =
  | { kind: 'text'; text: string; delta: boolean } // delta=true → streaming chunk
  | { kind: 'thinking'; text: string; delta: boolean }
  // parentToolUseId: when set, this event belongs to a subagent whose spawn
  // tool_use id is the parent (Claude parent_tool_use_id / Grok parentToolId).
  // Absent → main work thread. Optional so backends without parent meta stay valid.
  | { kind: 'tool_use'; id: string; name: string; input: unknown; parentToolUseId?: string }
  | { kind: 'tool_result'; id: string; ok: boolean; content: string; parentToolUseId?: string }
  | { kind: 'permission_request'; id: string; toolName: string; input: unknown } // resolved via ctx.requestPermission
  | { kind: 'progress'; label: string; detail?: string } // Codex operation-progress
  | {
      kind: 'result';
      text?: string;
      costUsd?: number;
      tokensIn?: number;
      tokensOut?: number;
      durationMs?: number;
    }
  // Claude: query.getContextUsage(); `model` is the init-reported RESOLVED model id
  // actually serving the session (e.g. 'claude-fable-5[1m]'), shown on the usage panel.
  // The optional extras are best-effort session/turn facts for the usage panel — all
  // optional so existing consumers (and backends that never learn them) are untouched:
  //   modelDisplayName  supportedModels() displayName captured once at init
  //   clearableTokens   getContextUsage() 'Messages' category tokens (= what /clear reclaims)
  //   memoryFileCount   getContextUsage().memoryFiles.length (loaded CLAUDE.md files)
  //   mcpServerCount    init mcp_servers with status 'connected'
  | {
      kind: 'context_usage';
      totalTokens: number;
      maxTokens: number;
      percentage: number;
      model?: string;
      modelDisplayName?: string;
      clearableTokens?: number;
      memoryFileCount?: number;
      mcpServerCount?: number;
    }
  // Claude: SDK system/task_notification mapped to a normalized subagent completion.
  // `toolUseId` links back to the Task/Agent tool_use block that started it, so a
  // renderer can pair the start (subagent_type/description) with this completion.
  | {
      kind: 'subagent_result';
      taskId: string;
      status: 'completed' | 'failed' | 'stopped';
      summary: string;
      toolUseId?: string;
      durationMs?: number;
      toolUses?: number;
    }
  | {
      kind: 'error';
      message: string;
      retryable: boolean;
    }
  // Rate-limit refresh from the backend. Not an error — the SDK emits this to
  // announce a new utilization snapshot / reset time. Rendered on its own path
  // (📊) so users don't see a ⚠️ error for a routine usage update.
  | {
      kind: 'rate_limit';
      resetAt?: string;
      rateLimitType?: string;
      utilization?: number;
    };

export interface PermissionDecision {
  behavior: 'allow' | 'deny';
  message?: string;
}

// ---- A user turn delivered to a mode ----
export interface TurnInput {
  text: string;
  files?: { path: string; mime?: string }[]; // path-confined by core before reaching a mode
}

// ---- A running session for one channel ----
export interface ModeSession {
  readonly sessionId: string | null; // backend session id (may be null pre-init)
  send(turn: TurnInput): Promise<void>; // deliver a user turn
  stop(): Promise<void>; // abort / terminate (session ends)
  // Cancel ONLY the turn currently in flight, keeping the session/context alive so the
  // next send() continues the same conversation (terminal-`claude` ESC semantics; distinct
  // from stop()). Optional so existing modes/test doubles stay valid; a mode that omits it
  // simply has no interrupt path. Must be harmless/idempotent when nothing is running.
  interrupt?(): Promise<void>;
  // Switch the model on the LIVE session, mid-conversation, without a restart. Optional:
  // only backends whose transport supports it (Claude) implement it; callers duck-type.
  setModel?(model?: string): Promise<void>;
  // Switch the reasoning effort on the LIVE session, mid-conversation, without a restart
  // (Claude: query.applyFlagSettings({ effortLevel }); Codex: the next turn/start effort
  // param). Optional so existing modes/test doubles stay valid; callers duck-type.
  // Takes effect on the next turn of the same session.
  setEffort?(effort?: string): Promise<void>;
  // Modes that support permissionPrompts call ctx.requestPermission; Discord resolves it.
}

// ---- Describes a session a mode can resume (for resume UX) ----
export interface ResumableSession {
  sessionId: string;
  cwd: string;
  label?: string;
  updatedAt?: string;
}

// A single dropdown option offered to the Discord UI: `value` is what we persist/pass to
// the backend, `label` is the English text shown in the menu. `supportedEffortLevels`,
// present only on Claude model choices when the SDK reports them, lets the reasoning-
// effort step narrow to what the chosen model accepts. Lives here (not providerCatalog)
// so ModeCatalog can reference it without contracts back-referencing an implementation
// module — the layer direction stays modes/providerCatalog → contracts.
export interface ModelChoice {
  value: string;
  label: string;
  supportedEffortLevels?: string[];
}

// The per-backend "vocabulary" a mode contributes to the Discord UI (wizard, /config,
// /effort): its model list, permission options, and reasoning-effort options. Each mode
// OWNS its own catalog so core/Discord never branch on the backend id to pick a list
// (§6). `models` may be async (Claude probes the SDK live). An empty effortChoices() →
// the wizard skips the effort step; an empty runtimeEffortChoices() → no /effort for that
// backend. `defaultEffort()` is the wizard's pre-selected effort (undefined → none).
export interface ModeCatalog {
  models(configured?: string): ModelChoice[] | Promise<ModelChoice[]>;
  permissionChoices(): ModelChoice[];
  effortChoices(supportedModelLevels?: readonly string[]): ModelChoice[];
  runtimeEffortChoices(supportedModelLevels?: readonly string[]): ModelChoice[];
  defaultEffort(): string | undefined;
}

// ---- The mode plugin: the ONE thing a new backend implements ----
export interface AgentMode {
  readonly name: string; // 'claude' | 'codex' | 'gemini' | …
  readonly capabilities: Capabilities;
  // The backend's model/permission/effort vocabulary for the Discord UI (§6). Required so
  // callers never need a `?? default` fallback branch — every real backend has one.
  readonly catalog: ModeCatalog;
  start(ctx: ModeContext): Promise<ModeSession>; // begin a fresh session
  resume(ctx: ModeContext, sessionId: string): Promise<ModeSession>; // rebind existing
  listResumable?(ctx: ModeContext): Promise<ResumableSession[]>; // for resume UX
}

// Layered (global → server → project) view of resolved mode config handed to a mode.
export interface ModeConfigView {
  model?: string; // Claude model (backend-specific; Codex reads codexModel instead)
  codexModel?: string; // Codex model; empty/absent → let `codex` use its own config default
  codexHome?: string;
  codexCliCommand?: string;
  codexCliVersion?: string;
  permissionTimeoutSec?: number;
  codexTimeoutMs?: number;
  autoAllowClaudeTools?: string[];
  allowedTools?: string[];
}

// Redacting logger contract (see core/logger.ts).
export interface Logger {
  debug(message: string, ...meta: unknown[]): void;
  info(message: string, ...meta: unknown[]): void;
  warn(message: string, ...meta: unknown[]): void;
  error(message: string, ...meta: unknown[]): void;
}

// Append-only audit entry (see core/auditLog.ts, §7.5). The caller supplies the
// who/what; AuditLog stamps the `when` (timestamp) at record time.
export interface AuditEntry {
  actorId: string;
  roleTier: 'admin' | 'execute' | 'read-only';
  guildId: string;
  channelId: string;
  action: string; // command | tool | turn
  command?: string; // the raw command line, when action is a command
  tool?: string; // the tool name, when action is a tool use
  mode?: string; // backend that handled it (claude | codex | …)
  permMode?: SessionPermMode;
  cwd?: string;
  outcome?: string; // free-form result note
  status?: 'allowed' | 'denied' | 'ok' | 'error'; // coarse result/status
}

export interface ModeContext {
  guildId: string;
  channelId: string;
  cwd: string;
  ownerId: string;
  model?: string;
  // Reasoning-effort level chosen in the wizard (§9). Claude → SDK options.effort;
  // Codex → `-c model_reasoning_effort="…"`. Absent → each backend's own default.
  effort?: string;
  permMode: SessionPermMode; // resolved global→server→project (§7A/§8); Codex may carry a sandbox mode
  emit(ev: AgentEvent): void; // → EventBus → Discord renderers
  requestPermission(req: { toolName: string; input: unknown }): Promise<PermissionDecision>;
  config: ModeConfigView; // resolved (layered) view: model, timeouts, codexHome, etc.
  logger: Logger;
  audit(entry: AuditEntry): void; // who/when/what → AuditLog (§7.5)
  // Called by a mode the FIRST time it captures a real backend sessionId (Claude
  // system/init, Codex first turn result). Optional: existing tests/consumers
  // that omit it stay valid. Synchronous void — the orchestrator persists the
  // registry entry immediately; must be idempotent (same id may repeat).
  onSessionIdReady?(sessionId: string): void;
}
