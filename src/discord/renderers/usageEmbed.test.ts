import { describe, it, expect } from 'vitest';
import { buildUsageEmbed } from './usageEmbed.js';
import type { AgentEvent } from '../../core/contracts.js';
import type { UsageResult } from '../../core/usageService.js';

const ctx: Extract<AgentEvent, { kind: 'context_usage' }> = {
  kind: 'context_usage',
  totalTokens: 30,
  maxTokens: 100,
  percentage: 30,
};

describe('buildUsageEmbed', () => {
  it('renders nothing when usage is unavailable and there is no context figure', () => {
    const unavailable: UsageResult = { available: false, reason: 'no-credentials' };
    expect(buildUsageEmbed(unavailable, null)).toBeNull();
    expect(buildUsageEmbed(null, null)).toBeNull();
  });

  it('renders the codex-unsupported result as nothing (hidden panel)', () => {
    const codex: UsageResult = { available: false, reason: 'codex-unsupported' };
    expect(buildUsageEmbed(codex, null)).toBeNull();
  });

  it('renders 5-hour + weekly + per-model + context fields from a snapshot', () => {
    const snapshot: UsageResult = {
      fetchedAt: 1000,
      fiveHour: { utilization: 42, resetsAt: '2026-07-01T12:00:00Z' },
      sevenDay: { utilization: 10 },
      sevenDayOpus: { utilization: 80 },
      sevenDaySonnet: { utilization: 5 },
    };
    const embed = buildUsageEmbed(snapshot, ctx);
    const names = (embed?.fields ?? []).map((f) => f.name);
    expect(names).toContain('5시간');
    expect(names).toContain('주간');
    expect(names).toContain('주간 (Opus)');
    expect(names).toContain('컨텍스트');
    // Highest utilization (80) → yellow band color, not green.
    expect(embed?.color).not.toBeUndefined();
  });

  it('renders a context-only panel when only a context figure is present', () => {
    const embed = buildUsageEmbed({ available: false, reason: 'no-credentials' }, ctx);
    expect(embed).not.toBeNull();
    expect((embed?.fields ?? []).map((f) => f.name)).toEqual(['컨텍스트']);
  });
});
