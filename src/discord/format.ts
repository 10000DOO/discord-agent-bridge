// Small formatting helpers shared by the renderers. Pure functions — no discord.js,
// no I/O — so they are trivially unit-testable. Discord's hard limits (2000 chars
// per message, 4096 per embed description) are respected here in one place.

// Discord hard limits.
export const MSG_LIMIT = 2000; // plain message content
export const EMBED_DESC_LIMIT = 4096; // embed description
export const THREAD_NAME_LIMIT = 100; // thread name

// Embed colors (ported from A4D COLORS; adapted names).
export const COLORS = {
  streaming: 0xfee75c, // yellow
  thinking: 0x9b59b6, // purple
  permission: 0xe67e22, // orange
  idle: 0x57f287, // green
  error: 0xed4245, // red
  stopped: 0xed4245, // red
} as const;

// Split text into Discord-message-sized chunks, preferring to break on newlines so
// code fences and paragraphs are not cut mid-line where avoidable. When a code fence
// (```) is left open at a chunk boundary, the chunk is closed with a ``` and the next
// chunk reopens it, so every chunk renders as balanced Markdown on its own. Text with
// no code fence keeps the plain split byte-for-byte. Never returns an empty array for a
// non-empty input; an empty input yields [].
export function chunkMessage(text: string, limit: number = MSG_LIMIT): string[] {
  if (text.length === 0) return [];
  if (text.length <= limit) return [text];
  const fenced = text.includes('```');
  const chunks: string[] = [];
  let rest = text;
  let carryFence: boolean = false; // a code fence left open by the previous chunk
  while (rest.length > 0) {
    const prefix = carryFence ? '```\n' : '';
    // Reserve room for the reopening prefix and a possible closing ``` so a finished
    // chunk (markers included) never exceeds the limit. Fence-free text reserves
    // nothing, so its output is identical to the plain newline split.
    const budget = limit - prefix.length - (fenced ? 4 : 0);
    let raw: string;
    if (rest.length <= budget) {
      raw = rest;
      rest = '';
    } else {
      // Prefer the last newline within the budget; fall back to a hard cut.
      const window = rest.slice(0, budget);
      const nl = window.lastIndexOf('\n');
      const cut = nl > 0 ? nl : budget;
      raw = rest.slice(0, cut);
      rest = rest.slice(cut).replace(/^\n/, '');
    }
    const fenceCount = (raw.match(/```/g) ?? []).length;
    const endsOpen: boolean = ((carryFence ? 1 : 0) + fenceCount) % 2 === 1;
    chunks.push(prefix + raw + (endsOpen ? '\n```' : ''));
    carryFence = endsOpen;
  }
  return chunks;
}

// Truncate a string to `max`, appending an ellipsis when it was cut. Used for embed
// descriptions (live stream preview) and thread names.
export function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  if (max <= 1) return text.slice(0, max);
  return text.slice(0, max - 1) + '…';
}

// A tool-call thread name from the tool + its input (§6). Ports A4D's per-tool
// summary heuristics; capped to Discord's 100-char thread-name limit.
export function toolThreadName(toolName: string, input: unknown): string {
  const summary = toolSummary(toolName, input);
  const name = summary ? `${toolName}: ${summary}` : toolName;
  return truncate(name, THREAD_NAME_LIMIT);
}

// A short, human summary of a tool's input for the thread name. Falls back to a
// clipped JSON stringify for unknown tools. Never throws on odd input.
export function toolSummary(toolName: string, input: unknown): string {
  const obj = isRecord(input) ? input : {};
  const str = (v: unknown): string | undefined => (typeof v === 'string' ? v : undefined);
  switch (toolName) {
    case 'Edit':
    case 'Write':
    case 'Read':
    case 'NotebookEdit':
      return str(obj.file_path) ?? str(obj.path) ?? '';
    case 'Bash':
      return (str(obj.command) ?? '').slice(0, 60);
    case 'Glob':
    case 'Grep':
      return str(obj.pattern) ?? '';
    case 'Agent':
    case 'Task':
      return str(obj.description) ?? (str(obj.prompt) ?? '').slice(0, 40);
    case 'WebSearch':
    case 'WebFetch':
      return str(obj.query) ?? str(obj.url) ?? '';
    default: {
      try {
        return JSON.stringify(input).slice(0, 60);
      } catch {
        return '';
      }
    }
  }
}

// Compact token count (1234 → "1.2K", 2_000_000 → "2.0M").
export function formatTokens(count: number): string {
  if (count >= 1_000_000) return `${(count / 1_000_000).toFixed(1)}M`;
  if (count >= 1_000) return `${(count / 1_000).toFixed(1)}K`;
  return String(count);
}

// Human duration: >=60s → "1.5m", else "12.3s".
export function formatDuration(ms: number): string {
  if (ms >= 60_000) return `${(ms / 60_000).toFixed(1)}m`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
