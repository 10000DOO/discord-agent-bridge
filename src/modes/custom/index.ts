import { listSessions as realListSessions, type Options, type SDKSessionInfo } from '@anthropic-ai/claude-agent-sdk';
import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../core/contracts.js';
import type { QueryFn } from '../claude/session.js';
import type { SendFileCallback, ShareDocumentCallback } from '../claude/mcpFileTool.js';
import { CLAUDE_PERMISSION_MODES, claudeCatalog } from '../../core/providerCatalog.js';
import { resolveCustomEnv } from './shellEnv.js';
import { CustomEnvSession } from './session.js';

// The signature of the SDK's listSessions() — narrowed to what listResumable uses.
// Injectable so tests pass a fake without touching the SDK or the filesystem.
export type ListSessionsFn = (options: { dir?: string; limit?: number }) => Promise<SDKSessionInfo[]>;

// Maximum resumable sessions surfaced in the resume picker (Discord select cap).
const LIST_RESUMABLE_LIMIT = 25;

export interface CustomModeDeps {
  queryFn?: QueryFn;
  // Wired by the Discord layer: factory that returns the per-channel attach_file sink.
  sendFileFor?: (guildId: string, channelId: string) => SendFileCallback;
  // Sibling factory: returns the per-channel share_document sink (path-only markdown →
  // Discord thread). Same in-process MCP plumbing as Claude via createMcpFileTool.
  shareDocumentFor?: (guildId: string, channelId: string) => ShareDocumentCallback;
  listSessionsFn?: ListSessionsFn;
}

// The `custom` backend: a Claude Code session whose env vars are extracted from the
// operator's shell aliases (kimi / claude). This lets a per-machine alias like
// `alias kimi='ANTHROPIC_BASE_URL=... ANTHROPIC_MODEL=... claude'` drive the Discord
// bot on that host without changing global config.
export class CustomMode implements AgentMode {
  readonly name = 'custom';

  readonly capabilities: Capabilities = {
    streaming: true,
    thinking: true,
    toolThreads: true,
    permissionPrompts: true,
    progress: false,
    transcript: false,
    sessionResume: true,
    fileAttach: true,
    fileDiff: true,
    usagePanel: true,
    permissionModes: [...CLAUDE_PERMISSION_MODES],
  };

  // The custom backend reuses the Claude SDK, so it shares Claude's UI vocabulary (§6).
  readonly catalog = claudeCatalog;

  private readonly deps: CustomModeDeps;

  constructor(deps: CustomModeDeps = {}) {
    this.deps = deps;
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    const { env: extracted, source, hasDangerousFlag } = resolveCustomEnv();
    this.warnIfDangerous(ctx, hasDangerousFlag, source);

    const env: Options['env'] = { ...process.env, ...extracted };
    const customCtx = { ...ctx, model: extracted.ANTHROPIC_MODEL ?? ctx.model };

    ctx.logger.info('custom backend env resolved', { source, keys: Object.keys(extracted) });
    return new CustomEnvSession(customCtx, { ...this.sessionDeps(ctx), env });
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    const { env: extracted, source, hasDangerousFlag } = resolveCustomEnv();
    this.warnIfDangerous(ctx, hasDangerousFlag, source);

    const env: Options['env'] = { ...process.env, ...extracted };
    const customCtx = { ...ctx, model: extracted.ANTHROPIC_MODEL ?? ctx.model };

    ctx.logger.info('custom backend env resolved for resume', { source, keys: Object.keys(extracted) });
    return new CustomEnvSession(customCtx, { ...this.sessionDeps(ctx), env, resumeId: sessionId });
  }

  async listResumable(ctx: ModeContext): Promise<ResumableSession[]> {
    const listSessionsFn = this.deps.listSessionsFn ?? (realListSessions as ListSessionsFn);
    try {
      const sessions = await listSessionsFn({ dir: ctx.cwd, limit: LIST_RESUMABLE_LIMIT });
      return sessions.map((s) => toResumable(s, ctx.cwd));
    } catch (err) {
      ctx.logger.warn('custom listResumable failed; returning empty', { err: String(err) });
      return [];
    }
  }

  private sessionDeps(ctx: ModeContext) {
    const sendFile = this.deps.sendFileFor?.(ctx.guildId, ctx.channelId);
    const shareDocument = this.deps.shareDocumentFor?.(ctx.guildId, ctx.channelId);
    return {
      ...(this.deps.queryFn !== undefined ? { queryFn: this.deps.queryFn } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
      ...(shareDocument !== undefined ? { shareDocument } : {}),
    };
  }

  private warnIfDangerous(ctx: ModeContext, hasDangerousFlag: boolean, source: string | undefined): void {
    if (hasDangerousFlag && ctx.permMode !== 'bypassPermissions') {
      ctx.logger.warn(
        'custom backend alias contains --dangerously-skip-permissions but permMode is not bypassPermissions',
        { source },
      );
    }
  }
}

function toResumable(info: SDKSessionInfo, fallbackCwd: string): ResumableSession {
  const session: ResumableSession = {
    sessionId: info.sessionId,
    cwd: info.cwd && info.cwd.length > 0 ? info.cwd : fallbackCwd,
  };
  const label = info.summary && info.summary.length > 0 ? info.summary : info.firstPrompt;
  if (label && label.length > 0) session.label = label;
  if (Number.isFinite(info.lastModified)) session.updatedAt = new Date(info.lastModified).toISOString();
  return session;
}
