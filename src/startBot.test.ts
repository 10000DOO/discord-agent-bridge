import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { startBot } from './app.js';
import { ConfigStore } from './core/config.js';
import { CONFIG_DEFAULTS, CONFIG_VERSION, type AppConfig } from './core/configSchema.js';

// startBot's first-run guardrails (§ friendly startup errors): a config-less or
// token-less boot must print a short, actionable "run --setup" message and set a
// non-zero exit code — NOT throw a raw stack trace. Genuine errors (a corrupt
// config) still propagate. Every case uses a temp DAB home so the real ~/.config
// is never touched, and no real Discord login happens (we bail before createApp).

function makeConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    ...CONFIG_DEFAULTS,
    version: CONFIG_VERSION,
    discord: { token: 'fake-token-value', clientId: 'client-id-000' },
    ...overrides,
  } as AppConfig;
}

describe('startBot — first-run guardrails', () => {
  let dir: string;
  let errSpy: ReturnType<typeof vi.spyOn>;
  let prevExitCode: typeof process.exitCode;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-boot-'));
    errSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    prevExitCode = process.exitCode;
    process.exitCode = undefined;
  });
  afterEach(() => {
    errSpy.mockRestore();
    process.exitCode = prevExitCode;
    fs.rmSync(dir, { recursive: true, force: true });
  });

  it('no config file → friendly "run --setup" message + non-zero exit, no throw', async () => {
    // Empty temp dir: no config.json exists.
    expect(new ConfigStore(dir).exists()).toBe(false);

    const app = await startBot({ baseDir: dir });

    expect(app).toBeUndefined();
    expect(process.exitCode).toBe(1);
    expect(errSpy).toHaveBeenCalledTimes(1);
    const msg = String(errSpy.mock.calls[0]?.[0]);
    expect(msg).toContain('--setup');
    // Friendly text, not an Error/stack trace.
    expect(msg).not.toMatch(/\bError\b|\bat \S+:\d+/);
  });

  it('config present but empty token → friendly token message + non-zero exit, no throw', async () => {
    const store = new ConfigStore(dir);
    store.save(makeConfig({ discord: { token: '', clientId: 'client-id-000' } }));

    const app = await startBot({ baseDir: dir });

    expect(app).toBeUndefined();
    expect(process.exitCode).toBe(1);
    expect(errSpy).toHaveBeenCalledTimes(1);
    const msg = String(errSpy.mock.calls[0]?.[0]);
    // Korean default token guidance mentions --setup and does not leak a stack.
    expect(msg).toContain('--setup');
    expect(msg).not.toMatch(/\bError\b|\bat \S+:\d+/);
  });

  it('a whitespace-only token is treated as missing (friendly path, non-zero exit)', async () => {
    const store = new ConfigStore(dir);
    store.save(makeConfig({ discord: { token: '   ', clientId: 'client-id-000' } }));

    const app = await startBot({ baseDir: dir });

    expect(app).toBeUndefined();
    expect(process.exitCode).toBe(1);
    expect(errSpy).toHaveBeenCalledTimes(1);
  });

  it('a present-but-invalid config still THROWS (real bug, not the friendly path)', async () => {
    const store = new ConfigStore(dir);
    fs.mkdirSync(dir, { recursive: true });
    // Missing the required discord section → zod rejects on load.
    fs.writeFileSync(store.configPath, JSON.stringify({ locale: 'ko' }), 'utf-8');

    await expect(startBot({ baseDir: dir })).rejects.toThrow();
    // Not swallowed into the friendly exit path.
    expect(process.exitCode).toBeUndefined();
  });
});
