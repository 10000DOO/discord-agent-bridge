import { describe, it, expect } from 'vitest';
import { formatRateLimitLine, formatUsageWindows, rateLimitTypeLabel } from './index.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { UsageResult, UsageSnapshot } from '../../core/usageService.js';

// When a usage snapshot is available, the rate-limit line shows EVERY window with its
// own reset. Without a snapshot it falls back to the SDK event's own label/util/reset.

type RateLimitEvent = Extract<AgentEvent, { kind: 'rate_limit' }>;

const ev = (over: Partial<RateLimitEvent> = {}): RateLimitEvent => ({ kind: 'rate_limit', ...over });
const snapshot = (over: Partial<UsageSnapshot> = {}): UsageSnapshot => ({ fetchedAt: 0, ...over });
const unavailable: UsageResult = { available: false, reason: 'no-credentials' };

// Build ISO reset times relative to the real clock, and render the EXPECTED string with
// the same locale logic the formatter uses — so assertions are timezone-independent.
function isoToday(): string {
  const d = new Date();
  d.setHours(13, 20, 0, 0);
  return d.toISOString();
}
function isoFutureDay(): string {
  const d = new Date();
  d.setDate(d.getDate() + 2); // definitely not today
  d.setHours(9, 0, 0, 0);
  return d.toISOString();
}
function expectedReset(iso: string): string {
  const d = new Date(iso);
  const now = new Date();
  const hhmm = d.toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false });
  const sameDay =
    d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  return sameDay ? hhmm : `${d.getMonth() + 1}/${d.getDate()} ${hhmm}`;
}

describe('rateLimitTypeLabel', () => {
  it('maps every known SDK rate-limit type', () => {
    expect(rateLimitTypeLabel('five_hour')).toBe('5시간 한도');
    expect(rateLimitTypeLabel('seven_day')).toBe('주간 한도');
    expect(rateLimitTypeLabel('seven_day_opus')).toBe('주간 한도 (Opus)');
    expect(rateLimitTypeLabel('seven_day_sonnet')).toBe('주간 한도 (Sonnet)');
    expect(rateLimitTypeLabel('overage')).toBe('추가 사용량');
  });

  it('passes an unknown/future type through verbatim', () => {
    expect(rateLimitTypeLabel('moon_phase')).toBe('moon_phase');
  });
});

describe('formatUsageWindows', () => {
  it('returns null for a non-snapshot (null / unavailable)', () => {
    expect(formatUsageWindows(null)).toBeNull();
    expect(formatUsageWindows(unavailable)).toBeNull();
  });

  it('returns null for a snapshot with no windows', () => {
    expect(formatUsageWindows(snapshot())).toBeNull();
  });

  it('renders every present window, each with its own reset, in order', () => {
    const today = isoToday();
    const future = isoFutureDay();
    const out = formatUsageWindows(
      snapshot({ fiveHour: { utilization: 26, resetsAt: today }, sevenDay: { utilization: 41, resetsAt: future } }),
    );
    expect(out).toBe(`5시간 26% (리셋 ${expectedReset(today)}) · 주간 41% (리셋 ${expectedReset(future)})`);
  });

  it('renders only the windows that exist', () => {
    const today = isoToday();
    expect(formatUsageWindows(snapshot({ fiveHour: { utilization: 26, resetsAt: today } }))).toBe(
      `5시간 26% (리셋 ${expectedReset(today)})`,
    );
  });

  it('omits the reset parenthetical when resetsAt is absent or unparseable', () => {
    expect(formatUsageWindows(snapshot({ fiveHour: { utilization: 26 } }))).toBe('5시간 26%');
    expect(formatUsageWindows(snapshot({ fiveHour: { utilization: 26, resetsAt: 'not-a-date' } }))).toBe('5시간 26%');
  });

  it('rounds utilization and labels the opus/sonnet windows', () => {
    expect(
      formatUsageWindows(snapshot({ sevenDayOpus: { utilization: 12.6 }, sevenDaySonnet: { utilization: 0 } })),
    ).toBe('주간(Opus) 13% · 주간(Sonnet) 0%');
  });
});

describe('formatRateLimitLine — snapshot present (all windows)', () => {
  it('shows every window with resets and ignores the event label/util/reset', () => {
    const today = isoToday();
    const future = isoFutureDay();
    const line = formatRateLimitLine(
      ev({ rateLimitType: 'five_hour', utilization: 99, resetAt: today }),
      snapshot({ fiveHour: { utilization: 26, resetsAt: today }, sevenDay: { utilization: 41, resetsAt: future } }),
    );
    expect(line).toBe(
      `📊 사용량 한도 알림 · 5시간 26% (리셋 ${expectedReset(today)}) · 주간 41% (리셋 ${expectedReset(future)})`,
    );
    expect(line).not.toContain('99'); // the event's own util is ignored on the snapshot path
  });

  it('shows a single window when the snapshot has only one', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'seven_day' }), snapshot({ sevenDay: { utilization: 41 } }))).toBe(
      '📊 사용량 한도 알림 · 주간 41%',
    );
  });
});

describe('formatRateLimitLine — no snapshot (event-based fallback, regression)', () => {
  it('uses the event label + utilization + reset when there is no snapshot', () => {
    const resetAt = new Date(1000 * 1000).toISOString();
    const hhmm = new Date(1000 * 1000).toLocaleTimeString('ko-KR', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour', utilization: 87, resetAt }), null)).toBe(
      `📊 사용량 한도 알림 · 5시간 한도 · 사용량 87% · 리셋 ${hhmm}`,
    );
  });

  it('rounds the event utilization', () => {
    expect(formatRateLimitLine(ev({ utilization: 42.7 }))).toContain('사용량 43%');
  });

  it('omits % when the event has none and there is no snapshot (null / unavailable / no arg)', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }), null)).toBe('📊 사용량 한도 알림 · 5시간 한도');
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }), unavailable)).toBe('📊 사용량 한도 알림 · 5시간 한도');
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }))).toBe('📊 사용량 한도 알림 · 5시간 한도');
  });

  it('falls back to the event when the snapshot carries no windows', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'seven_day', utilization: 50 }), snapshot())).toBe(
      '📊 사용량 한도 알림 · 주간 한도 · 사용량 50%',
    );
  });
});
