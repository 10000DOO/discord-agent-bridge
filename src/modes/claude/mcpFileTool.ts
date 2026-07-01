import * as fs from 'node:fs';
import * as path from 'node:path';
import { tool, createSdkMcpServer } from '@anthropic-ai/claude-agent-sdk';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';

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

export const ATTACH_FILE_TOOL_NAME = 'mcp__discord__attach_file';

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

export function createMcpFileTool(workspaceRoot: string, sendFile: SendFileCallback) {
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

  return createSdkMcpServer({ name: 'discord', version: '1.0.0', tools: [attachFile] });
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
