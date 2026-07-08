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

  it('shows the running model id in the footer (the old 모델 field is absorbed)', () => {
    const withModel = { ...ctx, model: 'claude-fable-5[1m]' };
    const embed = buildUsageEmbed(null, withModel);
    expect(embed?.footer).toBe('claude-fable-5[1m]');
    expect((embed?.fields ?? []).map((f) => f.name)).not.toContain('모델');
  });

  it('omits the footer when neither a model id nor a permission mode is known', () => {
    const embed = buildUsageEmbed(null, ctx);
    expect(embed).not.toBeNull();
    expect(embed?.footer).toBeUndefined();
  });

  it('renders the description line from display name + cwd/branch + elapsed', () => {
    const withName = { ...ctx, modelDisplayName: 'Claude Fable 5' };
    const createdAt = new Date(Date.now() - (5 * 60 + 16) * 60_000).toISOString(); // 5h16m ago
    const embed = buildUsageEmbed(null, withName, {
      meta: { cwd: '/Volumes/src/discord-agent-bridge', gitBranch: 'master', createdAt },
    });
    expect(embed?.description).toBe('[Claude Fable 5] · 📁 discord-agent-bridge git:(master) · ⏱️ 5시간 16분');
  });

  it('omits the git:(…) segment when no branch is known and the whole description when nothing is', () => {
    const embed = buildUsageEmbed(null, ctx, { meta: { cwd: '/tmp/proj' } });
    expect(embed?.description).toBe('📁 proj');
    expect(buildUsageEmbed(null, ctx)?.description).toBeUndefined();
  });

  it('puts the permission-mode label and model id into the footer', () => {
    const withModel = { ...ctx, model: 'claude-fable-5' };
    const embed = buildUsageEmbed(null, withModel, { meta: { permMode: 'bypassPermissions' } });
    expect(embed?.footer).toBe('권한: 전체 자동 승인 (⚠️ 위험) · claude-fable-5');
  });

  it('appends the /clear savings hint to the context line when clearableTokens is present', () => {
    const withClearable = { ...ctx, clearableTokens: 207_600 };
    const embed = buildUsageEmbed(null, withClearable);
    const field = (embed?.fields ?? []).find((f) => f.name === '컨텍스트');
    expect(field?.value).toContain('/clear 시 ~207.6K 토큰 절약');
    // Zero clearable tokens → no hint.
    const zero = buildUsageEmbed(null, { ...ctx, clearableTokens: 0 });
    expect((zero?.fields ?? []).find((f) => f.name === '컨텍스트')?.value).not.toContain('/clear');
  });

  it('renders the session-composition field from memoryFileCount/mcpServerCount', () => {
    const withCounts = { ...ctx, memoryFileCount: 1, mcpServerCount: 3 };
    const embed = buildUsageEmbed(null, withCounts);
    const field = (embed?.fields ?? []).find((f) => f.name === '세션 구성');
    expect(field?.value).toBe('CLAUDE.md 1 · MCP 3');
    expect(field?.inline).toBe(true);
    // Neither count → no field.
    expect((buildUsageEmbed(null, ctx)?.fields ?? []).map((f) => f.name)).not.toContain('세션 구성');
  });

  it('renders the turn tools field: top 4 by count, ❌ on failure, +N overflow', () => {
    const tools = [
      { name: 'Bash', count: 20, failed: 0 },
      { name: 'Read', count: 3, failed: 0 },
      { name: 'Edit', count: 1, failed: 1 },
      { name: 'Grep', count: 2, failed: 0 },
      { name: 'Glob', count: 1, failed: 0 },
    ];
    const embed = buildUsageEmbed(null, ctx, { tools });
    const field = (embed?.fields ?? []).find((f) => f.name === '이번 턴 도구');
    expect(field?.value).toBe('✅ Bash ×20 · ✅ Read ×3 · ✅ Grep ×2 · ❌ Edit ×1 · +1');
    // No tools this turn → no field.
    expect((buildUsageEmbed(null, ctx, { tools: [] })?.fields ?? []).map((f) => f.name)).not.toContain('이번 턴 도구');
  });

  it('renders subagent runs with status icon, type: description label and duration', () => {
    const agents = [
      { status: 'completed' as const, summary: 'long summary', type: 'developer', description: 'Fix model list', durationMs: 12_000 },
      { status: 'failed' as const, summary: 'it broke' },
    ];
    const embed = buildUsageEmbed(null, ctx, { agents });
    const field = (embed?.fields ?? []).find((f) => f.name === '서브에이전트');
    expect(field?.value).toBe('✅ developer: Fix model list (12초)\n❌ it broke');
  });

  it('caps the subagent field value at 1024 chars', () => {
    const agents = Array.from({ length: 5 }, (_, i) => ({
      status: 'completed' as const,
      summary: `run-${i} ${'x'.repeat(400)}`,
    }));
    const embed = buildUsageEmbed(null, ctx, { agents });
    const field = (embed?.fields ?? []).find((f) => f.name === '서브에이전트');
    expect(field).toBeDefined();
    expect(field!.value.length).toBeLessThanOrEqual(1024);
  });
});
