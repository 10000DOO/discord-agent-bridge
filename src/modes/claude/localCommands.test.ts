import { describe, expect, it } from 'vitest';
import { rebuildLocalCommandOutput, type ClaudeSessionFacts } from './localCommands.js';

// Verbatim CLI replies, captured from `claude -p "/<cmd>" --output-format stream-json` against
// 2.1.223 — the whole point of this module is that these two shapes are all we ever get.
const MCP_SUMMARY =
  '32 MCP server(s): 3 connected, 2 connecting, 27 not connected, 0 disabled. Use `/mcp` in the terminal for details.';
const STATUS_STUB = "/status isn't available in this environment.";

const FACTS: ClaudeSessionFacts = {
  version: '2.1.223',
  cwd: '/Volumes/SourceCode/Sample/discord-agent-bridge',
  sessionId: 'f8e9e999-fe16-44ba-8a2c-d05fb42fbf07',
  model: 'claude-opus-5[1m]',
  modelDisplayName: 'Opus 5 (1M context)',
  permissionMode: 'default',
  apiKeySource: 'none',
  outputStyle: 'default',
  mcpServers: [
    { name: 'codegraph', status: 'connected' },
    { name: 'claude.ai Figma', status: 'pending' },
    { name: 'plugin:discord:discord', status: 'failed' },
    { name: 'claude.ai Slack', status: 'needs-auth' },
  ],
  toolCount: 127,
  commandCount: 85,
  skills: ['cocoa-patterns', 'ponytail:ponytail'],
  plugins: [{ name: 'ponytail', path: '/p/ponytail', version: '1.2.0' }, { name: 'discord', path: '/p/discord' }],
  agentCount: 14,
  memoryFiles: [{ path: '/Users/x/.claude/CLAUDE.md', type: 'user', tokens: 2300 }],
  totalTokens: 26400,
  maxTokens: 200000,
};

describe('rebuildLocalCommandOutput', () => {
  it('appends the server list to /mcp\'s summary instead of replacing it', () => {
    const out = rebuildLocalCommandOutput(MCP_SUMMARY, FACTS);
    expect(out.startsWith(MCP_SUMMARY)).toBe(true);
    expect(out).toContain('MCP Server Status (4 configured, at session start)');
    expect(out).toContain('codegraph');
    // Each raw status becomes the CLI's own wording.
    expect(out).toContain('connecting');
    expect(out).toContain('needs authentication');
    expect(out).toContain('failed');
  });

  it('rebuilds the /status screen the CLI refuses to draw', () => {
    const out = rebuildLocalCommandOutput(STATUS_STUB, FACTS);
    expect(out).toContain('Claude Code Status v2.1.223');
    expect(out).toContain('/Volumes/SourceCode/Sample/discord-agent-bridge');
    expect(out).toContain('claude-opus-5[1m] (Opus 5 (1M context))');
    expect(out).toContain('26.4k / 200k (13%)');
    expect(out).toContain('1/4 connected');
    expect(out).toContain('127 tools');
  });

  it('rebuilds /memory from the loaded memory files', () => {
    const out = rebuildLocalCommandOutput("/memory isn't available in this environment.", FACTS);
    expect(out).toContain('Memory Files');
    expect(out).toContain('user: /Users/x/.claude/CLAUDE.md (2.3k tokens)');
  });

  it('rebuilds /skills and /plugin from what init reported as loaded', () => {
    const skills = rebuildLocalCommandOutput("/skills isn't available in this environment.", FACTS);
    expect(skills).toContain('Skills (2)');
    expect(skills).toContain('• cocoa-patterns');

    const plugins = rebuildLocalCommandOutput("/plugin isn't available in this environment.", FACTS);
    expect(plugins).toContain('Plugins (2)');
    // A plugin.json version is shown when the manifest declares one, omitted when it does not.
    expect(plugins).toContain('• ponytail (1.2.0)');
    expect(plugins).toContain('• discord');
  });

  // Every miss must fall through to the backend's own words rather than an empty or invented
  // screen: a command we cannot rebuild, and a session that never reported the facts.
  it('leaves text alone when it cannot do better', () => {
    const doctor = "/doctor isn't available in this environment.";
    expect(rebuildLocalCommandOutput(doctor, FACTS)).toBe(doctor);
    expect(rebuildLocalCommandOutput(STATUS_STUB, {})).toBe(STATUS_STUB);
    expect(rebuildLocalCommandOutput(MCP_SUMMARY, {})).toBe(MCP_SUMMARY);
    expect(rebuildLocalCommandOutput('## Context Usage\n\n**Tokens:** 1', FACTS)).toBe(
      '## Context Usage\n\n**Tokens:** 1',
    );
  });

  it('shows an unknown server status verbatim rather than guessing', () => {
    const out = rebuildLocalCommandOutput(MCP_SUMMARY, {
      mcpServers: [{ name: 'weird', status: 'reconnecting-soon' }],
    });
    expect(out).toContain('reconnecting-soon');
  });
});
