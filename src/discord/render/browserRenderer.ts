import * as path from 'node:path';
import { createRequire } from 'node:module';
import puppeteer, { type Browser, type Page } from 'puppeteer';
import type { ImageRenderer, RenderedImage, Segment } from './segment.js';
import { tableCellCount } from './blockParser.js';
import { buildTableHtml, buildMermaidHtml } from './htmlTemplates.js';
import { findChrome } from './chrome.js';
import type { Logger } from '../../core/contracts.js';

// The puppeteer/mermaid render engine — the ONE module that imports puppeteer, kept
// isolated like client.ts isolates discord.js. It implements the ImageRenderer port
// (segment → PNG) that the renderers layer consumes via injection.
//
// Hardening (design §6.7/§10.3): the table/mermaid content is UNTRUSTED. Every render
// runs in a page with (a) all outbound network blocked (request interception + offline)
// so a crafted block can never exfiltrate the prompt or fetch a remote resource, (b) a
// wall-clock timeout so a pathological diagram can't hang the browser, and (c) input
// size caps. mermaid runs with securityLevel:'strict'. render() NEVER throws — any
// failure returns null and the caller falls back to raw text.

const RENDER_TIMEOUT_MS = 15_000;
const MAX_BLOCK_CHARS = 20_000;
const MAX_TABLE_CELLS = 2_000;
// Cap concurrent pages so a burst of renders can't spawn unbounded tabs (memory/CPU).
const MAX_CONCURRENT_RENDERS = 2;
// Close the warm browser after this idle gap to return its ~100–300MB resident memory;
// the next render relaunches it lazily (getBrowser), so this is transparent.
const IDLE_SHUTDOWN_MS = 5 * 60 * 1000;

const require = createRequire(import.meta.url);

// Path to mermaid's browser bundle, resolved from the installed dependency so it is
// injected locally (offline) — never fetched from a CDN.
function mermaidBundlePath(): string {
  // mermaid's package root → dist/mermaid.min.js
  const pkg = require.resolve('mermaid/package.json');
  return path.join(path.dirname(pkg), 'dist', 'mermaid.min.js');
}

export class BrowserImageRenderer implements ImageRenderer {
  private browserPromise: Promise<Browser> | null = null;
  private readonly logger: Logger | undefined;
  // Explicit browser executable (a provisioned Chromium). When absent, fall back to a
  // system Chrome; when neither, let puppeteer resolve its own (may fail → null render).
  private readonly executablePath: string | undefined;
  // Concurrency gate: `active` counts in-flight renders (≤ MAX_CONCURRENT_RENDERS); when
  // full, extra renders park their resume callback in `waiters` and are handed a slot on
  // release (FIFO), so a render burst never opens more than the cap of pages at once.
  private active = 0;
  private readonly waiters: Array<() => void> = [];
  // Idle-shutdown timer: (re)armed when the last render finishes; firing closes the warm
  // browser. Cleared while a render is running so the browser can't close mid-render.
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  // Best-effort browser close on process exit, a backstop to the normal shutdown path
  // (SessionWiring.closeImageRenderer via app.destroy). Registered once with process.once,
  // so it fires at most once at real termination; kept across idle-close/relaunch cycles.
  private readonly onExit = () => { void this.close(); };

  constructor(deps: { logger?: Logger; executablePath?: string } = {}) {
    this.logger = deps.logger;
    this.executablePath = deps.executablePath;
    process.once('exit', this.onExit);
  }

  // Acquire one render slot: proceed immediately when under the cap, else wait for a
  // release to hand this one a slot (active stays at the cap during the handoff).
  private acquire(): Promise<void> {
    if (this.active < MAX_CONCURRENT_RENDERS) {
      this.active += 1;
      return Promise.resolve();
    }
    return new Promise<void>((resolve) => this.waiters.push(resolve));
  }

  // Release a render slot: hand it directly to the next waiter (keeping `active`), or drop
  // `active` and, once no render is left running, arm the idle-shutdown timer.
  private release(): void {
    const next = this.waiters.shift();
    if (next) {
      next();
      return;
    }
    this.active -= 1;
    if (this.active === 0) this.scheduleIdleShutdown();
  }

