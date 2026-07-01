import { describe, it, expect } from 'vitest';
import { buildStatusEmbed } from './statusEmbed.js';

describe('buildStatusEmbed', () => {
  it('renders mode, permission mode, cwd, and session id', () => {
    const embed = buildStatusEmbed({
      mode: 'claude',
      cwd: '/ws',
      sessionId: 'sess-1',
      permMode: 'default',
      usagePanel: true,
    });
    const values = (embed.fields ?? []).map((f) => f.value);
    expect(values).toContain('claude');
    expect(values).toContain('`/ws`');
    expect(values).toContain('`sess-1`');
    // Claude (usagePanel true) → no "unavailable" footer.
    expect(embed.footer).toBeUndefined();
  });

  it('shows the Codex "usage/limits unavailable" line when usagePanel is false', () => {
    const embed = buildStatusEmbed({
      mode: 'codex',
      cwd: '/ws',
      sessionId: null,
      permMode: 'plan',
      usagePanel: false,
    });
    expect(embed.footer).toBe('사용량/한도 정보 없음 (Codex CLI 제한)');
    // A null session id renders as a dash, not "null".
    expect((embed.fields ?? []).some((f) => f.value === '`—`')).toBe(true);
  });
});
