import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { shareDocument, threadAsChannel, type DocumentShareOptions } from './documentShare.js';
import type { EditableMessage, MessageChannel, MessageThread, OutgoingMessage } from './ports.js';
import type { ImageRenderer } from './render/segment.js';

// A channel whose startThread is counted and whose thread records every send. The
// channel's own send throws — the core must post the body INSIDE the thread (via the
// threadAsChannel adapter), never to the channel directly.
function fakeChannel() {
  const names: string[] = [];
  const sends: OutgoingMessage[] = [];
  let starts = 0;
  const channel: MessageChannel = {
    async send() {
      throw new Error('channel.send must not be called directly');
    },
    async startThread(name) {
      starts += 1;
      names.push(name);
      const thread: MessageThread = {
        id: `t${starts}`,
        async send(m) {
          sends.push(m);
          return { id: `m${sends.length}`, async edit() {} } as EditableMessage;
        },
      };
      return thread;
    },
  };
  return { channel, names, sends, starts: () => starts };
}

function opts(over: Partial<DocumentShareOptions> = {}): DocumentShareOptions {
  return {
    maxBytes: 524288,
    bodyMode: 'preview',
    previewMaxChars: 8000,
    extensions: ['.md', '.markdown'],
    ...over,
  };
}

// A deterministic renderer (mirrors answerDelivery.test.ts): renders a table/mermaid
// segment to a labeled buffer, or returns null when the source contains 'FAIL' to
// exercise the raw-text fallback. The port's method is .render(seg) — the wiring-side
// variable name `renderImage` is the ImageRenderer itself.
const fakeRenderer: ImageRenderer = {
  async render(seg) {
    const src = seg.kind === 'table' ? seg.source : seg.code;
    if (src.includes('FAIL')) return null;
    return { data: Buffer.from(`png:${seg.kind}`), name: `${seg.kind}.png` };
  },
};

