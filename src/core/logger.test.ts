import { describe, it, expect } from 'vitest';
import { createLogger, redact, type LogSink, type LogLevel } from './logger.js';

function captureSink(): { lines: { level: LogLevel; line: string }[]; sink: LogSink } {
  const lines: { level: LogLevel; line: string }[] = [];
  return {
    lines,
    sink: {
      write(level, line) {
        lines.push({ level, line });
      },
    },
  };
}

describe('redact()', () => {
  it('redacts sensitive object keys', () => {
    const out = redact({ token: 'abc.def.ghi', clientId: 'safe', authorization: 'Bearer xyz' }) as Record<
      string,
      unknown
    >;
    expect(out.token).toBe('[REDACTED]');
    expect(out.authorization).toBe('[REDACTED]');
    expect(out.clientId).toBe('safe');
  });

  it('scrubs Discord-token-shaped strings in free text', () => {
    // Synthetic, zero-entropy value matching the Discord-token SHAPE
    // (23-28 . 6-7 . 27-40 chars). Assembled at runtime so no realistic
    // token literal lives in source (avoids secret scanners).
    const fake = ['X'.repeat(24), 'Y'.repeat(6), 'Z'.repeat(28)].join('.');
    const out = redact(`connecting with ${fake} now`) as string;
    expect(out).not.toContain(fake);
    expect(out).toContain('[REDACTED]');
  });

  it('scrubs Bearer tokens and sk- keys', () => {
    expect(redact('Authorization: Bearer abcdef123456')).not.toContain('abcdef123456');
    // Synthetic sk--prefixed key (>=16 tail chars) matching the pattern shape.
    const skKey = 'sk-' + 'k'.repeat(20);
    expect(redact(`key ${skKey} here`)).not.toContain(skKey);
  });

  it('does NOT over-redact a benign dotted string that only resembles a token', () => {
    // Short segments (8 . 3 . 10) fall well below the Discord-token shape
    // (23-28 . 6-7 . 27-40), so a file-hash-like value must survive intact.
    const benign = 'deadbeef.sig.0123456789';
    expect(redact(`artifact ${benign} built`)).toBe(`artifact ${benign} built`);
  });

  it('scrubs a Bearer token separated by multiple spaces', () => {
    // The lookbehind allows 1-4 spaces after "Bearer" so a hand-spaced header
    // is still redacted. Assembled at runtime; not a realistic secret.
    const tok = 'sometoken12345';
    const out = redact(`Bearer   ${tok}`) as string;
    expect(out).not.toContain(tok);
    expect(out).toContain('[REDACTED]');
  });

  it('handles nested structures and circular references', () => {
    const obj: Record<string, unknown> = { a: { token: 'x.y.z' } };
    obj.self = obj;
    const out = redact(obj) as Record<string, unknown>;
    expect((out.a as Record<string, unknown>).token).toBe('[REDACTED]');
    expect(out.self).toBe('[Circular]');
  });
});

describe('createLogger()', () => {
  it('redacts a token embedded in a logged payload', () => {
    const { lines, sink } = captureSink();
    const logger = createLogger('test', { level: 'info', sink });
    // Synthetic sentinel under the sensitive 'token' key (redacted by key).
    const secret = 'S'.repeat(40);
    logger.info('bot login', { discord: { token: secret } });
    const joined = lines.map((l) => l.line).join('\n');
    expect(joined).not.toContain(secret);
    expect(joined).toContain('[REDACTED]');
  });

  it('gates messages below the configured level', () => {
    const { lines, sink } = captureSink();
    const logger = createLogger('test', { level: 'warn', sink });
    logger.debug('debug msg');
    logger.info('info msg');
    logger.warn('warn msg');
    logger.error('error msg');
    const levels = lines.map((l) => l.level);
    expect(levels).toEqual(['warn', 'error']);
  });

  it('defaults to info level', () => {
    const { lines, sink } = captureSink();
    const logger = createLogger('test', { sink });
    logger.debug('nope');
    logger.info('yep');
    expect(lines).toHaveLength(1);
    expect(lines[0].level).toBe('info');
  });
});
