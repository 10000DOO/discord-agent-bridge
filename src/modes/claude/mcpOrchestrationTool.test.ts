import { describe, it, expect, vi } from 'vitest';
import {
  SEND_ORDER_TOOL_NAME,
  REPORT_TOOL_NAME,
  sendOrderViaHost,
  reportViaHost,
  createSendOrderTool,
  createReportTool,
  type SendOrderCallback,
  type ReportCallback,
} from './mcpOrchestrationTool.js';

describe('tool names', () => {
  it('are the mcp__discord__* SDK tool names (D4: joins the discord server)', () => {
    expect(SEND_ORDER_TOOL_NAME).toBe('mcp__discord__send_order');
    expect(REPORT_TOOL_NAME).toBe('mcp__discord__report');
  });
});

describe('sendOrderViaHost', () => {
  it('forwards args to the host callback and returns its sentence as-is', async () => {
    const sendOrder: SendOrderCallback = vi.fn(async () => 'Order delivered to #agent-core.');

    const result = await sendOrderViaHost(sendOrder, 'core', '/ws/core', 'implement #1234', '1234');

    expect(sendOrder).toHaveBeenCalledWith('core', '/ws/core', 'implement #1234', '1234');
    expect(result).toEqual({ content: [{ type: 'text', text: 'Order delivered to #agent-core.' }] });
  });

  it('omits the optional issue when not given', async () => {
    const sendOrder: SendOrderCallback = vi.fn(async () => 'ok');
    await sendOrderViaHost(sendOrder, 'core', '/ws/core', 'go');
    expect(sendOrder).toHaveBeenCalledWith('core', '/ws/core', 'go', undefined);
  });

  it('maps a thrown host error to isError:true without inventing wording', async () => {
    const sendOrder: SendOrderCallback = vi.fn(async () => {
      throw new Error('busy: #agent-core is mid-turn');
    });
    const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() };

    const result = await sendOrderViaHost(sendOrder, 'core', '/ws/core', 'go', undefined, logger);

    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain('busy: #agent-core is mid-turn');
    expect(logger.error).toHaveBeenCalledWith(
      'send_order tool failed',
      expect.objectContaining({ err: 'busy: #agent-core is mid-turn' }),
    );
  });
});

describe('reportViaHost', () => {
  it('forwards text/marker to the host callback and returns its sentence as-is', async () => {
    const report: ReportCallback = vi.fn(async () => 'Report relayed to #orc-myproj.');

    const result = await reportViaHost(report, 'done', 'DONE');

    expect(report).toHaveBeenCalledWith('done', 'DONE');
    expect(result).toEqual({ content: [{ type: 'text', text: 'Report relayed to #orc-myproj.' }] });
  });

  it('maps a thrown host error to isError:true', async () => {
    const report: ReportCallback = vi.fn(async () => {
      throw new Error('wrong role: report is module-only');
    });

    const result = await reportViaHost(report, 'done');

    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain('wrong role: report is module-only');
  });
});

// ---- D11 regression: no spec-override arguments -------------------------------
// design_orchestration_module_agents.md D11: the human fixes backend/model/effort/
// permMode in the start card; send_order must never expose a way for the
// orchestrator LLM to override them. report must never expose a target-channel
// argument (R4) — routing is always back to the caller's own orchestrator channel.

describe('createSendOrderTool — schema (D11 regression)', () => {
  it('exposes exactly module/path/text/issue — no backend/model/effort/permMode', () => {
    const toolDef = createSendOrderTool(async () => 'ok');
    const keys = Object.keys(toolDef.inputSchema);

    expect(keys.sort()).toEqual(['issue', 'module', 'path', 'text']);
    for (const forbidden of ['backend', 'model', 'effort', 'permMode']) {
      expect(keys).not.toContain(forbidden);
    }
    expect(toolDef.name).toBe('send_order');
  });
});

describe('createReportTool — schema', () => {
  it('exposes exactly text/marker — no target-channel argument (R4)', () => {
    const toolDef = createReportTool(async () => 'ok');
    const keys = Object.keys(toolDef.inputSchema);

    expect(keys.sort()).toEqual(['marker', 'text']);
    for (const forbidden of ['channel', 'channelId', 'target', 'to']) {
      expect(keys).not.toContain(forbidden);
    }
    expect(toolDef.name).toBe('report');
  });
});
