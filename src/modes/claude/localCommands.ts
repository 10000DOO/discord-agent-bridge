// Terminal-only slash-command output, reconstructed for the bridge.
//
// Some of Claude Code's slash commands are handled by the CLI itself, not the model, and their
// real output is DRAWN BY ITS INTERACTIVE UI. Ask for one over the SDK and you get either a
// one-line summary (`/mcp`) or a refusal (`/status isn't available in this environment.`) — the
// bridge is not swallowing anything, that is the whole reply.
//
// Every fact those commands would have shown, however, already arrives here: the SDK's `init`
// message carries the version, cwd, model, permission mode, MCP servers and counts, and
// getContextUsage() carries the loaded memory files. So the answer is rebuilt from what we hold
// and substituted for the stub, laid out like the terminal's own screens.
//
// Deliberately NOT rebuilt (no data, and guessing would be worse than the stub):
//   /doctor, /permissions, /hooks, /agents — install health and rule/hook tables the SDK never
//   reports. `/agents` already answers for itself; `/context`, `/cost` and `/usage` come back in
//   full and are left untouched.

/** Everything the rebuilt screens need. Filled from `init`, topped up at each result. */
export interface ClaudeSessionFacts {
  version?: string;
  cwd?: string;
  sessionId?: string;
  model?: string;
  modelDisplayName?: string;
  permissionMode?: string;
  apiKeySource?: string;
  outputStyle?: string;
  mcpServers?: { name: string; status: string }[];
  skills?: string[];
  plugins?: { name: string; path: string; version?: string }[];
  toolCount?: number;
  agentCount?: number;
  commandCount?: number;
  memoryFiles?: { path: string; type: string; tokens: number }[];
  totalTokens?: number;
  maxTokens?: number;
}

// The CLI's refusal for a command whose output only exists inside its own UI. It names the
// command, so no prompt tracking is needed to know what was asked for.
const UNAVAILABLE = /^\/([a-z][a-z0-9-]*) isn't available in this environment\.?\s*$/i;

// `/mcp`'s summary line, which we extend rather than replace.
const MCP_SUMMARY = /MCP server\(s\):/;

/**
 * The reply to deliver for `text`: the rebuilt screen when this is a stub we can answer, the
 * summary plus the server list for `/mcp`, otherwise `text` unchanged.
 *
 * Everything is best-effort by design — an unknown command, a fact we never received, or a
 * reworded CLI message all fall through to the original text. This never throws and never
 * invents a value it was not given.
 */
export function rebuildLocalCommandOutput(text: string, facts: ClaudeSessionFacts): string {
  const stub = UNAVAILABLE.exec(text.trim());
  if (stub) {
    const rebuilt = rebuildScreen(stub[1]!.toLowerCase(), facts);
    return rebuilt ?? text;
  }
  if (MCP_SUMMARY.test(text)) {
    const list = mcpScreen(facts);
    return list ? `${text.trimEnd()}\n\n${list}` : text;
  }
  return text;
}

function rebuildScreen(command: string, facts: ClaudeSessionFacts): string | undefined {
  switch (command) {
    case 'status':
      return statusScreen(facts);
    case 'memory':
      return memoryScreen(facts);
    case 'mcp':
      return mcpScreen(facts);
    case 'skills':
      return listScreen('Skills', facts.skills);
    case 'plugin':
      return listScreen(
        'Plugins',
        facts.plugins?.map((p) => (p.version ? `${p.name} (${p.version})` : p.name)),
      );
    default:
      return undefined;
  }
}

// A terminal screen, in a code fence so Discord shows it in the monospace box the output was
// laid out for. Returns undefined for a screen with no rows at all — a heading over nothing is
// worse than the CLI's own message.
function screen(title: string, lines: string[]): string | undefined {
  if (lines.length === 0) return undefined;
  return ['```', title, '', ...lines, '```'].join('\n');
}

