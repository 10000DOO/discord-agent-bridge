import { describe, it, expect } from 'vitest';
import { formatRateLimitLine, rateLimitTypeLabel } from './index.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { UsageResult, UsageSnapshot } from '../../core/usageService.js';

// formatRateLimitLine backfills the utilization % from the usage snapshot when the
// SDK's rate_limit_event omits it (the common case — SDKRateLimitInfo.utilization is
// optional and usually absent).

type RateLimitEvent = Extract<AgentEvent, { kind: 'rate_limit' }>;
type LimitField = 'fiveHour' | 'sevenDay' | 'sevenDayOpus' | 'sevenDaySonnet';

const ev = (over: Partial<RateLimitEvent> = {}): RateLimitEvent => ({ kind: 'rate_limit', ...over });
const snapshot = (over: Partial<UsageSnapshot> = {}): UsageSnapshot => ({ fetchedAt: 0, ...over });
const withWindow = (field: LimitField, utilization: number): UsageSnapshot => {
  const s: UsageSnapshot = { fetchedAt: 0 };
  s[field] = { utilization };
  return s;
};
const unavailable: UsageResult = { available: false, reason: 'no-credentials' };

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

describe('formatRateLimitLine — utilization from the event (regression)', () => {
  it('uses ev.utilization when present, ignoring the snapshot', () => {
    const line = formatRateLimitLine(ev({ rateLimitType: 'five_hour', utilization: 42 }), withWindow('fiveHour', 99));
    expect(line).toContain('사용량 42%');
    expect(line).not.toContain('99%');
  });

  it('rounds the utilization', () => {
    expect(formatRateLimitLine(ev({ utilization: 42.7 }))).toContain('사용량 43%');
  });

  it('omits % when neither the event nor a snapshot supplies it', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }))).not.toMatch(/사용량 \d+%/);
  });
});

describe('formatRateLimitLine — utilization backfilled from the usage snapshot', () => {
  const cases: Array<[string, LimitField]> = [
    ['five_hour', 'fiveHour'],
    ['seven_day', 'sevenDay'],
    ['seven_day_opus', 'sevenDayOpus'],
    ['seven_day_sonnet', 'sevenDaySonnet'],
  ];
  for (const [rateType, field] of cases) {
    it(`maps ${rateType} → ${field} and shows its %`, () => {
      const line = formatRateLimitLine(ev({ rateLimitType: rateType }), withWindow(field, 37));
      expect(line).toContain('사용량 37%');
    });
  }

  it('rounds a backfilled utilization', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }), withWindow('fiveHour', 12.4))).toContain('사용량 12%');
  });

  it('omits % for overage even with a full snapshot', () => {
    const snap = snapshot({ fiveHour: { utilization: 50 }, sevenDay: { utilization: 60 } });
    expect(formatRateLimitLine(ev({ rateLimitType: 'overage' }), snap)).not.toMatch(/사용량 \d+%/);
  });

  it('omits % for an unknown rate type', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'moon_phase' }), withWindow('fiveHour', 50))).not.toMatch(/사용량 \d+%/);
  });

  it('omits % when the matching window is missing from the snapshot', () => {
    // seven_day requested but the snapshot only carries the five-hour window.
    expect(formatRateLimitLine(ev({ rateLimitType: 'seven_day' }), withWindow('fiveHour', 50))).not.toMatch(/사용량 \d+%/);
  });
});

describe('formatRateLimitLine — no snapshot / unavailable', () => {
  it('omits % when usage is null', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }), null)).not.toMatch(/사용량 \d+%/);
  });

  it('omits % when usage is UsageUnavailable', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }), unavailable)).not.toMatch(/사용량 \d+%/);
  });

  it('omits % when the usage arg is not passed at all (back-compat)', () => {
    expect(formatRateLimitLine(ev({ rateLimitType: 'five_hour' }))).not.toMatch(/사용량 \d+%/);
  });

  it('does not crash and omits % when there is no rateLimitType', () => {
    expect(formatRateLimitLine(ev(), withWindow('fiveHour', 50))).not.toMatch(/사용량 \d+%/);
  });
});