  private scheduleIdleShutdown(): void {
    this.clearIdleTimer();
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      void this.close();
    }, IDLE_SHUTDOWN_MS);
    // Don't let the idle timer keep the event loop (and the process) alive on its own.
    this.idleTimer.unref?.();
  }

  private clearIdleTimer(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  }

  private getBrowser(): Promise<Browser> {
    if (!this.browserPromise) {
      const executablePath = this.executablePath ?? findChrome();
      this.browserPromise = puppeteer
        .launch({
          headless: true,
          ...(executablePath ? { executablePath } : {}),
          args: ['--disable-gpu', '--disable-dev-shm-usage'],
        })
        .catch((e) => {
          // A launch failure must NOT poison the cache: null it so the next render retries.
          // Otherwise a single transient failure (missing shared lib, cold-boot race) would
          // wedge rendering off for the whole process lifetime.
          this.browserPromise = null;
          throw e;
        });
    }
    return this.browserPromise;
  }

  async close(): Promise<void> {
    this.clearIdleTimer();
    if (this.browserPromise) {
      const b = await this.browserPromise.catch(() => null);
      this.browserPromise = null;
      if (b) await b.close().catch(() => {});
    }
  }

  private async withPage<T>(fn: (page: Page) => Promise<T>): Promise<T> {
    // Serialize under the concurrency cap and hold off idle-shutdown while a render runs.
    await this.acquire();
    this.clearIdleTimer();
    try {
      const browser = await this.getBrowser();
      const page = await browser.newPage();
      await page.setViewport({ width: 1400, height: 900, deviceScaleFactor: 2 });
      // Hard-block egress: allow ONLY local, egress-free schemes (data:/blob:/about:) and
      // abort everything else; offline mode as an absolute gate.
      await page.setRequestInterception(true);
      page.on('request', (req) => {
        if (/^(data|blob|about):/i.test(req.url())) void req.continue().catch(() => {});
        else void req.abort().catch(() => {}); // http(s)/ws/ftp/file/… — never fetched
      });
      await page.setOfflineMode(true);
      try {
        let timer: ReturnType<typeof setTimeout>;
        const timeout = new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new Error('render timeout')), RENDER_TIMEOUT_MS);
        });
        try {
          return await Promise.race([fn(page), timeout]);
        } finally {
          clearTimeout(timer!);
        }
      } finally {
        await page.close().catch(() => {});
      }
    } finally {
      this.release();
    }
  }

  private renderTable(tableMd: string): Promise<Buffer> {
    return this.withPage(async (page) => {
      await page.setJavaScriptEnabled(false); // static HTML — no scripts needed
      await page.setContent(buildTableHtml(tableMd), { waitUntil: 'load' });
      const el = await page.$('#c');
      if (!el) throw new Error('table container missing');
      return Buffer.from(await el.screenshot({ type: 'png' }));
    });
  }

  private renderMermaid(code: string): Promise<Buffer> {
    return this.withPage(async (page) => {
      await page.setContent(buildMermaidHtml(), { waitUntil: 'load' });
      await page.addScriptTag({ path: mermaidBundlePath() });
      const res = await page.evaluate(async (src: string) => {
        try {
          const m = (window as unknown as { mermaid: {
            initialize: (o: unknown) => void;
            render: (id: string, s: string) => Promise<{ svg: string }>;
          } }).mermaid;
          m.initialize({ startOnLoad: false, theme: 'dark', securityLevel: 'strict' });
          const { svg } = await m.render('g0', src);
          document.getElementById('c')!.innerHTML = svg;
          return true as const;
        } catch (e) {
          return String((e as { message?: string })?.message ?? e);
        }
      }, code);
      if (res !== true) throw new Error(`mermaid: ${res}`);
      const el = await page.$('#c');
      if (!el) throw new Error('mermaid container missing');
      return Buffer.from(await el.screenshot({ type: 'png' }));
    });
  }

  async render(seg: Extract<Segment, { kind: 'table' | 'mermaid' }>): Promise<RenderedImage | null> {
    const raw = seg.kind === 'table' ? seg.source : seg.code;
    // Size guard: a pathological block spikes CPU/memory → skip (raw-text fallback).
    if (raw.length > MAX_BLOCK_CHARS) return null;
    if (seg.kind === 'table' && tableCellCount(seg.source) > MAX_TABLE_CELLS) return null;
    try {
      if (seg.kind === 'table') {
        return { data: await this.renderTable(seg.source), name: 'table.png' };
      }
      return { data: await this.renderMermaid(seg.code), name: 'diagram.png' };
    } catch (err) {
      this.logger?.debug('image render failed (raw fallback)', {
        kind: seg.kind,
        err: err instanceof Error ? err.message : String(err),
      });
      return null;
    }
  }
}
