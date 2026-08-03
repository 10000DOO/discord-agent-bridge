import { describe, it, expect, vi } from 'vitest';
import {
  PROJECT_SEARCH_TOOL_NAME,
  createMcpProjectRagTool,
  projectSearchViaDabRag,
  type RunDabRagQuery,
} from './mcpProjectRagTool.js';

describe('PROJECT_SEARCH_TOOL_NAME', () => {
  it('is the mcp__project_rag__project_search SDK tool name', () => {
    expect(PROJECT_SEARCH_TOOL_NAME).toBe('mcp__project_rag__project_search');
  });
});

describe('projectSearchViaDabRag', () => {
  it('forwards a --project/--json/--term argv to the injected runner and returns its stdout as-is (R6: no file contents)', async () => {
    const stdoutJson = JSON.stringify({ modules: [], symbols: [], freshness: 'fresh' });
    const runDabRagQuery: RunDabRagQuery = vi.fn(async () => stdoutJson);

    const result = await projectSearchViaDabRag('/ws/project', runDabRagQuery, 'ProjectRagCoordinator');

    expect(runDabRagQuery).toHaveBeenCalledWith([
      'rag',
      'query',
      '--project',
      '/ws/project',
      '--json',
      '--term',
      'ProjectRagCoordinator',
    ]);
    expect(result).toEqual({ content: [{ type: 'text', text: stdoutJson }] });
  });

  it('appends --limit-symbols when maxResults is given', async () => {
    const runDabRagQuery: RunDabRagQuery = vi.fn(async () => '{}');

    await projectSearchViaDabRag('/ws/project', runDabRagQuery, 'foo', 3);

    expect(runDabRagQuery).toHaveBeenCalledWith([
      'rag',
      'query',
      '--project',
      '/ws/project',
      '--json',
      '--term',
      'foo',
      '--limit-symbols',
      '3',
    ]);
  });

  it('degrades to a neutral isError result and logs when the runner rejects (dab CLI missing/broken)', async () => {
    const runDabRagQuery: RunDabRagQuery = vi.fn(async () => {
      throw new Error('spawn dab ENOENT');
    });
    const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() };

    const result = await projectSearchViaDabRag('/ws/project', runDabRagQuery, 'foo', undefined, logger);

    expect(result.isError).toBe(true);
    expect(result.content[0]?.text).toContain('spawn dab ENOENT');
    expect(logger.error).toHaveBeenCalledWith(
      'project_search tool failed',
      expect.objectContaining({ err: 'spawn dab ENOENT' }),
    );
  });
});

describe('createMcpProjectRagTool', () => {
  it('registers a project_rag SDK server carrying the project_search tool', () => {
    const runDabRagQuery: RunDabRagQuery = vi.fn(async () => '{}');

    const server = createMcpProjectRagTool('/ws/project', runDabRagQuery);

    expect(server.type).toBe('sdk');
    expect(server.name).toBe('project_rag');
  });
});
