import { describe, it, expect } from 'vitest';
import { buildTableHtml, buildMermaidHtml, escapeHtml } from './htmlTemplates.js';

describe('escapeHtml', () => {
  it('escapes HTML metacharacters', () => {
    expect(escapeHtml('<script>&"')).toBe('&lt;script&gt;&amp;&quot;');
  });
});

describe('buildTableHtml', () => {
  it('renders header + body cells into a <table>', () => {
    const html = buildTableHtml('| Name | Age |\n|---|---|\n| Kim | 30 |');
    expect(html).toContain('<th>Name</th>');
    expect(html).toContain('<td>Kim</td>');
    expect(html).toContain('<td>30</td>');
  });

  it('escapes untrusted cell content (no raw tags reach the DOM)', () => {
    const html = buildTableHtml('| x |\n|---|\n| <img src=x onerror=alert(1)> |');
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;img src=x onerror=alert(1)&gt;');
  });

  it('applies column alignment from the delimiter row', () => {
    const html = buildTableHtml('| l | c | r |\n|:--|:-:|--:|\n| 1 | 2 | 3 |');
    expect(html).toContain('text-align:left');
    expect(html).toContain('text-align:center');
    expect(html).toContain('text-align:right');
  });
});

describe('buildMermaidHtml', () => {
  it('returns an empty dark container document (no diagram source inlined)', () => {
    const html = buildMermaidHtml();
    expect(html).toContain('<div id="c"></div>');
    expect(html).toContain('background:#1e2124');
  });
});