function statusScreen(facts: ClaudeSessionFacts): string | undefined {
  const rows: string[] = [];
  const add = (label: string, value: string | undefined) => {
    if (value !== undefined && value.length > 0) rows.push(`  ${label.padEnd(18)}${value}`);
  };
  add('Working directory', facts.cwd);
  add('Model', modelLine(facts));
  add('Permission mode', facts.permissionMode);
  add('Auth', facts.apiKeySource === 'none' ? 'subscription / logged in' : facts.apiKeySource);
  add('Output style', facts.outputStyle);
  add('Session', facts.sessionId);
  add('Context', contextLine(facts));
  add('Loaded', loadedLine(facts));
  add('MCP servers', mcpStatusLine(facts));
  return screen(`Claude Code Status${facts.version ? ` v${facts.version}` : ''}`, rows);
}

function modelLine(facts: ClaudeSessionFacts): string | undefined {
  if (!facts.model) return undefined;
  return facts.modelDisplayName ? `${facts.model} (${facts.modelDisplayName})` : facts.model;
}

function contextLine(facts: ClaudeSessionFacts): string | undefined {
  const { totalTokens, maxTokens } = facts;
  if (totalTokens === undefined || maxTokens === undefined || maxTokens <= 0) return undefined;
  return `${tokens(totalTokens)} / ${tokens(maxTokens)} (${Math.round((totalTokens / maxTokens) * 100)}%)`;
}

function loadedLine(facts: ClaudeSessionFacts): string | undefined {
  const parts: string[] = [];
  if (facts.toolCount !== undefined) parts.push(`${facts.toolCount} tools`);
  if (facts.commandCount !== undefined) parts.push(`${facts.commandCount} commands`);
  if (facts.skills !== undefined) parts.push(`${facts.skills.length} skills`);
  if (facts.agentCount !== undefined) parts.push(`${facts.agentCount} agents`);
  if (facts.plugins !== undefined) parts.push(`${facts.plugins.length} plugins`);
  if (facts.memoryFiles !== undefined) {
    parts.push(`${facts.memoryFiles.length} memory file${facts.memoryFiles.length === 1 ? '' : 's'}`);
  }
  return parts.length > 0 ? parts.join(' · ') : undefined;
}

function mcpStatusLine(facts: ClaudeSessionFacts): string | undefined {
  const servers = facts.mcpServers;
  if (!servers || servers.length === 0) return undefined;
  const connected = servers.filter((s) => s.status === 'connected').length;
  return `${connected}/${servers.length} connected`;
}

// `/skills` and `/plugin` are both just "what is loaded", which init reports by name.
function listScreen(title: string, items: string[] | undefined): string | undefined {
  if (!items || items.length === 0) return undefined;
  return screen(`${title} (${items.length})`, items.map((i) => `  • ${i}`));
}

function memoryScreen(facts: ClaudeSessionFacts): string | undefined {
  const files = facts.memoryFiles;
  if (!files || files.length === 0) return undefined;
  return screen(
    'Memory Files',
    files.map((f) => `  • ${f.type}: ${f.path} (${tokens(f.tokens)} tokens)`),
  );
}

function mcpScreen(facts: ClaudeSessionFacts): string | undefined {
  const servers = facts.mcpServers;
  if (!servers || servers.length === 0) return undefined;
  const width = Math.max(...servers.map((s) => s.name.length));
  return screen(
    `MCP Server Status (${servers.length} configured, at session start)`,
    servers.map((s) => `  ${statusMark(s.status)} ${s.name.padEnd(width)}  ${statusText(s.status)}`),
  );
}

// The CLI's own vocabulary for each state, so the rebuilt screen reads like the real one. An
// unknown status is shown verbatim rather than mapped to a guess.
function statusText(status: string): string {
  switch (status) {
    case 'connected':
      return 'connected';
    case 'pending':
      return 'connecting';
    case 'needs-auth':
      return 'needs authentication';
    case 'failed':
      return 'failed';
    case 'disabled':
      return 'disabled';
    default:
      return status;
  }
}

function statusMark(status: string): string {
  switch (status) {
    case 'connected':
      return '✔';
    case 'pending':
      return '…';
    case 'disabled':
      return '·';
    default:
      return '✘';
  }
}

// 26400 → '26.4k', 200000 → '200k'. Matches the CLI's own token formatting.
function tokens(n: number): string {
  if (n < 1000) return String(n);
  return `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k`;
}
