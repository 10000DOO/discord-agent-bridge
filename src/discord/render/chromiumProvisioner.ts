import * as path from 'node:path';
import {
  Browser,
  install as puppeteerInstall,
  resolveBuildId,
  detectBrowserPlatform,
  getInstalledBrowsers,
  type InstalledBrowser,
} from '@puppeteer/browsers';
import { findChrome } from './chrome.js';
import type { Logger } from '../../core/contracts.js';

// Chromium provisioning (design §6.1/§8.2/§9). Chromium is a ~300MB host resource that is
// NEVER downloaded at npm-install time (.puppeteerrc.cjs skipDownload) nor synchronously
// at answer time. Instead:
//   • a system-installed Chrome is reused when present (no download at all), OR
//   • the operator opts in via a button (at /init) or /config → we download a dedicated
//     Chromium into the app cache dir in the BACKGROUND.
// This module owns detection + background install; the decision (undecided/accepted/
// declined) is persisted in global config by the caller.

// Injectable install fn so tests exercise the flow without a real ~150MB download.
export type InstallFn = (opts: {
  browser: Browser;
  buildId: string;
  cacheDir: string;
  downloadProgressCallback?: (downloaded: number, total: number) => void;
}) => Promise<InstalledBrowser>;

export interface ChromiumProvisionerDeps {
  // Where a provisioned Chromium is cached (persistent; app home, NOT .dab-attachments).
  cacheDir: string;
  logger?: Logger;
  // Overridable for tests (default: the real @puppeteer/browsers install).
  installFn?: InstallFn;
  // System-Chrome detector; overridable for tests (default: real filesystem probe).
  systemChrome?: () => string | undefined;
}

export class ChromiumProvisioner {
  private readonly cacheDir: string;
  private readonly logger: Logger | undefined;
  private readonly installFn: InstallFn;
  private readonly systemChrome: () => string | undefined;

  constructor(deps: ChromiumProvisionerDeps) {
    this.cacheDir = deps.cacheDir;
    this.logger = deps.logger;
    this.installFn = deps.installFn ?? (puppeteerInstall as unknown as InstallFn);
    this.systemChrome = deps.systemChrome ?? findChrome;
  }

  // The browser executable to launch: prefer a system Chrome (no download), else a
  // previously provisioned Chromium in the cache dir. undefined → nothing usable.
  executablePath(): string | undefined {
    const system = this.systemChrome();
    if (system) return system;
    return this.provisionedPath();
  }

  // True when SOMETHING launchable exists (system or provisioned) — the render gate.
  isInstalled(): boolean {
    return this.executablePath() !== undefined;
  }

  private provisionedPath(): string | undefined {
    try {
      const browsers = getInstalledBrowsers({ cacheDir: this.cacheDir });
      // getInstalledBrowsers is sync in current versions but tolerate a thenable.
      const list = browsers as unknown as InstalledBrowser[];
      const chrome = Array.isArray(list) ? list.find((b) => b.browser === Browser.CHROME) : undefined;
      return chrome?.executablePath;
    } catch {
      return undefined;
    }
  }

  // Download Chromium into the cache dir (background). Best-effort progress via callback.
  // Returns the executable path on success; throws on failure (caller reports + keeps
  // the raw-text fallback). No-op-ish when already installed (returns existing path).
  async install(onProgress?: (pct: number) => void): Promise<string> {
    const existing = this.executablePath();
    if (existing) return existing;
    const platform = detectBrowserPlatform();
    if (!platform) throw new Error('unsupported platform for Chromium download');
    const buildId = await resolveBuildId(Browser.CHROME, platform, 'stable');
    let lastPct = -1;
    const installed = await this.installFn({
      browser: Browser.CHROME,
      buildId,
      cacheDir: this.cacheDir,
      downloadProgressCallback: (downloaded, total) => {
        if (!onProgress || !total) return;
        const pct = Math.floor((downloaded / total) * 100);
        if (pct !== lastPct && pct % 10 === 0) {
          lastPct = pct;
          onProgress(pct);
        }
      },
    });
    this.logger?.info('chromium provisioned', { path: installed.executablePath, buildId });
    return installed.executablePath;
  }

  // The default cache dir for a given app home.
  static cacheDirFor(appHome: string): string {
    return path.join(appHome, 'chromium');
  }
}
