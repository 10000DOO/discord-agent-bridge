import * as fs from 'node:fs';
import * as path from 'node:path';
import { tool, createSdkMcpServer } from '@anthropic-ai/claude-agent-sdk';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import type { Logger } from '../../core/contracts.js';
import type { ShareResult } from '../../discord/documentShare.js';

// In-process MCP server exposing a single `attach_file` tool so Claude can push a
// file into the Discord channel this session is bound to (§5a, §7.5). Two
// deliberate boundaries:
//
//  1. Transport-agnostic. The actual Discord send is an injected callback wired by
//     the Discord layer later; this module never imports discord.js so modes stay
//     transport-agnostic.
//  2. Path-confined. Every requested path is realpath-resolved and must stay
//     inside the session workspace root (fixes A5). A path escaping the root is
//     rejected before the callback runs — the confinement is enforced here, at the
//     file-open site, not only in the orchestrator's pre-filter.
//
// The exposed SDK tool name is `mcp__discord__attach_file`; add it to allowedTools
// so it is auto-allowed like any other configured tool.

// Sends the confined file to the channel; returns a human-readable confirmation.
// Throws on failure (too large, not found, transport error) — the caller turns a
// throw into an MCP error result rather than crashing the session.
export type SendFileCallback = (absPath: string, filename?: string) => Promise<string>;

// Shares a markdown document from the session workspace into a Discord thread. The
// injected callback (wired by the Discord layer via SessionWiring.shareDocumentFor)
// does the path confinement, read, and thread post itself and returns the structured
// ShareResult. It resolves for the five known rejection causes (ShareResult.code) but
// MAY reject for anything else the core rethrows (EACCES, a post failure) — the tool
// handler turns a rejection into a neutral notice rather than crashing the session.
export type ShareDocumentCallback = (path: string) => Promise<ShareResult>;

export const ATTACH_FILE_TOOL_NAME = 'mcp__discord__attach_file';
export const SHARE_DOCUMENT_TOOL_NAME = 'mcp__discord__share_document';

// The MCP tool-result shape we return (a subset of CallToolResult).
export interface AttachFileResult {
  content: { type: 'text'; text: string }[];
  isError?: boolean;
}

// The confinement + send core, extracted so it is directly unit-testable without
// reaching into MCP server internals. Resolves `requestedPath` against the
// workspace root, rejects anything that escapes it, then forwards to `sendFile`.
export async function attachFileConfined(
  workspaceRoot: string,
  sendFile: SendFileCallback,
  requestedPath: string,
  filename?: string,
): Promise<AttachFileResult> {
  const root = realpathOrResolve(workspaceRoot);
  try {
    const resolved = realpathOrResolve(path.resolve(root, requestedPath));
    if (!isWithin(root, resolved)) {
      return {
        content: [
          {
            type: 'text',
            text: `Refused: "${requestedPath}" is outside the session workspace and cannot be attached.`,
          },
        ],
        isError: true,
      };
    }
    const result = await sendFile(resolved, filename);
    return { content: [{ type: 'text', text: result }] };
  } catch (err) {
    return {
      content: [
        {
          type: 'text',
          text: `Failed to attach file: ${err instanceof Error ? err.message : String(err)}`,
        },
      ],
      isError: true,
    };
  }
}

