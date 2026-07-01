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
    // (>=17 . >=5 . >=20 chars). Assembled at runtime so no realistic
    // token literal lives in source (avoids secret scanners).
    const fake = ['X'.repeat(20), 'Y'.repeat(6), 'Z'.repeat(24)].join('.');
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
