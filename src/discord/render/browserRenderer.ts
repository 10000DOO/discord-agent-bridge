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

  constructor(deps: { logger?: Logger; executablePath?: string } = {}) {
    this.logger = deps.logger;
    this.executablePath = deps.executablePath;
  }

  private getBrowser(): Promise<Browser> {
    if (!this.browserPromise) {
      const executablePath = this.executablePath ?? findChrome();
      this.browserPromise = puppeteer.launch({
        headless: true,
        ...(executablePath ? { executablePath } : {}),
        args: ['--disable-gpu', '--disable-dev-shm-usage'],
      });
    }
    return this.browserPromise;
  }

  async close(): Promise<void> {
    if (this.browserPromise) {
      const b = await this.browserPromise.catch(() => null);
      this.browserPromise = null;
      if (b) await b.close().catch(() => {});
    }
  }

  private async withPage<T>(fn: (page: Page) => Promise<T>): Promise<T> {
    const browser = await this.getBrowser();
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900, deviceScaleFactor: 2 });
    // Hard-block egress: abort any network request; offline mode as an absolute gate.
    await page.setRequestInterception(true);
    page.on('request', (req) => {
      if (/^(https?|wss?|ftp):/i.test(req.url())) void req.abort().catch(() => {});
      else void req.continue().catch(() => {}); // data:/blob:/about: — local, no egress
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
