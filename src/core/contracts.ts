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
// sandbox flags (see modes/codex/runner.ts permModeArgs). As of the installed SDK:
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
// to sandbox + approval flags (modes/codex/runner permModeArgs). Kept as its own type so
// the Claude PermMode path is untouched.
export type CodexSandboxMode = 'read-only' | 'workspace-write' | 'danger-full-access';

// The permission value carried on a SESSION (binding/context/start): either a Claude
// PermMode or a Codex sandbox mode. Only the runner that receives it (Claude SDK vs
// codex spawn) interprets it — the carrier fields stay backend-agnostic. Config
// DEFAULTS remain PermMode-only (the /config panel is Claude's vocabulary).
export type SessionPermMode = PermMode | CodexSandboxMode;

// ---- Normalized event stream every mode emits (superset union) ----
export type AgentEvent =
  | { kind: 'text'; text: string; delta: boolean } // delta=true → streaming chunk
  | { kind: 'thinking'; text: string; delta: boolean }
  | { kind: 'tool_use'; id: string; name: string; input: unknown }
  | { kind: 'tool_result'; id: string; ok: boolean; content: string }
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
  | { kind: 'context_usage'; totalTokens: number; maxTokens: number; percentage: number } // Claude: query.getContextUsage()
  | {
      kind: 'error';
      message: string;
      retryable: boolean;
      rateLimit?: { resetAt?: string; rateLimitType?: string; utilization?: number };
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
  stop(): Promise<void>; // abort / terminate
  // Modes that support permissionPrompts call ctx.requestPermission; Discord resolves it.
}

// ---- Describes a session a mode can resume (for resume UX) ----
export interface ResumableSession {
  sessionId: string;
  cwd: string;
  label?: string;
  updatedAt?: string;
}

// ---- The mode plugin: the ONE thing a new backend implements ----
export interface AgentMode {
  readonly name: string; // 'claude' | 'codex' | 'gemini' | …
  readonly capabilities: Capabilities;
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
}