describe('shareDocument', () => {
  let cwd: string;
  let outside: string;

  beforeEach(() => {
    // realpath so comparisons hold on macOS where /var → /private/var.
    cwd = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dab-doc-cwd-')));
    outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'dab-doc-out-')));
  });

  afterEach(() => {
    fs.rmSync(cwd, { recursive: true, force: true });
    fs.rmSync(outside, { recursive: true, force: true });
  });

  it('allows a relative path that escapes the workspace with ../ when the target is valid markdown', async () => {
    fs.writeFileSync(path.join(outside, 'secret.md'), 'top secret');
    const { channel, starts, sends } = fakeChannel();
    const relEscape = path.join('..', path.basename(outside), 'secret.md');
    const res = await shareDocument({
      channel,
      cwd,
      path: relEscape,
      options: opts({ bodyMode: 'attachment_only' }),
    });
    expect(res.ok).toBe(true);
    // Outside cwd → result.path is absolute (realpath-resolved).
    expect(res.path).toBe(path.join(outside, 'secret.md'));
    expect(starts()).toBe(1);
    expect(sends[0].files?.[0]).toMatchObject({ name: 'secret.md', path: path.join(outside, 'secret.md') });
  });

  it('allows an absolute path outside the session folder when the target is valid markdown', async () => {
    fs.writeFileSync(path.join(outside, 'abs.md'), 'outside absolute');
    const absPath = path.join(outside, 'abs.md');
    const { channel, starts, sends } = fakeChannel();
    const res = await shareDocument({
      channel,
      cwd,
      path: absPath,
      options: opts({ bodyMode: 'attachment_only' }),
    });
    expect(res.ok).toBe(true);
    expect(res.path).toBe(absPath);
    expect(starts()).toBe(1);
    expect(sends[0].content).toContain(absPath);
    expect(sends[0].files?.[0]).toMatchObject({ name: 'abs.md', path: absPath });
  });

  it('allows a symlink inside cwd that points outside (realpath) when the target is valid markdown', async () => {
    fs.writeFileSync(path.join(outside, 'target.md'), 'outside body');
    fs.symlinkSync(path.join(outside, 'target.md'), path.join(cwd, 'link.md'));
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({
      channel,
      cwd,
      path: 'link.md',
      options: opts({ bodyMode: 'attachment_only' }),
    });
    expect(res.ok).toBe(true);
    // realpath lands outside cwd → absolute display path.
    expect(res.path).toBe(path.join(outside, 'target.md'));
    expect(starts()).toBe(1);
  });

  it('returns notFound for a missing file (no thread opened)', async () => {
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'nope.md', options: opts() });
    expect(res).toEqual({ ok: false, code: 'notFound' });
    expect(starts()).toBe(0);
  });

  it('returns notFile for a directory', async () => {
    fs.mkdirSync(path.join(cwd, 'adir'));
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'adir', options: opts() });
    expect(res).toEqual({ ok: false, code: 'notFile' });
    expect(starts()).toBe(0);
  });

  it('returns tooLarge when the file exceeds maxBytes', async () => {
    fs.writeFileSync(path.join(cwd, 'big.md'), 'x'.repeat(200));
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'big.md', options: opts({ maxBytes: 100 }) });
    expect(res.ok).toBe(false);
    expect(res.code).toBe('tooLarge');
    // A display-formatted limit is returned so the edge can fill doc.error.tooLarge's {max}.
    expect(res.max).toMatch(/KiB$/);
    expect(starts()).toBe(0);
  });

  it('returns notMarkdown for a non-markdown extension', async () => {
    fs.writeFileSync(path.join(cwd, 'notes.txt'), 'plain text');
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'notes.txt', options: opts() });
    expect(res).toEqual({ ok: false, code: 'notMarkdown' });
    expect(starts()).toBe(0);
  });

  it('attachment_only: opens the thread, attaches the file, posts no body', async () => {
    fs.writeFileSync(path.join(cwd, 'doc.md'), '# Title\n\nbody text');
    const { channel, names, sends, starts } = fakeChannel();
    const res = await shareDocument({
      channel,
      cwd,
      path: 'doc.md',
      options: opts({ bodyMode: 'attachment_only' }),
    });
    expect(res).toEqual({ ok: true, threadName: '📄 doc.md', path: 'doc.md' });
    expect(starts()).toBe(1);
    expect(names[0]).toBe('📄 doc.md');
    // Only the attachment message — no body sends.
    expect(sends).toHaveLength(1);
    expect(sends[0].files).toHaveLength(1);
    expect(sends[0].files?.[0]).toMatchObject({ name: 'doc.md', path: path.join(cwd, 'doc.md') });
  });

  it('preview: clips the body to previewMaxChars and appends a truncation notice', async () => {
    const content = 'A'.repeat(50);
    fs.writeFileSync(path.join(cwd, 'doc.md'), content);
    const { channel, sends } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'doc.md', options: opts({ previewMaxChars: 10 }) });
    expect(res.ok).toBe(true);
    // sends[0] = attachment, sends[1] = body.
    expect(sends[0].files).toHaveLength(1);
    const body = sends[1].content ?? '';
    expect(body.startsWith('A'.repeat(10))).toBe(true);
    expect(body).not.toContain('A'.repeat(11)); // clipped at 10
    expect(body).toContain('preview truncated');
  });

  it('preview: posts the whole body verbatim when under previewMaxChars (no notice)', async () => {
    fs.writeFileSync(path.join(cwd, 'doc.md'), 'short body');
    const { channel, sends } = fakeChannel();
    await shareDocument({ channel, cwd, path: 'doc.md', options: opts({ previewMaxChars: 8000 }) });
    expect(sends[1].content).toBe('short body');
  });

  it('full: posts the entire file body', async () => {
    const content = '# Full\n\n' + 'line\n'.repeat(20);
    fs.writeFileSync(path.join(cwd, 'doc.md'), content);
    const { channel, sends } = fakeChannel();
    await shareDocument({ channel, cwd, path: 'doc.md', options: opts({ bodyMode: 'full', previewMaxChars: 5 }) });
    // previewMaxChars is ignored in full mode → the whole content is posted.
    expect(sends[1].content).toBe(content);
  });

  it('truncates a long thread name to THREAD_NAME_LIMIT (100)', async () => {
    const longBase = 'a'.repeat(200) + '.md';
    fs.writeFileSync(path.join(cwd, longBase), 'body');
    const { channel, names } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: longBase, options: opts() });
    expect(res.ok).toBe(true);
    expect(names[0].length).toBeLessThanOrEqual(100);
    expect(names[0].startsWith('📄 ')).toBe(true);
    expect(names[0].endsWith('…')).toBe(true);
  });

  it('resolves .markdown extension case-insensitively', async () => {
    fs.writeFileSync(path.join(cwd, 'DOC.MARKDOWN'), 'body');
    const { channel } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'DOC.MARKDOWN', options: opts() });
    expect(res.ok).toBe(true);
  });

  it('rejects a .md file whose bytes contain a NUL (binary, D10) — no thread opened', async () => {
    // '#', space, NUL, 'a' — a NUL byte marks the content as binary.
    fs.writeFileSync(path.join(cwd, 'bin.md'), Buffer.from([0x23, 0x20, 0x00, 0x61]));
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'bin.md', options: opts() });
    expect(res).toEqual({ ok: false, code: 'notFile' });
    expect(starts()).toBe(0);
  });

  it('returns notFile for the workspace root itself (empty path) — no thread opened', async () => {
    const { channel, starts } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: '', options: opts() });
    expect(res).toEqual({ ok: false, code: 'notFile' });
    expect(starts()).toBe(0);
  });

  it('the first posted message meta line includes the relative path', async () => {
    fs.mkdirSync(path.join(cwd, 'sub'));
    fs.writeFileSync(path.join(cwd, 'sub', 'doc.md'), 'body');
    const { channel, sends } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: path.join('sub', 'doc.md'), options: opts() });
    expect(res.ok).toBe(true);
    expect(sends[0].content).toContain(path.join('sub', 'doc.md'));
  });

  it('render on: a GFM table becomes an inline image in the thread (text → image → text)', async () => {
    const md = '# Doc\n\nbefore\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter';
    fs.writeFileSync(path.join(cwd, 'doc.md'), md);
    const { channel, sends } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'doc.md', options: opts(), renderImage: fakeRenderer });
    expect(res.ok).toBe(true);
    // sends[0] = meta + .md attachment; the rendered body follows as text → image → text.
    const body = sends.slice(1);
    expect(body.map((s) => (s.files ? 'IMG' : s.content))).toEqual(['# Doc\n\nbefore', 'IMG', 'after']);
    expect(body[1].files?.[0]).toMatchObject({ name: 'table.png' });
    // The rendered PNG travels as an in-memory Buffer (OutgoingFile.path: string|Buffer).
    expect(Buffer.isBuffer(body[1].files?.[0].path)).toBe(true);
  });

  it('render on, renderer returns null: the mermaid block falls back to its raw markdown (no crash)', async () => {
    fs.writeFileSync(path.join(cwd, 'doc.md'), '```mermaid\nFAIL graph TD\n```');
    const { channel, sends } = fakeChannel();
    const res = await shareDocument({ channel, cwd, path: 'doc.md', options: opts(), renderImage: fakeRenderer });
    expect(res.ok).toBe(true);
    // Attachment + one text chunk with the reconstructed fence, verbatim — no image.
    expect(sends).toHaveLength(2);
    expect(sends[1].files).toBeUndefined();
    expect(sends[1].content).toBe('```mermaid\nFAIL graph TD\n```');
  });

  it('render throws: shareDocument propagates the rejection (the edge owns crash-freedom via try/catch)', async () => {
    fs.writeFileSync(path.join(cwd, 'doc.md'), '| a |\n|---|\n| 1 |');
    const throwing: ImageRenderer = {
      async render() {
        throw new Error('render boom');
      },
    };
    const { channel, sends, starts } = fakeChannel();
    // answerDelivery calls renderImage.render(seg) with NO try/catch and deliverAnswer
    // must not be modified (D5), so a throw rejects shareDocument. The production
    // BrowserImageRenderer never throws (null on any failure); the /doc and
    // share_document edges wrap the core in try/catch (docs ch.8) — that is where
    // "no crash" lives, not here.
    await expect(
      shareDocument({ channel, cwd, path: 'doc.md', options: opts(), renderImage: throwing }),
    ).rejects.toThrow('render boom');
    // Partial state by design: the thread and the original .md attachment are already
    // posted before the body step throws (R2's key artifact survives).
    expect(starts()).toBe(1);
    expect(sends[0].files?.[0]).toMatchObject({ name: 'doc.md' });
  });
});

describe('threadAsChannel', () => {
  it('startThread is a throwing stub (pins the D5 invariant)', () => {
    const thread: MessageThread = {
      id: 't1',
      async send() {
        return { id: 'm1', async edit() {} } as EditableMessage;
      },
    };
    const ch = threadAsChannel(thread);
    expect(() => ch.startThread('nested')).toThrow('nested thread unsupported');
  });
});
