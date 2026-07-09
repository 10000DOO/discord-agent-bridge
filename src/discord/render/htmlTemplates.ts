import { splitRow } from './blockParser.js';

// Pure HTML builders for the render engine (design §6.3). Table cells and mermaid
// output are UNTRUSTED (agent/user text), so every interpolation is HTML-escaped here;
// the browser only ever loads this locally-built string (setContent), never a URL.

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Minimal inline markdown inside table cells (code / bold / italic / strike), applied
// AFTER escaping so no raw HTML can slip through.
function inlineMd(s: string): string {
  let out = escapeHtml(s);
  out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/~~([^~]+)~~/g, '<del>$1</del>');
  out = out.replace(/(?<!\*)\*([^*]+)\*(?!\*)/g, '<em>$1</em>');
  return out;
}

const DARK_CSS = `
  * { box-sizing: border-box; }
  body { margin: 0; background: #1e2124; display: inline-block; }
  #c { display: inline-block; padding: 16px; }
  table {
    border-collapse: collapse;
    font: 15px/1.5 "Apple SD Gothic Neo","Malgun Gothic","Noto Sans CJK KR","gg sans",-apple-system,"Segoe UI",sans-serif;
    color: #dbdee1;
  }
  th, td { border: 1px solid #3f4248; padding: 7px 14px; white-space: pre-wrap; text-align: left; }
  th { background: #2b2d31; font-weight: 600; }
  tbody tr:nth-child(2n) { background: #26282c; }
  code { background: #2b2d31; padding: .15em .4em; border-radius: 4px; font-family: ui-monospace,Menlo,monospace; font-size: 90%; }
`;

// GFM table markdown → a full dark-themed HTML document (single <table> in #c).
export function buildTableHtml(tableMd: string): string {
  const rows = tableMd.split('\n').filter((l) => l.trim().length);
  const header = splitRow(rows[0] ?? '');
  const aligns = splitRow(rows[1] ?? '').map((c) => {
    const l = c.startsWith(':');
    const r = c.endsWith(':');
    return l && r ? 'center' : r ? 'right' : l ? 'left' : '';
  });
  const body = rows.slice(2).map(splitRow);
  const align = (i: number) => (aligns[i] ? ` style="text-align:${aligns[i]}"` : '');
  const th = header.map((h, i) => `<th${align(i)}>${inlineMd(h)}</th>`).join('');
  const trs = body
    .map((cells) => `<tr>${cells.map((c, i) => `<td${align(i)}>${inlineMd(c)}</td>`).join('')}</tr>`)
    .join('');
  const table = `<table><thead><tr>${th}</tr></thead><tbody>${trs}</tbody></table>`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>${DARK_CSS}</style></head><body><div id="c">${table}</div></body></html>`;
}

// An empty dark page for mermaid; the caller injects mermaid.min.js locally
// (addScriptTag{path}) and renders into #c. No script/markup from the diagram source
// reaches the DOM as HTML — mermaid runs with securityLevel:'strict' (browserRenderer).
export function buildMermaidHtml(): string {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    body{margin:0;background:#1e2124;display:inline-block;}
    #c{display:inline-block;padding:16px;}
    #c svg{display:block;}
  </style></head><body><div id="c"></div></body></html>`;
}
