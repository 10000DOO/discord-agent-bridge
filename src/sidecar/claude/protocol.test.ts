import { describe, it, expect } from 'vitest';
import {
  PROTOCOL_VERSION,
  parseEnvelope,
  serializeEnvelope,
  ProtocolParseError,
  req,
  res,
  resError,
  event,
  notify,
  makeError,
} from './protocol.js';

describe('sidecar protocol parse/serialize', () => {
  it('round-trips a req envelope', () => {
    const env = req('h-1', 'session.start', {
      cwd: '/tmp/ws',
      guildId: 'g1',
      channelId: 'c1',
      permMode: 'default',
    });
    const line = serializeEnvelope(env);
    expect(line.includes('\n')).toBe(false);
    const parsed = parseEnvelope(line);
    expect(parsed).toEqual(env);
    expect(parsed.v).toBe(PROTOCOL_VERSION);
    expect(parsed.type).toBe('req');
    expect(parsed.method).toBe('session.start');
  });

  it('round-trips res / resError / event / notify', () => {
    expect(parseEnvelope(serializeEnvelope(res('1', 'session.send', { ok: true }, 's-1')))).toMatchObject({
      type: 'res',
      result: { ok: true },
      session: 's-1',
    });
    expect(
      parseEnvelope(
        serializeEnvelope(resError('1', 'session.stop', makeError('unknown_session', 'nope'))),
      ),
    ).toMatchObject({
      type: 'res',
      error: { code: 'unknown_session', message: 'nope', retryable: false },
    });
    expect(
      parseEnvelope(
        serializeEnvelope(event('s-1', { kind: 'text', text: 'hi', delta: true })),
      ),
    ).toMatchObject({
      type: 'event',
      session: 's-1',
      event: { kind: 'text', text: 'hi', delta: true },
    });
    expect(
      parseEnvelope(serializeEnvelope(notify('sidecar.ready', { v: 1 }))),
    ).toMatchObject({
      type: 'notify',
      method: 'sidecar.ready',
      params: { v: 1 },
    });
  });

  it('rejects empty / non-json / wrong version / bad type', () => {
    expect(() => parseEnvelope('')).toThrow(ProtocolParseError);
    expect(() => parseEnvelope('   ')).toThrow(ProtocolParseError);
    expect(() => parseEnvelope('not-json')).toThrow(ProtocolParseError);
    expect(() => parseEnvelope(JSON.stringify({ v: 99, type: 'req' }))).toThrow(
      /unsupported protocol version/,
    );
    expect(() => parseEnvelope(JSON.stringify({ v: 1, type: 'nope' }))).toThrow(
      /invalid envelope type/,
    );
    expect(() => parseEnvelope(JSON.stringify([1, 2]))).toThrow(/JSON object/);
  });

  it('accepts whitespace-padded lines', () => {
    const line = '  ' + serializeEnvelope(req('a', 'sessions.list', { cwd: '/' })) + '  ';
    expect(parseEnvelope(line).method).toBe('sessions.list');
  });
});
