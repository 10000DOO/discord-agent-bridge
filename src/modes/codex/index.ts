import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';
import { CodexDiscovery } from './discovery.js';
import { CODEX_PERMISSION_MODES, codexCatalog } from '../../core/providerCatalog.js';
import {
  CodexAppSession,
  type CodexAppSessionDeps,
  type CreateCodexAppServerClient,
} from './appSession.js';
import { resolveCodexHome } from './resolveHome.js';
import type { SendFileCallback, ShareDocumentCallback } from '../claude/mcpFileTool.js';

// Codex backend via long-lived `codex app-server` (JSON-RPC). Mode name stays `codex`.
// Phase 2: thinking + usagePanel + fileDiff; fileAttach only when sendFileFor is wired.

export interface CodexModeDeps {
  discovery?: CodexDiscovery;
  createClient?: CreateCodexAppServerClient;
  // Wired by the Discord layer: per-channel attach_file sink (dynamic tool).
  sendFileFor?: (guildId: string, channelId: string) => SendFileCallback;
  // Sibling factory to sendFileFor for the share_document dynamic tool (path-only markdown →
  // Discord thread; same funnel as the /doc slash). Bound per session, same as sendFileFor.
  shareDocumentFor?: (guildId: string, channelId: string) => ShareDocumentCallback;
}

export class CodexMode implements AgentMode {
  readonly name = 'codex';

  readonly capabilities: Capabilities;

  readonly catalog = codexCatalog;

  private readonly deps: CodexModeDeps;

  constructor(deps: CodexModeDeps = {}) {
    this.deps = deps;
    // fileAttach only when a sendFile factory is wired (omit dynamicTools otherwise).
    const fileAttach = deps.sendFileFor !== undefined;
    this.capabilities = {
      streaming: true,
      thinking: true,
      toolThreads: true,
      permissionPrompts: true,
      progress: true,
      transcript: false,
      sessionResume: true,
      fileAttach,
      fileDiff: true,
      usagePanel: true,
      permissionModes: [...CODEX_PERMISSION_MODES],
    };
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    return new CodexAppSession(ctx, this.sessionDeps(ctx));
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    return new CodexAppSession(ctx, { ...this.sessionDeps(ctx), resumeId: sessionId });
  }

  async listResumable(ctx: ModeContext): Promise<ResumableSession[]> {
    const codexHome = resolveCodexHome(ctx.config.codexHome);
    return this.discovery(ctx).listResumable(codexHome, {});
  }

  private sessionDeps(ctx: ModeContext): CodexAppSessionDeps {
    const sendFile = this.deps.sendFileFor?.(ctx.guildId, ctx.channelId);
    const shareDocument = this.deps.shareDocumentFor?.(ctx.guildId, ctx.channelId);
    return {
      ...(this.deps.createClient !== undefined ? { createClient: this.deps.createClient } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
      ...(shareDocument !== undefined ? { shareDocument } : {}),
    };
  }

  private discovery(ctx: ModeContext): CodexDiscovery {
    return this.deps.discovery ?? new CodexDiscovery({ logger: ctx.logger });
  }
}

// Backward-compatible alias used by older tests/callers.
export { CodexAppSession as CodexSession } from './appSession.js';
export { resolveCodexHome } from './resolveHome.js';
export { resolveThreadPolicy } from './policy.js';
export type { ThreadPolicy } from './policy.js';
export type { CreateCodexAppServerClient, CodexAppSessionDeps } from './appSession.js';
