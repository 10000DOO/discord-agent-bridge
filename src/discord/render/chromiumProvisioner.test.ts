import { describe, it, expect, vi } from 'vitest';
import * as os from 'node:os';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { Browser, type InstalledBrowser } from '@puppeteer/browsers';
import { ChromiumProvisioner, type InstallFn } from './chromiumProvisioner.js';

function tmpCache(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dab-chromium-'));
}

describe('ChromiumProvisioner', () => {
  it('is "installed" when a system Chrome is present (no download needed)', () => {
    const p = new ChromiumProvisioner({ cacheDir: tmpCache(), systemChrome: () => '/usr/bin/google-chrome' });
    expect(p.isInstalled()).toBe(true);
    expect(p.executablePath()).toBe('/usr/bin/google-chrome');
  });

  it('is NOT installed with no system Chrome and an empty cache dir', () => {
    const p = new ChromiumProvisioner({ cacheDir: tmpCache(), systemChrome: () => undefined });
    expect(p.isInstalled()).toBe(false);
    expect(p.executablePath()).toBeUndefined();
  });

  it('install() downloads via the injected fn when nothing is present, returning the path', async () => {
    const installFn: InstallFn = vi.fn(async ({ downloadProgressCallback }) => {
      downloadProgressCallback?.(50, 100);
      downloadProgressCallback?.(100, 100);
      return { executablePath: '/cache/chrome/stable/chrome', browser: Browser.CHROME } as unknown as InstalledBrowser;
    });
    const seen: number[] = [];
    const p = new ChromiumProvisioner({ cacheDir: tmpCache(), systemChrome: () => undefined, installFn });
    const out = await p.install((pct) => seen.push(pct));
    expect(out).toBe('/cache/chrome/stable/chrome');
    expect(installFn).toHaveBeenCalledOnce();
    expect(seen).toContain(50);
    expect(seen).toContain(100);
  });

  it('install() short-circuits (no download) when a system Chrome already exists', async () => {
    const installFn: InstallFn = vi.fn();
    const p = new ChromiumProvisioner({ cacheDir: tmpCache(), systemChrome: () => '/usr/bin/google-chrome', installFn });
    expect(await p.install()).toBe('/usr/bin/google-chrome');
    expect(installFn).not.toHaveBeenCalled();
  });
});