export function createMcpFileTool(
  workspaceRoot: string,
  sendFile: SendFileCallback,
  shareDocument?: ShareDocumentCallback,
  logger?: Logger,
) {
  const attachFile = tool(
    'attach_file',
    'Send a file to the current Discord channel where this session is running. Use this whenever the user asks you to attach, send, share, or upload a file to Discord. The file must already exist on the local filesystem and must be inside the session workspace — create it there first with Write or Bash if needed, then call this tool.',
    {
      path: z.string().describe('Path to the file to send (inside the session workspace)'),
      filename: z
        .string()
        .optional()
        .describe('Override the display filename (defaults to the basename of path)'),
    },
    async (args): Promise<CallToolResult> =>
      // AttachFileResult is a structural subset of CallToolResult; the only gap is
      // CallToolResult's open index signature, so cast at this one boundary.
      (await attachFileConfined(workspaceRoot, sendFile, args.path, args.filename)) as CallToolResult,
    { annotations: { readOnlyHint: false } },
  );

  // Widen to the server's tool-array type so tools with different input schemas
  // (attach_file has {path, filename}; share_document has {path}) coexist.
  const tools: NonNullable<Parameters<typeof createSdkMcpServer>[0]['tools']> = [attachFile];

  // PATH-ONLY (D2): the tool takes only a path — the bot reads the file itself and the
  // result is a short confirmation, never the document body, so token cost is constant
  // regardless of document size. Registered on the SAME `discord` server as attach_file
  // whenever the Discord layer wires a shareDocument sink for this session.
  if (shareDocument) {
    const shareDoc = tool(
      'share_document',
      'Post a markdown document from the workspace into a Discord thread.',
      {
        path: z.string().describe('Path to the markdown file to share (inside the session workspace)'),
      },
      async (args): Promise<CallToolResult> =>
        (await shareDocumentResult(shareDocument, args.path, logger)) as CallToolResult,
      { annotations: { readOnlyHint: false } },
    );
    tools.push(shareDoc);
  }

  return createSdkMcpServer({ name: 'discord', version: '1.0.0', tools });
}

// Run the injected share and map the structured ShareResult onto a concise,
// model-facing confirmation string (PATH-ONLY — never the document body, D2). Known
// rejections come back as ShareResult.code; anything the core rethrows (EACCES, a post
// failure) is caught here so it degrades to a neutral notice instead of crashing the
// session — and the raw error / absolute path is NEVER surfaced to the model (it is
// logged server-side instead). Extracted so the mapping is directly unit-testable
// without reaching into MCP server internals. The strings are model-facing, so they
// stay neutral English rather than using the user-facing t() catalog.
export async function shareDocumentResult(
  shareDocument: ShareDocumentCallback,
  requestedPath: string,
  logger?: Logger,
): Promise<AttachFileResult> {
  try {
    const res = await shareDocument(requestedPath);
    if (res.ok) {
      const threadName = res.threadName ?? res.path ?? requestedPath;
      return { content: [{ type: 'text', text: `Shared "${res.path ?? requestedPath}" to thread ${threadName}` }] };
    }
    return { content: [{ type: 'text', text: shareErrorText(requestedPath, res) }], isError: true };
  } catch (err) {
    logger?.error('share_document tool failed', { err: err instanceof Error ? err.message : String(err) });
    return { content: [{ type: 'text', text: `Could not share ${requestedPath}: unexpected error` }], isError: true };
  }
}

// A short, neutral reason line for a failed share. A coded rejection maps to its cause;
// an uncoded failure is the wiring backstop (no live session/sink for this channel).
function shareErrorText(requestedPath: string, res: ShareResult): string {
  const prefix = `Could not share ${requestedPath}: `;
  switch (res.code) {
    case 'notMarkdown':
      return prefix + 'not a markdown file';
    case 'notFound':
      return prefix + 'file not found';
    case 'tooLarge':
      return prefix + `too large (${res.max ?? 'limit exceeded'})`;
    case 'escape':
      return prefix + 'outside the workspace';
    case 'notFile':
      return prefix + 'not a file';
    default:
      return prefix + 'no active session for this channel';
  }
}

// Realpath a path, falling back to the realpath of its deepest existing ancestor
// joined with the non-existent tail — so confinement holds for paths that do not
// exist yet while still resolving symlinks in the part that does. Mirrors the
// orchestrator's baseline approach (sessionOrchestrator.ts) at the mode's own
// file-open site.
function realpathOrResolve(target: string): string {
  const abs = path.resolve(target);
  let existing = abs;
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break; // reached the filesystem root
    tail.unshift(path.basename(existing));
    existing = parent;
  }
  try {
    const realExisting = fs.realpathSync(existing);
    return tail.length > 0 ? path.join(realExisting, ...tail) : realExisting;
  } catch {
    return abs;
  }
}

// True when `child` is the same as, or nested under, `root`. Uses path.relative so
// it is not fooled by shared string prefixes (e.g. /ws vs /ws-evil).
function isWithin(root: string, child: string): boolean {
  const rel = path.relative(root, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
