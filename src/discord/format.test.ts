import { describe, it, expect } from 'vitest';
import {
  chunkMessage,
  truncate,
  toolThreadName,
  formatTokens,
  formatDuration,
  MSG_LIMIT,
  THREAD_NAME_LIMIT,
} from './format.js';

describe('format helpers', () => {
  it('chunkMessage keeps short text whole and splits long text under the limit', () => {
    expect(chunkMessage('short')).toEqual(['short']);
    expect(chunkMessage('')).toEqual([]);
    const long = 'a'.repeat(MSG_LIMIT * 2 + 10);
    const chunks = chunkMessage(long);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((c) => c.length <= MSG_LIMIT)).toBe(true);
    expect(chunks.join('')).toBe(long);
  });

  it('chunkMessage prefers to break on a newline', () => {
    // First line fills nearly the whole limit; total exceeds it so a split is forced,
    // and the break lands on the newline (not mid-line).
    const line = 'x'.repeat(MSG_LIMIT - 5);
    const text = `${line}\n${'y'.repeat(50)}`;
    const chunks = chunkMessage(text);
    expect(chunks[0]).toBe(line);
    expect(chunks[1]).toBe('y'.repeat(50));
  });

  it('truncate appends an ellipsis only when cut', () => {
    expect(truncate('abc', 5)).toBe('abc');
    expect(truncate('abcdef', 4)).toBe('abc…');
  });

  it('toolThreadName summarizes per-tool input and caps to the thread-name limit', () => {
    expect(toolThreadName('Edit', { file_path: '/ws/a.ts' })).toBe('Edit: /ws/a.ts');
    expect(toolThreadName('Bash', { command: 'ls -la' })).toBe('Bash: ls -la');
    const longPath = '/' + 'p'.repeat(200);
    expect(toolThreadName('Read', { file_path: longPath }).length).toBeLessThanOrEqual(THREAD_NAME_LIMIT);
  });

  it('formatTokens / formatDuration are compact', () => {
    expect(formatTokens(512)).toBe('512');
    expect(formatTokens(1500)).toBe('1.5K');
    expect(formatTokens(2_000_000)).toBe('2.0M');
    expect(formatDuration(3000)).toBe('3.0s');
    expect(formatDuration(90_000)).toBe('1.5m');
  });
});

describe('chunkMessage — code fence balancing', () => {
  const fenceCount = (s: string) => (s.match(/```/g) ?? []).length;
  const balanced = (s: string) => fenceCount(s) % 2 === 0;
  // All content except triple-backticks and newlines must survive in order. The only
  // characters the splitter adds or drops are ``` and \n (inserted markers, dropped
  // boundary newlines), so stripping both from either side must yield the same string.
  const content = (s: string) => s.replace(/```/g, '').replace(/\n/g, '');

  it('leaves fence-free long text unchanged (regression)', () => {
    const long = 'a'.repeat(MSG_LIMIT * 2 + 10);
    const chunks = chunkMessage(long);
    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((c) => c.length <= MSG_LIMIT)).toBe(true);
    expect(chunks.join('')).toBe(long); // no markers inserted, byte-for-byte
  });

  it('closes and reopens a code block that spans multiple chunks', () => {
    const code = Array.from({ length: 200 }, (_, i) => `line ${i} ${'x'.repeat(20)}`).join('\n');
    const text = '```js\n' + code + '\n```';
    expect(text.length).toBeGreaterThan(MSG_LIMIT);
    const chunks = chunkMessage(text);
    expect(chunks.length).toBeGreaterThanOrEqual(2);
    expect(chunks.every((c) => c.length <= MSG_LIMIT)).toBe(true);
    expect(chunks.every(balanced)).toBe(true); // each chunk self-balanced
    expect(content(chunks.join(''))).toBe(content(text)); // code text preserved
  });

  it('opens and closes every middle chunk when a code block spans 3+ chunks', () => {
    const lines = Array.from({ length: 400 }, () => 'y'.repeat(50)).join('\n'); // ~20k chars
    const text = '```\n' + lines + '\n```';
    const chunks = chunkMessage(text);
    expect(chunks.length).toBeGreaterThanOrEqual(3);
    expect(chunks.every((c) => c.length <= MSG_LIMIT)).toBe(true);
    chunks.forEach((c, i) => {
      expect(balanced(c)).toBe(true);
      if (i > 0 && i < chunks.length - 1) {
        expect(c.startsWith('```')).toBe(true); // reopened
        expect(c.endsWith('```')).toBe(true); // closed at boundary
      }
    });
    expect(content(chunks.join(''))).toBe(content(text));
  });

  it('keeps every chunk balanced with multiple fences (code / prose / code)', () => {
    const block = (tag: string) => '```' + tag + '\n' + (tag + '\n').repeat(300) + '```';
    const text = block('alpha') + '\n\nsome prose paragraph between the blocks\n\n' + block('beta');
    expect(text.length).toBeGreaterThan(MSG_LIMIT);
    const chunks = chunkMessage(text);
    expect(chunks.every((c) => c.length <= MSG_LIMIT)).toBe(true);
    expect(chunks.every(balanced)).toBe(true);
    expect(content(chunks.join(''))).toBe(content(text));
  });
});
