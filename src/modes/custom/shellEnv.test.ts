import { describe, it, expect } from 'vitest';
import { resolveCustomEnv } from './shellEnv.js';

const NONEXISTENT_HOME = '/this-home-dir-does-not-exist-for-tests';

describe('resolveCustomEnv', () => {
  it('extracts allowed env vars from a kimi alias value', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': "alias kimi='ANTHROPIC_BASE_URL=\"https://api.moonshot.ai/anthropic\" ANTHROPIC_AUTH_TOKEN=\"sk-secret\" ANTHROPIC_MODEL=\"kimi-k2.7-code\" API_TIMEOUT_MS=\"600000\" claude'",
      },
    });
    expect(result.env).toEqual({
      ANTHROPIC_BASE_URL: 'https://api.moonshot.ai/anthropic',
      ANTHROPIC_AUTH_TOKEN: 'sk-secret',
      ANTHROPIC_MODEL: 'kimi-k2.7-code',
      API_TIMEOUT_MS: '600000',
    });
    expect(result.source).toBe('.zshrc');
    expect(result.hasDangerousFlag).toBe(false);
  });

  it('extracts bare and export-prefixed assignments anywhere in the file', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': `
# some comment
export ANTHROPIC_BASE_URL="https://api.example.com"
ANTHROPIC_API_KEY='key-2'
API_TIMEOUT_MS=600000
`,
      },
    });
    expect(result.env).toEqual({
      ANTHROPIC_BASE_URL: 'https://api.example.com',
      ANTHROPIC_API_KEY: 'key-2',
      API_TIMEOUT_MS: '600000',
    });
    expect(result.source).toBe('.zshrc');
  });

  it('also scans alias claude', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.bashrc': "alias claude='ANTHROPIC_API_KEY=\"key-1\" ANTHROPIC_SMALL_FAST_MODEL=\"kimi-k2.7-code\" claude'",
      },
    });
    expect(result.env).toEqual({
      ANTHROPIC_API_KEY: 'key-1',
      ANTHROPIC_SMALL_FAST_MODEL: 'kimi-k2.7-code',
    });
    expect(result.source).toBe('.bashrc');
  });

  it('ignores env keys not in the allow-list', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': `
ANTHROPIC_MODEL="kimi"
PATH="/evil"
FOO="bar"
`,
      },
    });
    expect(result.env).toEqual({ ANTHROPIC_MODEL: 'kimi' });
  });

  it('detects --dangerously-skip-permissions anywhere in the file', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': '# dangerous alias\nalias kimi=\'claude --dangerously-skip-permissions\'\nANTHROPIC_MODEL="kimi"',
      },
    });
    expect(result.hasDangerousFlag).toBe(true);
    expect(result.env.ANTHROPIC_MODEL).toBe('kimi');
  });

  it('supports single-quoted, double-quoted, and unquoted values', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': `
ANTHROPIC_MODEL='single'
export ANTHROPIC_API_KEY="double"
API_TIMEOUT_MS=600000
`,
      },
    });
    expect(result.env).toEqual({
      ANTHROPIC_MODEL: 'single',
      ANTHROPIC_API_KEY: 'double',
      API_TIMEOUT_MS: '600000',
    });
  });

  it('lets later files override earlier files', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': 'ANTHROPIC_MODEL="old"',
        '.zprofile': 'ANTHROPIC_MODEL="new"',
      },
    });
    expect(result.env.ANTHROPIC_MODEL).toBe('new');
    expect(result.source).toBe('.zprofile');
  });

  it('lets the last occurrence within a single file win', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': `
ANTHROPIC_MODEL="first"
ANTHROPIC_MODEL="second"
ANTHROPIC_MODEL="third"
`,
      },
    });
    expect(result.env.ANTHROPIC_MODEL).toBe('third');
  });

  it('returns empty env and no source when no allowed keys are found', () => {
    const result = resolveCustomEnv({ homeDir: NONEXISTENT_HOME, files: { '.zshrc': '# no relevant env\n' } });
    expect(result.env).toEqual({});
    expect(result.source).toBeUndefined();
    expect(result.hasDangerousFlag).toBe(false);
  });

  it('does not source or execute the file — only regex-scans it', () => {
    const result = resolveCustomEnv({
      homeDir: NONEXISTENT_HOME,
      files: {
        '.zshrc': 'ANTHROPIC_MODEL="$(rm -rf /)"',
      },
    });
    expect(result.env.ANTHROPIC_MODEL).toBe('$(rm -rf /)');
  });
});
