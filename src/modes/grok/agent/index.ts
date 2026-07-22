import type {
  AgentMode,
  Capabilities,
  ModeContext,
  ModeSession,
  ResumableSession,
} from '../../../core/contracts.js';
import { grokCatalog, grokPermissionModes } from '../catalog.js';
import { GrokDiscovery } from '../discovery.js';
import { resolveGrokHome } from '../configSource.js';
import { GrokAcpSession, type CreateGrokAcpClient, type GrokAcpSessionDeps } from './acpSession.js';
import type { SendFileCallback, ShareDocumentCallback } from '../../claude/mcpFileTool.js';
import type { AttachGateway } from '../../../discord/attachGateway.js';

// The sole Grok backend: a long-lived `grok agent stdio` ACP conversation (formerly path B /
// `grok-agent`). The retired per-turn `grok -p` backend (path A / `grok`) is gone; persisted
// mode ids `grok` and `grok-agent` are migrated to `grok-build` on config/state load.
// Honest ACP capabilities: tool_call/tool_call_update → toolThreads/progress on; interactive
// tool approval → permissionPrompts on. Reuses the grok catalog and ~/.grok discovery.

// Injectable deps so tests drive the mode without a real `grok agent stdio` process or a real
// ~/.grok on disk. Defaults wire the real client/discovery.
export interface GrokBuildModeDeps {
  createClient?: CreateGrokAcpClient;
  discovery?: GrokDiscovery;
  // Wired by the Discord layer for subprocess attach_file MCP (requires attachGateway).
  sendFileFor?: (guildId: string, channelId: string) => SendFileCallback;
  attachGateway?: AttachGateway;
  // Sibling factory to sendFileFor for the subprocess share_document MCP tool (path-only
  // markdown → Discord thread over the loopback gateway; same funnel as the /doc slash).
  // Bound per session, same as sendFileFor; also requires attachGateway.
  shareDocumentFor?: (guildId: string, channelId: string) => ShareDocumentCallback;
}

export class GrokBuildMode implements AgentMode {
  readonly name = 'grok-build';

  readonly capabilities: Capabilities;

  // Reuse grok's model/permission/effort vocabulary.
  readonly catalog = grokCatalog;

  private readonly deps: GrokBuildModeDeps;

  constructor(deps: GrokBuildModeDeps = {}) {
    this.deps = deps;
    // fileAttach only when both a sendFile factory and the loopback gateway are wired.
    const fileAttach = deps.sendFileFor !== undefined && deps.attachGateway !== undefined;
    this.capabilities = {
      streaming: true, // agent_message_chunk deltas
      thinking: true, // agent_thought_chunk deltas
      toolThreads: true, // tool_call / tool_call_update → per-tool visibility
      permissionPrompts: true, // ACP supports interactive tool approval (Discord wire in WO-10)
      progress: true, // plan updates surface as progress (WO-11)
      transcript: false, // the answer rides the streaming path, not a post-hoc feed
      sessionResume: true, // session/load + session_search.sqlite discovery
      fileAttach,
      fileDiff: true, // Edit/Write name + path→file_path normalization for DiffView
      usagePanel: true, // emits context_usage from the prompt response _meta (totalTokens vs configSource.contextWindow) + costUsd
      // Dynamic from installed `grok --help` (permissionSource); fallback = full CLI list.
      permissionModes: grokPermissionModes(),
    };
  }

  async start(ctx: ModeContext): Promise<ModeSession> {
    return new GrokAcpSession(ctx, this.sessionDeps(ctx));
  }

  async resume(ctx: ModeContext, sessionId: string): Promise<ModeSession> {
    return new GrokAcpSession(ctx, { ...this.sessionDeps(ctx), resumeId: sessionId });
  }

  // List resumable sessions from session_search.sqlite under the grok home (GROK_HOME-aware),
  // filtered to the browsed cwd.
  async listResumable(ctx: ModeContext): Promise<ResumableSession[]> {
    return this.discovery(ctx).listResumable(resolveGrokHome(), ctx.cwd);
  }

  private sessionDeps(ctx: ModeContext): GrokAcpSessionDeps {
    const sendFile = this.deps.sendFileFor?.(ctx.guildId, ctx.channelId);
    const shareDocument = this.deps.shareDocumentFor?.(ctx.guildId, ctx.channelId);
    return {
      ...(this.deps.createClient !== undefined ? { createClient: this.deps.createClient } : {}),
      ...(sendFile !== undefined ? { sendFile } : {}),
      ...(this.deps.attachGateway !== undefined ? { attachGateway: this.deps.attachGateway } : {}),
      ...(shareDocument !== undefined ? { shareDocument } : {}),
    };
  }

  private discovery(ctx: ModeContext): GrokDiscovery {
    return this.deps.discovery ?? new GrokDiscovery({ logger: ctx.logger });
  }
}
