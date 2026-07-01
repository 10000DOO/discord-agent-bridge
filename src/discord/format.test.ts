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
