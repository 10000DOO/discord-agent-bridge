import { tool } from '@anthropic-ai/claude-agent-sdk';
import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import type { Logger } from '../../core/contracts.js';

// Two in-process MCP tools for the orchestration star topology
// (design_orchestration_module_agents.md R4/R5, D4/D11): `send_order`
// (orchestrator → module) and `report` (module → orchestrator). Both join the
// existing `discord` SDK server (mcpFileTool.ts's tools array) instead of a new
// server — D4 decided one shared server so tool names stay `mcp__discord__*`
// and `allowedTools` management stays simple. This module only builds the tool
// objects and the pure logic behind them; mcpFileTool.ts owns the actual
// createSdkMcpServer() call.
//
// Deliberately absent from `send_order`'s schema: backend/model/effort/permMode.
// The human already fixed those in the start card (WO-10, D11) — the only source
// of truth — so the orchestrator LLM has no argument through which to raise the
// module tier itself. Deliberately absent from `report`: a target-channel
// argument (R4) — routing is always back to the caller's own orchestrator
// channel, enforced host-side, never selectable by argument.
//
// Both tool handlers forward the host's decision sentence verbatim (mirrors
// host.file.attach's onFileAttach: resolve with the sentence, or throw on
// failure) — all judgment (path confinement, busy/concurrency/round-trip
// limits, role checks) happens in OrchestrationHost (Swift); this module never
// invents wording.

export const SEND_ORDER_TOOL_NAME = 'mcp__discord__send_order';
export const REPORT_TOOL_NAME = 'mcp__discord__report';

/** host.orchestration.order — resolves with the host's sentence, or throws on failure. */
export type SendOrderCallback = (
  module: string,
  path: string,
  text: string,
  issue?: string,
) => Promise<string>;

/** host.orchestration.report — resolves with the host's sentence, or throws on failure. */
export type ReportCallback = (text: string, marker?: string) => Promise<string>;

export interface OrchestrationToolResult {
  content: { type: 'text'; text: string }[];
  isError?: boolean;
}

// The round-trip + error mapping core, extracted so it is directly unit-testable
// without reaching into MCP server internals (mirrors attachFileConfined in
// mcpFileTool.ts). The host's sentence is returned as-is; only a thrown error
// (transport failure, or "not wired for session") becomes isError:true.
export async function sendOrderViaHost(
  sendOrder: SendOrderCallback,
  module: string,
  path: string,
  text: string,
  issue?: string,
  logger?: Logger,
): Promise<OrchestrationToolResult> {
  try {
    const message = await sendOrder(module, path, text, issue);
    return { content: [{ type: 'text', text: message }] };
  } catch (err) {
    logger?.error('send_order tool failed', { err: err instanceof Error ? err.message : String(err) });
    return {
      content: [
        { type: 'text', text: `send_order failed: ${err instanceof Error ? err.message : String(err)}` },
      ],
      isError: true,
    };
  }
}

export async function reportViaHost(
  report: ReportCallback,
  text: string,
  marker?: string,
  logger?: Logger,
): Promise<OrchestrationToolResult> {
  try {
    const message = await report(text, marker);
    return { content: [{ type: 'text', text: message }] };
  } catch (err) {
    logger?.error('report tool failed', { err: err instanceof Error ? err.message : String(err) });
    return {
      content: [{ type: 'text', text: `report failed: ${err instanceof Error ? err.message : String(err)}` }],
      isError: true,
    };
  }
}

// The three report outcome markers the module-agent role file specifies
// (design_orchestration_module_agents.md 3-7 ORCHESTRATOR/MODULE_AGENT roles).
const REPORT_MARKERS = ['DONE', 'IMPL_BLOCKED', 'COMMON_MODULE_HANDOFF'] as const;

export function createSendOrderTool(sendOrder: SendOrderCallback, logger?: Logger) {
  return tool(
    'send_order',
    'Send a work order to a module agent channel. ORCHESTRATOR ROLE ONLY — calling this from a ' +
      "module channel is rejected. Creates the module's channel on first use (reused after). The " +
      "module session's model and reasoning effort were fixed by a human at session start and " +
      'CANNOT be set here — never invent backend/model/effort/permMode arguments; there are none.',
    {
      module: z.string().describe('Module name (its channel is agent-<module>)'),
      path: z.string().describe('Path to the module folder'),
      text: z.string().describe("The order text; delivered as the module agent's next turn"),
      issue: z.string().optional().describe('Issue number/id, if this order is tied to one'),
    },
    async (args): Promise<CallToolResult> =>
      // OrchestrationToolResult is a structural subset of CallToolResult; cast at this
      // one boundary, same as mcpFileTool.ts's attach_file/share_document handlers.
      (await sendOrderViaHost(sendOrder, args.module, args.path, args.text, args.issue, logger)) as CallToolResult,
    { annotations: { readOnlyHint: false } },
  );
}

export function createReportTool(report: ReportCallback, logger?: Logger) {
  return tool(
    'report',
    'Report progress or completion back to the orchestrator. MODULE AGENT ROLE ONLY — calling ' +
      "this from the orchestrator channel is rejected. Always routes to this module's own " +
      'orchestrator channel; there is no target-channel argument.',
    {
      text: z.string().describe('Report text for the orchestrator'),
      marker: z.enum(REPORT_MARKERS).optional().describe('Outcome marker, if applicable'),
    },
    async (args): Promise<CallToolResult> =>
      (await reportViaHost(report, args.text, args.marker, logger)) as CallToolResult,
    { annotations: { readOnlyHint: false } },
  );
}
