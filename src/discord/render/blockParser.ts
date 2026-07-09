import type { Segment } from './segment.js';

// Pure answer-text → Segment[] parser (design §4.2). No discord.js / puppeteer. The
// whole point is FALSE-POSITIVE avoidance: content inside a fenced code block is never
// treated as a table, and a stray pipe in prose (no delimiter row) is never a table.

// A GFM table delimiter row: `|---|:--:|`, `--- | :--- | ---:`, etc.
const DELIM = /^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;
// A fence open line: ``` or ~~~ with an optional info string (language).
const FENCE = /^(\s*)(`{3,}|~{3,})\s*([^\s`~]*)/;

function isTableRow(line: string): boolean {
  return line.includes('|') && line.trim().length > 0;
}

// Split a table row into trimmed cells, honoring `\|` escapes and leading/trailing pipes.
export function splitRow(line: string): string[] {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);
  const cells: string[] = [];
  let cur = '';
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '\\' && s[i + 1] === '|') {
      cur += '|';
      i++;
      continue;
    }
    if (s[i] === '|') {
      cells.push(cur);
      cur = '';
      continue;
    }
    cur += s[i];
  }
  cells.push(cur);
  return cells.map((c) => c.trim());
}

// Number of cells (rows × columns) in a table block — used for the size guard.
export function tableCellCount(tableMd: string): number {
  const rows = tableMd.split('\n').filter((l) => l.trim().length);
  if (rows.length < 2) return 0;
  const cols = splitRow(rows[0]).length;
  // Exclude BOTH the header and the delimiter row from the body count.
  return Math.max(0, rows.length - 2) * cols;
}

// Split answer text into an ordered sequence of text / table / mermaid segments.
// Adjacent text is merged; the block↔text order is preserved so the delivery layer can
// send `text → image → text` in place (design §5).
export function splitAnswerSegments(text: string): Segment[] {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const segments: Segment[] = [];
  let buf: string[] = [];
  const flushText = () => {
    if (buf.length) {
      // Trim surrounding blank lines so a block's neighboring prose delivers cleanly
      // (the blank line that separated prose from a table/fence is not re-sent).
      const joined = buf.join('\n').trim();
      if (joined.length) segments.push({ kind: 'text', text: joined });
      buf = [];
    }
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = line.match(FENCE);
    if (fence) {
      const marker = fence[2][0]; // ` or ~
      const info = (fence[3] || '').toLowerCase();
      // Collect the fenced body up to a closing fence of the same marker (or EOF).
      const body: string[] = [];
      let j = i + 1;
      for (; j < lines.length; j++) {
        if (new RegExp(`^\\s*${marker === '`' ? '`{3,}' : '~{3,}'}\\s*$`).test(lines[j])) break;
        body.push(lines[j]);
      }
      if (info === 'mermaid') {
        flushText();
        segments.push({ kind: 'mermaid', code: body.join('\n') });
      } else {
        // Any other code fence stays verbatim in text (its pipes must NOT be read as a
        // table). Re-emit the fence markers so the block round-trips unchanged.
        buf.push(line, ...body);
        if (j < lines.length) buf.push(lines[j]); // closing fence
      }
      i = j; // skip past the closing fence (or to EOF)
      continue;
    }

    // GFM table: a pipe row immediately followed by a delimiter row.
    if (isTableRow(line) && i + 1 < lines.length && DELIM.test(lines[i + 1])) {
      const tbl = [line, lines[i + 1]];
      let j = i + 2;
      for (; j < lines.length; j++) {
        if (!isTableRow(lines[j])) break;
        tbl.push(lines[j]);
      }
      flushText();
      segments.push({ kind: 'table', source: tbl.join('\n') });
      i = j - 1;
      continue;
    }

    buf.push(line);
  }
  flushText();
  return segments;
}
