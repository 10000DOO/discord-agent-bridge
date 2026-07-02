import * as os from 'node:os';
import * as path from 'node:path';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
  TurnInput,
} from '../../core/contracts.js';
import { runCodexTurn, type RunCodexTurnOptions, type RunCodexTurnResult } from './runner.js';
import { CodexDiscovery } from './discovery.js';
import { CODEX_PERMISSION_MODES } from '../../core/providerCatalog.js';

// The Codex backend: unlike Claude's single long-lived query(), Codex is one-shot
// PER TURN (a fresh `codex exec --json` first, then `codex exec resume <id>` once a
// thread id exists). CodexSession wraps runCodexTurn and threads the captured
// sessionId forward. Capabilities (§5b) drive which Discord renderers run: no
// streaming/thinking/tool-threads/permission-prompts/usage-panel — Codex surfaces
// progress + a post-hoc transcript, and its control is via sandbox/approval flags
// (mapped from PermMode in the runner) plus the core CommandPolicy, NOT per-action
// Discord Allow/Deny prompts (permissionPrompts:false).

// Injectable seam so tests drive CodexMode/CodexSession without a real `codex`
// process or a real ~/.codex on disk. Defaults wire the real runner/discovery.
export interface CodexModeDeps {
  runTurn?: (opts: RunCodexTurnOptions) => Promise<RunCodexTurnResult>;
  discovery?: CodexDiscovery;
}

export class CodexMode implements AgentMode {
  readonly name = 'codex';

  readonly capabilities: Capabilities = {
    streaming: false,
    thinking: false,
    toolThreads: false,
    // Codex does NOT surface per-action Discord Allow/Deny; control is via the
    // sandbox/approval flags (PermMode → runner) + the core CommandPolicy (§5b).
    permissionPrompts: false,
    progress: true,
    transcript: true,
    sessionResume: true,
    fileAttach: false,
    fileDiff: false,
    usagePanel: false,
    // Only the subset that maps to Codex approval/sandbox flags in the runner
    // (verified, §5b/§7A). 'dontAsk'/'auto' have no Codex mapping and are excluded by
    // the central catalog's CODEX_PERMISSION_MODES.
    permissionModes: [...CODEX_PERMISSION_MODES],
  };

  private readonly deps: CodexModeDeps;

  constructor(deps: CodexModeDeps = {}) {
    this.deps = deps;
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    return new CodexSession(ctx, this.sessionDeps());
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    return new CodexSession(ctx, { ...this.sessionDeps(), resumeId: sessionId });
  }

  // For the resume UX (§9): list resumable ~/.codex threads. codexHome resolves the
  // configured value, expanding a leading `~` and defaulting to <home>/.codex when
  // unset (P2-2 Q1). includeSubAgents stays internal/false (Q2).
  async listResumable(ctx: ModeContext): Promise<ResumableSession[]> {
    const codexHome = resolveCodexHome(ctx.config.codexHome);
    return this.discovery(ctx).listResumable(codexHome, {});
  }

  private sessionDeps(): CodexSessionDeps {
    return {
      ...(this.deps.runTurn !== undefined ? { runTurn: this.deps.runTurn } : {}),
    };
  }

  private discovery(ctx: ModeContext): CodexDiscovery {
    return this.deps.discovery ?? new CodexDiscovery({ logger: ctx.logger });
  }
}

export interface CodexSessionDeps {
  // Defaults to the real runCodexTurn; tests inject a fake.
  runTurn?: (opts: RunCodexTurnOptions) => Promise<RunCodexTurnResult>;
  // Existing backend thread id to resume; omitted for a fresh session.
  resumeId?: string;
}

// A Codex session (§9). It holds the turn-invariant inputs (cwd/model/permMode) and
// the backend thread id — null until the first turn's `thread.started` sets it,
// captured from the runCodexTurn result. Each send() runs one `codex exec` turn:
// a fresh turn first, then `exec resume <id>` once the id is known. stop() aborts
// any in-flight child via an AbortController the runner honors.
export class CodexSession implements ModeSession {
  sessionId: string | null = null;

