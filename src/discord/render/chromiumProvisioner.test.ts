import { describe, it, expect, vi } from 'vitest';
import * as os from 'node:os';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { ChromiumProvisioner, type ProvisionFn } from './chromiumProvisioner.js';

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

  it('detects a provisioned Chromium on disk (cross-platform layout scan)', () => {
    const cacheDir = tmpCache();
    // Mimic the extracted layout: <cache>/chrome/<platform>-<buildId>/chrome-linux64/chrome
    const exe = path.join(cacheDir, 'chrome', 'linux-123', 'chrome-linux64', 'chrome');
    fs.mkdirSync(path.dirname(exe), { recursive: true });
    fs.writeFileSync(exe, '#!/bin/true\n');
    const p = new ChromiumProvisioner({ cacheDir, systemChrome: () => undefined });
    expect(p.isInstalled()).toBe(true);
    expect(p.executablePath()).toBe(exe);
  });

  it('install() runs the provision step, reports progress, and returns the executable', async () => {
    const cacheDir = tmpCache();
    const seen: number[] = [];
    // Fake provision: create a launchable executable at a scanned path + report progress.
    const provisionFn: ProvisionFn = vi.fn(async ({ onProgress }) => {
      onProgress?.(50);
      const exe = path.join(cacheDir, 'chrome', 'linux-123', 'chrome-linux64', 'chrome');
      fs.mkdirSync(path.dirname(exe), { recursive: true });
      fs.writeFileSync(exe, '#!/bin/true\n');
      onProgress?.(100);
    });
    const p = new ChromiumProvisioner({ cacheDir, systemChrome: () => undefined, provisionFn });
    const out = await p.install((pct) => seen.push(pct));
    expect(out).toContain('chrome-linux64');
    expect(provisionFn).toHaveBeenCalledOnce();
    expect(seen).toEqual([50, 100]);
  });

  it('install() short-circuits (no provision) when a system Chrome already exists', async () => {
    const provisionFn: ProvisionFn = vi.fn();
    const p = new ChromiumProvisioner({ cacheDir: tmpCache(), systemChrome: () => '/usr/bin/google-chrome', provisionFn });
    expect(await p.install()).toBe('/usr/bin/google-chrome');
    expect(provisionFn).not.toHaveBeenCalled();
  });

  it('joins concurrent install() calls into ONE in-flight provision (no duplicate download)', async () => {
    const cacheDir = tmpCache();
    let release!: () => void;
    const gate = new Promise<void>((r) => { release = r; });
    // The provision blocks until released, so the second install() lands while the first is
    // still running — the guard must make it join, not start a second download/unzip.
    const provisionFn: ProvisionFn = vi.fn(async () => {
      await gate;
      const exe = path.join(cacheDir, 'chrome', 'linux-123', 'chrome-linux64', 'chrome');
      fs.mkdirSync(path.dirname(exe), { recursive: true });
      fs.writeFileSync(exe, '#!/bin/true\n');
    });
    const p = new ChromiumProvisioner({ cacheDir, systemChrome: () => undefined, provisionFn });
    const first = p.install();
    const second = p.install();
    release();
    const [a, b] = await Promise.all([first, second]);
    expect(a).toBe(b);
    expect(a).toContain('chrome-linux64');
    expect(provisionFn).toHaveBeenCalledOnce();
    // After it settles the guard is cleared, so a later install() short-circuits on the
    // now-present executable (still no second provision).
    expect(await p.install()).toBe(a);
    expect(provisionFn).toHaveBeenCalledOnce();
  });
});
