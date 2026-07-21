// Parse clap-style CLI help fragments of the form `[possible values: a, b, c]`.
// Used by Codex/Grok permission sources to discover installed-CLI option catalogs
// without hardcoding only. Case-insensitive on the "possible values" label; value
// tokens are returned as written (trimmed). Fail-safe: malformed text → [].

const POSSIBLE_VALUES_RE = /\[possible values:\s*([^\]]+)\]/gi;

/** Split a single "a, b, c" list into trimmed non-empty tokens. */
function splitValues(list: string): string[] {
  return list
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/** Extract values from the first clap-style `[possible values: a, b, c]` block. */
export function parsePossibleValues(text: string): string[] {
  if (typeof text !== 'string' || text.length === 0) return [];
  POSSIBLE_VALUES_RE.lastIndex = 0;
  const match = POSSIBLE_VALUES_RE.exec(text);
  if (!match?.[1]) return [];
  return splitValues(match[1]);
}

/** Extract every clap-style `[possible values: …]` block in document order. */
export function parseAllPossibleValueBlocks(text: string): string[][] {
  if (typeof text !== 'string' || text.length === 0) return [];
  const blocks: string[][] = [];
  POSSIBLE_VALUES_RE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = POSSIBLE_VALUES_RE.exec(text)) !== null) {
    const values = splitValues(match[1] ?? '');
    if (values.length > 0) blocks.push(values);
  }
  return blocks;
}

/**
 * Return the first possible-values block whose members satisfy `predicate`
 * (e.g. includes a known sentinel like `workspace-write` or `bypassPermissions`).
 */
export function findPossibleValuesBlock(
  text: string,
  predicate: (values: string[]) => boolean,
): string[] | undefined {
  for (const block of parseAllPossibleValueBlocks(text)) {
    if (predicate(block)) return block;
  }
  return undefined;
}
