import { describe, it, expect, afterEach } from 'vitest';
import { t, setLocale, getLocale } from './i18n.js';

describe('i18n', () => {
  afterEach(() => setLocale('ko'));

  it('defaults to Korean and returns the Korean string for a known key', () => {
    expect(getLocale()).toBe('ko');
    expect(t('perm.button.allow')).toBe('허용');
    expect(t('status.title')).toBe('세션 상태');
  });

  it('falls back to the key itself for a missing key', () => {
    expect(t('this.key.does.not.exist')).toBe('this.key.does.not.exist');
  });

  it('interpolates {placeholder} vars', () => {
    expect(t('wizard.started', { backend: 'claude', cwd: '/ws' })).toBe(
      '세션을 시작했어요. 백엔드 claude · 폴더 `/ws`',
    );
  });

  it('leaves an unknown placeholder untouched (never blanked)', () => {
    // 'stream.thought' expects {sec}; omit it and the token stays visible.
    expect(t('stream.thought')).toBe('{sec}초 동안 생각함');
  });

  it('resolves in the active locale, falling back to ko for keys not in en', () => {
    setLocale('en');
    expect(t('perm.button.allow')).toBe('Allow');
    // 'status.title' has no English entry → falls back to Korean.
    expect(t('status.title')).toBe('세션 상태');
  });

  it('honors a per-call locale override', () => {
    expect(t('perm.button.deny', undefined, 'en')).toBe('Deny');
    expect(getLocale()).toBe('ko'); // active locale unchanged
  });
});
