// Runtime slash-command catalog for the `claude.slashCommands` RPC (additive, v1).
// Session-scoped sibling of catalog.ts: the list is whatever THIS live session accepts
// (built-ins + user skills + plugin commands, all cwd-dependent), so it is read off the
// session's own query rather than a throwaway probe.

export interface SlashCommandEntry {
  // Backend-supplied name, verbatim: no leading '/', no namespace rewriting
  // ('ponytail:ponytail-help' stays as is).
  name: string;
  description: string;
  // Omitted when the SDK reports '' so the Host reads it as absent.
  argumentHint?: string;
}

export interface ClaudeSlashCommandsResult {
  commands: SlashCommandEntry[];
}

/** Normalize the SDK's SlashCommand[] to the wire shape. Skips unusable rows; never throws. */
export function toSlashCommandEntries(raw: unknown): SlashCommandEntry[] {
  if (!Array.isArray(raw)) return [];
  const out: SlashCommandEntry[] = [];
  for (const item of raw as unknown[]) {
    if (item === null || typeof item !== 'object') continue;
    const c = item as Record<string, unknown>;
    if (typeof c.name !== 'string' || c.name.length === 0) continue;
    const hint = typeof c.argumentHint === 'string' ? c.argumentHint.trim() : '';
    out.push({
      name: c.name,
      description: typeof c.description === 'string' ? c.description : '',
      ...(hint.length > 0 ? { argumentHint: hint } : {}),
    });
  }
  return out;
}
