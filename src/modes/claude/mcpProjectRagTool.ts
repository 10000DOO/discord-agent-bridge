import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tool, createSdkMcpServer } from '@anthropic-ai/claude-agent-sdk';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import type { Logger } from '../../core/contracts.js';
import { resolveCliCommand } from '../../core/resolveCli.js';

// In-process MCP server exposing a single `project_search` tool so Claude can
// query this project's local static RAG index (`.dab-index/`) for candidate
// files/symbols BEFORE reading them (docs/project-rag-generic-indexing.md
// R1/R5/R6, D6/P8). Mirrors mcpFileTool.ts's tool()+createSdkMcpServer()+zod
// pattern, with two deliberate differences:
//
//  1. Read-only (R6, §9): `dab rag query` never touches file contents or
//     calls an LLM/embedding API — it returns candidate paths/symbols/line
//     ranges only, never file bodies. Hence `readOnlyHint: true` (the
//     opposite of mcpFileTool's attach_file/share_document, which write to
//     Discord).
//  2. The actual `dab` CLI invocation is injected as `runDabRagQuery` so this
//     adapter never has to assume `dab rag query` exists yet — tests supply a
//     mock; only `defaultRunDabRagQuery` (the production wiring) shells out
//     for real.

export const PROJECT_SEARCH_TOOL_NAME = 'mcp__project_rag__project_search';

// Runs `dab <args>` and resolves with raw stdout (expected to be JSON, from
// `--json`). Injectable so tests never need the real `dab` binary.
export type RunDabRagQuery = (args: string[]) => Promise<string>;

export interface ProjectSearchResult {
  content: { type: 'text'; text: string }[];
  isError?: boolean;
}

// Builds the `dab rag query` argv and forwards it to the injected runner,
// returning its JSON stdout as-is (R6 — never file contents, just the
// index's candidate pointers). Extracted so it is directly unit-testable
// without reaching into MCP server internals (mirrors attachFileConfined in
// mcpFileTool.ts).
export async function projectSearchViaDabRag(
  cwd: string,
  runDabRagQuery: RunDabRagQuery,
  query: string,
  maxResults?: number,
  logger?: Logger,
): Promise<ProjectSearchResult> {
  const args = ['rag', 'query', '--project', cwd, '--json', '--term', query];
  if (maxResults !== undefined) {
    args.push('--limit-symbols', String(maxResults));
  }
  try {
    const stdout = await runDabRagQuery(args);
    return { content: [{ type: 'text', text: stdout }] };
  } catch (err) {
    logger?.error('project_search tool failed', { err: err instanceof Error ? err.message : String(err) });
    return {
      content: [
        {
          type: 'text',
          text: `Project RAG query failed: ${err instanceof Error ? err.message : String(err)}`,
        },
      ],
      isError: true,
    };
  }
}

export function createMcpProjectRagTool(cwd: string, runDabRagQuery: RunDabRagQuery, logger?: Logger) {
  const search = tool(
    'project_search',
    "Search this project's local static RAG index for candidate files/symbols BEFORE reading files. Returns candidate paths and pointers only, never file contents.",
    {
      query: z.string().describe('Search term, symbol name, or path fragment to look up in the project index'),
      maxResults: z
        .number()
        .min(1)
        .max(6)
        .optional()
        .describe('Max number of candidate symbols to return (defaults to the CLI\'s own limit)'),
    },
    async (args): Promise<CallToolResult> =>
      // ProjectSearchResult is a structural subset of CallToolResult; cast at this
      // one boundary, same as mcpFileTool.ts's attach_file/share_document handlers.
      (await projectSearchViaDabRag(cwd, runDabRagQuery, args.query, args.maxResults, logger)) as CallToolResult,
    { annotations: { readOnlyHint: true } },
  );

  return createSdkMcpServer({ name: 'project_rag', version: '1.0.0', tools: [search] });
}

const execFileAsync = promisify(execFile);

// Production wiring: shells out to the `dab` binary this bridge ships
// alongside (Swift executable target `dab`, swift/Package.swift:15). Resolved
// via resolveCliCommand the same way the Codex/Grok CLIs are (cliHelpCatalog.ts),
// since PATH is minimal under launchd/systemd.
export const defaultRunDabRagQuery: RunDabRagQuery = async (args) => {
  const cmd = resolveCliCommand('dab');
  const { stdout } = await execFileAsync(cmd, args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  return stdout;
};
