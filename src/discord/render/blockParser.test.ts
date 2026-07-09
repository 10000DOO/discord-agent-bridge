import { describe, it, expect } from 'vitest';
import { splitAnswerSegments, splitRow, tableCellCount } from './blockParser.js';

describe('splitAnswerSegments', () => {
  it('keeps plain prose as a single text segment', () => {
    expect(splitAnswerSegments('hello\nworld')).toEqual([{ kind: 'text', text: 'hello\nworld' }]);
  });

  it('extracts a GFM table between surrounding prose, in order', () => {
    const md = 'before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter';
    const segs = splitAnswerSegments(md);
    expect(segs.map((s) => s.kind)).toEqual(['text', 'table', 'text']);
    expect(segs[1]).toMatchObject({ kind: 'table', source: '| a | b |\n|---|---|\n| 1 | 2 |' });
    expect(segs[0]).toMatchObject({ text: 'before' });
    expect(segs[2]).toMatchObject({ text: 'after' });
  });

  it('extracts a ```mermaid fence as a mermaid segment (code only)', () => {
    const md = '```mermaid\nflowchart LR\n  A --> B\n```';
    expect(splitAnswerSegments(md)).toEqual([{ kind: 'mermaid', code: 'flowchart LR\n  A --> B' }]);
  });

  it('does NOT treat pipes inside a NON-mermaid code fence as a table', () => {
    const md = '```js\nconst x = a | b;\n| not | a | table |\n```';
    const segs = splitAnswerSegments(md);
    expect(segs).toHaveLength(1);
    expect(segs[0].kind).toBe('text');
    expect((segs[0] as { text: string }).text).toContain('| not | a | table |');
  });

  it('does NOT treat a stray prose pipe (no delimiter row) as a table', () => {
    const segs = splitAnswerSegments('use a | b to pipe');
    expect(segs).toEqual([{ kind: 'text', text: 'use a | b to pipe' }]);
  });

  it('does NOT mistake mermaid edge labels (A -->|yes| B) for a table', () => {
    const md = '```mermaid\nflowchart LR\n  A -->|yes| B\n  B -->|no| C\n```';
    const segs = splitAnswerSegments(md);
    expect(segs).toHaveLength(1);
    expect(segs[0].kind).toBe('mermaid');
  });

  it('handles a header + delimiter with zero body rows', () => {
    const segs = splitAnswerSegments('| h1 | h2 |\n|---|---|');
    expect(segs).toEqual([{ kind: 'table', source: '| h1 | h2 |\n|---|---|' }]);
  });

  it('collects an unterminated ```mermaid fence to EOF', () => {
    const segs = splitAnswerSegments('```mermaid\nflowchart LR\n  A --> B');
    expect(segs).toEqual([{ kind: 'mermaid', code: 'flowchart LR\n  A --> B' }]);
  });

  it('normalizes CRLF and supports ~~~ mermaid fences', () => {
    const segs = splitAnswerSegments('~~~mermaid\r\ngraph TD\r\n  X --> Y\r\n~~~');
    expect(segs).toEqual([{ kind: 'mermaid', code: 'graph TD\n  X --> Y' }]);
  });

  it('drops whitespace-only text segments between blocks', () => {
    const md = '| a |\n|---|\n| 1 |\n\n\n| b |\n|---|\n| 2 |';
    expect(splitAnswerSegments(md).map((s) => s.kind)).toEqual(['table', 'table']);
  });
});

describe('splitRow', () => {
  it('trims cells and drops leading/trailing pipes', () => {
    expect(splitRow('| a | b | c |')).toEqual(['a', 'b', 'c']);
  });
  it('honors escaped pipes inside a cell', () => {
    expect(splitRow('| a \\| b | c |')).toEqual(['a | b', 'c']);
  });
});

describe('tableCellCount', () => {
  it('counts body cells (rows × columns, excluding header/delimiter)', () => {
    expect(tableCellCount('| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |')).toBe(4);
  });
});