  private readonly ctx: ModeContext;
  private readonly runTurn: (opts: RunCodexTurnOptions) => Promise<RunCodexTurnResult>;
  private readonly cwd: string;
  private readonly model: string;
  // A single AbortController for the session; stop() aborts it so the in-flight
  // runCodexTurn kills its `codex` child. Turns are serialized by the orchestrator's
  // per-channel queue, so at most one turn is ever in flight.
  private readonly abortController: AbortController;
  private closed = false;

  constructor(ctx: ModeContext, deps: CodexSessionDeps = {}) {
    this.ctx = ctx;
    this.runTurn = deps.runTurn ?? runCodexTurn;
    this.cwd = ctx.cwd;
    // Codex reads its OWN model (not ctx.model, which carries the Claude model).
    // Empty → omit `-m` so `codex` uses its own config default (operator-set).
    this.model = ctx.config.codexModel ?? '';
    this.abortController = new AbortController();
    if (deps.resumeId !== undefined) {
      this.sessionId = deps.resumeId;
    }
  }

  // Deliver one user turn. runCodexTurn builds the argv (fresh vs resume), spawns
  // the CLI, streams events through ctx.emit, and returns the (possibly newly
  // captured) thread id. After a FRESH turn we store the id so the next turn resumes.
  // On resume, Codex uses the thread's persisted cwd (resume can't pass --cd), so a
  // resumed session's cwd is informational and may be '' (Q4) — the runner ignores
  // cwd on resume anyway.
  async send(turn: TurnInput): Promise<void> {
    if (this.closed) throw new Error('Codex session is closed.');
    const result = await this.runTurn({
      prompt: turn.text,
      cwd: this.cwd,
      permMode: this.ctx.permMode,
      ...(this.model.length > 0 ? { model: this.model } : {}),
      ...(this.ctx.effort !== undefined && this.ctx.effort.length > 0 ? { effort: this.ctx.effort } : {}),
      ...(this.sessionId !== null ? { resumeId: this.sessionId } : {}),
      timeoutMs: this.ctx.config.codexTimeoutMs ?? DEFAULT_CODEX_TIMEOUT_MS,
      ...(this.ctx.config.codexCliCommand !== undefined ? { codexCommand: this.ctx.config.codexCliCommand } : {}),
      ...(this.ctx.config.codexHome !== undefined ? { codexHome: resolveCodexHome(this.ctx.config.codexHome) } : {}),
      emit: this.ctx.emit,
      logger: this.ctx.logger,
      signal: this.abortController.signal,
    });
    // Capture the thread id from the first (fresh) turn so subsequent turns resume it.
    if (this.sessionId === null && result.sessionId !== null) {
      this.sessionId = result.sessionId;
    }
  }

  // Abort the in-flight `codex` child (§7.5 kill switch). The runner drains and
  // resolves the turn as aborted; the AbortController stays aborted so a late turn
  // cannot spawn a fresh child.
  async stop(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.abortController.abort();
  }
}

// Fallback when config.codexTimeoutMs is somehow absent (matches configSchema's
// limits.codexTimeoutMs default). The resolved ModeConfigView normally supplies it.
const DEFAULT_CODEX_TIMEOUT_MS = 1_800_000;

// Resolve the configured codexHome to an absolute path: default to <home>/.codex
// when unset/empty, and expand a leading `~`/`~/` (config stores it as '~/.codex').
export function resolveCodexHome(configured: string | undefined): string {
  if (!configured || configured.length === 0) return path.join(os.homedir(), '.codex');
  if (configured === '~') return os.homedir();
  if (configured.startsWith('~/')) return path.join(os.homedir(), configured.slice(2));
  return configured;
}
