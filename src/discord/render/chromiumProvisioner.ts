import * as fs from 'node:fs';
import * as path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Browser, install as puppeteerInstall, resolveBuildId, detectBrowserPlatform } from '@puppeteer/browsers';
import { findChrome } from './chrome.js';
import type { Logger } from '../../core/contracts.js';

const execFileP = promisify(execFile);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Chromium provisioning (design §6.1/§8.2/§9). Chromium is a ~300MB host resource that is
// NEVER downloaded at npm-install time (.puppeteerrc.cjs skipDownload) nor synchronously
// at answer time. Instead: a system Chrome is reused when present, or the operator opts in
// via a button (/init, /config) → we download a dedicated Chromium in the BACKGROUND.
//
// macOS note: @puppeteer/browsers' install() has two issues on macOS — its promise can
// stay UNSETTLED after the download, and its built-in extractor produces a broken .app
// bundle (missing Frameworks → the browser can't launch). So we use it only to DOWNLOAD
// the .zip (reliable, clean progress), detect the finished download by polling the .zip
// for a stable size, then extract with the system `unzip` (handles .app bundles). Detection
// scans the cache filesystem (getInstalledBrowsers is async; a sync scan keeps this simple).

// The provisioning step (download + extract) as an injectable seam so tests exercise the
// flow without a real ~150MB download: given a target cache dir, make a launchable browser
// appear under it. Reports download progress (0–100) via onProgress.
export type ProvisionFn = (opts: {
  browser: Browser;
  buildId: string;
  platform: string;
  cacheDir: string;
  onProgress?: (pct: number) => void;
}) => Promise<void>;

export interface ChromiumProvisionerDeps {
  cacheDir: string;
  logger?: Logger;
  provisionFn?: ProvisionFn;
  // System-Chrome detector; overridable for tests (default: real filesystem probe).
  systemChrome?: () => string | undefined;
}

export class ChromiumProvisioner {
  private readonly cacheDir: string;
  private readonly logger: Logger | undefined;
  private readonly provisionFn: ProvisionFn;
  private readonly systemChrome: () => string | undefined;

  constructor(deps: ChromiumProvisionerDeps) {
    this.cacheDir = deps.cacheDir;
    this.logger = deps.logger;
    this.provisionFn = deps.provisionFn ?? ((opts) => this.downloadAndExtract(opts));
    this.systemChrome = deps.systemChrome ?? findChrome;
  }

  // The browser executable to launch: prefer a system Chrome (no download), else a
  // previously provisioned Chromium in the cache dir. undefined → nothing usable.
  executablePath(): string | undefined {
    return this.systemChrome() ?? this.provisionedPath();
  }

  // True when SOMETHING launchable exists (system or provisioned) — the render gate.
  isInstalled(): boolean {
    return this.executablePath() !== undefined;
  }

  // Scan the cache dir for a downloaded Chromium executable, cross-platform.
  private provisionedPath(): string | undefined {
    try {
      const base = path.join(this.cacheDir, 'chrome');
      if (!fs.existsSync(base)) return undefined;
      for (const dir of fs.readdirSync(base)) {
        const inner = path.join(base, dir);
        const candidates = [
          path.join(inner, 'chrome-mac-arm64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'),
          path.join(inner, 'chrome-mac-x64', 'Google Chrome for Testing.app', 'Contents', 'MacOS', 'Google Chrome for Testing'),
          path.join(inner, 'chrome-linux64', 'chrome'),
          path.join(inner, 'chrome-win64', 'chrome.exe'),
        ];
        for (const c of candidates) if (fs.existsSync(c)) return c;
      }
      return undefined;
    } catch {
      return undefined;
    }
  }

  // Real download + extract. Kicks off @puppeteer/browsers install() only for its download
  // (its promise may hang and its extractor is broken on macOS — both ignored); waits for
  // the .zip to finish (size-stable), then extracts with the system `unzip`.
  private async downloadAndExtract(opts: Parameters<ProvisionFn>[0]): Promise<void> {
    const { browser, buildId, platform, cacheDir, onProgress } = opts;
    const chromeDir = path.join(cacheDir, 'chrome');
    let last = -1;
    void puppeteerInstall({
      browser,
      buildId,
      cacheDir,
      downloadProgressCallback: (downloaded: number, total: number) => {
        if (!onProgress || !total) return;
        const pct = Math.min(99, Math.floor((downloaded / total) * 100)); // 100 after unzip
        if (pct !== last && pct % 10 === 0) {
          last = pct;
          onProgress(pct);
        }
      },
    } as Parameters<typeof puppeteerInstall>[0]).catch(() => {
      /* hang / broken-extraction ignored — we poll for the zip and unzip ourselves */
    });

    const findZip = (): string | undefined => {
      try {
        return fs.readdirSync(chromeDir).filter((f) => f.endsWith('.zip')).map((f) => path.join(chromeDir, f))[0];
      } catch {
        return undefined;
      }
    };
    const deadline = Date.now() + 10 * 60 * 1000;
    let zip: string | undefined;
    let prevSize = -1;
    let stable = 0;
    while (Date.now() < deadline) {
      zip = findZip();
      if (zip) {
        const size = fs.statSync(zip).size;
        if (size === prevSize && size > 0) {
          if (++stable >= 2) break;
        } else {
          stable = 0;
          prevSize = size;
        }
      }
      await sleep(1500);
    }
    if (!zip) throw new Error('chromium download did not produce a .zip');

    const destDir = path.join(chromeDir, `${platform}-${buildId}`);
    fs.rmSync(destDir, { recursive: true, force: true }); // drop any broken stub
    await execFileP('unzip', ['-q', '-o', zip, '-d', destDir]);
    fs.rmSync(zip, { force: true });
    if (onProgress) onProgress(100);
    this.logger?.info('chromium provisioned', { destDir, buildId });
  }

  // Download Chromium into the cache dir (background). No-op (returns the existing path)
  // when a browser is already available. Throws on failure; the caller reports it and
  // keeps the raw-text fallback.
  async install(onProgress?: (pct: number) => void): Promise<string> {
    const existing = this.executablePath();
    if (existing) return existing;
    const platform = detectBrowserPlatform();
    if (!platform) throw new Error('unsupported platform for Chromium download');
    const buildId = await resolveBuildId(Browser.CHROME, platform, 'stable');
    await this.provisionFn({ browser: Browser.CHROME, buildId, platform, cacheDir: this.cacheDir, ...(onProgress ? { onProgress } : {}) });
    const exe = this.provisionedPath();
    if (!exe) throw new Error('chromium install produced no executable');
    return exe;
  }

  // The default cache dir for a given app home.
  static cacheDirFor(appHome: string): string {
    return path.join(appHome, 'chromium');
  }
}
