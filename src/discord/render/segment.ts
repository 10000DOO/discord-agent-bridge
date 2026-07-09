// Segment model + the ImageRenderer port (design §4.1). The renderers layer consumes
// ONLY these types; the puppeteer/mermaid engine (browserRenderer) implements the port
// and is injected as a callback, so the renderers stay discord.js- and puppeteer-free
// (same isolation rule client.ts applies to discord.js).

export type Segment =
  | { kind: 'text'; text: string }
  // `source` is the ORIGINAL markdown for the block, used as the raw-text fallback when
  // rendering is unavailable or fails (so the answer never loses content).
  | { kind: 'table'; source: string }
  | { kind: 'mermaid'; code: string };

// A rendered block, ready to attach. `data` is an in-memory PNG buffer (no temp file →
// nothing to clean up); the client adapter maps it onto a discord.js AttachmentBuilder,
// which accepts a Buffer directly.
export interface RenderedImage {
  data: Buffer;
  name: string;
}

export interface ImageRenderer {
  // Render a table/mermaid segment to a PNG. Returns null on any failure/skip
  // (unavailable, parse error, oversize, timeout) — NEVER throws; the caller falls back
  // to the block's raw text so the answer is never broken.
  render(seg: Extract<Segment, { kind: 'table' | 'mermaid' }>): Promise<RenderedImage | null>;
  // Release any warm browser / held resources on shutdown. Optional so a fake/light renderer
  // need not implement it; the puppeteer-backed renderer closes its Chromium here. Called
  // from the app's shutdown path (SessionWiring.closeImageRenderer). Best-effort.
  close?(): Promise<void>;
}
