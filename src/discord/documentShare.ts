// Share a markdown document from the session workspace into a Discord thread:
// open a document thread, attach the original `.md`, and post the file's own text
// (never an AI re-summary) as the body. The single core the /doc slash command and
// the per-backend `share_document` tools all funnel through (via SessionWiring).
//
// Deliberate boundaries (see docs/document-share-and-viewer.md §3):
//
//  1. Path-confined. Every requested path is realpath-resolved and must stay inside
//     the session workspace root. The confinement pattern is REPLICATED from
//     modes/claude/mcpFileTool.ts (attachFileConfined/realpathOrResolve/isWithin) —
//     one of four intentional import-free copies; it is NOT extracted into a shared
//     util (D4). Symlink escapes are caught by realpath + path.relative, not a string
//     prefix check.
//  2. deliverAnswer reuse via a thin adapter. The body is posted through the shared
//     deliverAnswer path so tables/mermaid render exactly as elsewhere. deliverAnswer
//     wants a MessageChannel (send + startThread) but a thread only sends, so we wrap
//     it with threadAsChannel whose startThread is a throwing stub — deliverAnswer's
//     signature is NOT modified (D5). When renderImage is absent this is byte-for-byte
//     the plain chunkMessage behavior.
//  3. Discord-layer only. Depends on the ports + format + answerDelivery of this layer;
//     never imports core (providerCatalog/permissionSource) so there is no cycle.

import * as fs from 'node:fs';
import * as path from 'node:path';
import type { MessageChannel, MessageThread } from './ports.js';
import type { ImageRenderer } from './render/segment.js';
import { truncate, THREAD_NAME_LIMIT } from './format.js';
import { deliverAnswer } from './renderers/answerDelivery.js';

// full = post the whole file (within maxBytes); preview = the first previewMaxChars
// characters (with a 1-line notice when truncated); attachment_only = the `.md`
// attachment with no body text.
export type BodyMode = 'full' | 'preview' | 'attachment_only';

// A per-cause rejection code. The core returns the code only; the edge (slash / tool)
// localizes it via t('doc.error.'+code) so the core stays i18n-free.
export type ShareErrorCode = 'notFound' | 'escape' | 'tooLarge' | 'notMarkdown' | 'notFile';

export interface DocumentShareOptions {
  maxBytes: number;
  bodyMode: BodyMode;
  previewMaxChars: number;
  extensions: string[];
}

export interface ShareResult {
  ok: boolean;
  // The created thread's name (`📄 <basename>`, truncated) — present on success.
  threadName?: string;
  // The shared file's path relative to the workspace root — present on success.
  path?: string;
  // The rejection cause — present on failure.
  code?: ShareErrorCode;
  // A display-formatted size limit (e.g. `512.0 KiB`) — present on a tooLarge rejection
  // so the edge can fill the {max} placeholder of doc.error.tooLarge.
  max?: string;
}

export interface ShareRequest {
  channel: MessageChannel;
  cwd: string;
  path: string;
  options: DocumentShareOptions;
  // Absent → text-only body (render branch off / Chrome unavailable). Present → the
  // body's tables/mermaid become inline PNGs via deliverAnswer. Wired in WO-6.
  renderImage?: ImageRenderer;
}

// Appended when a preview is cut short. The full document is always the first thread
// message's attachment, so it sits above this body.
const PREVIEW_NOTICE = '\n\n… (preview truncated — full document attached above)';

export async function shareDocument(req: ShareRequest): Promise<ShareResult> {
  const { options } = req;

  // (a) Confinement — realpath the workspace root and the candidate, reject anything
  // that escapes it. Mirrors attachFileConfined (mcpFileTool.ts). Runs BEFORE any
  // thread is opened so a rejected path never creates a thread.
  const root = realpathOrResolve(req.cwd);
  const resolved = realpathOrResolve(path.resolve(root, req.path));
  if (!isWithin(root, resolved)) return { ok: false, code: 'escape' };

  // (b) Existence + must be a regular file. Rejecting every non-regular file (not just
  // directories) mirrors fileDownload.ts and avoids a readFileSync hang on a FIFO/socket.
  let stat: fs.Stats;
  try {
    stat = fs.statSync(resolved);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return { ok: false, code: 'notFound' };
    throw err;
  }
  if (!stat.isFile()) return { ok: false, code: 'notFile' };

  // (c) Extension must be one of the configured markdown extensions.
  const ext = path.extname(resolved).toLowerCase();
  if (!options.extensions.some((e) => e.toLowerCase() === ext)) {
    return { ok: false, code: 'notMarkdown' };
  }

  // (d) Size guard. Return the limit in the same KiB format used for the size meta line
  // below so the edge can render {max} instead of a literal placeholder.
  if (stat.size > options.maxBytes) {
    return { ok: false, code: 'tooLarge', max: `${(options.maxBytes / 1024).toFixed(1)} KiB` };
  }

  // (e) Read the file and reject binary content (D10). A NUL byte cannot occur in normal
  // UTF-8 text/markdown, so it is a cheap, dependency-free binary sniff. Runs BEFORE any
  // thread is opened so a binary file never creates a thread; the content is reused for
  // the body below.
  const content = fs.readFileSync(resolved, 'utf-8');
  const NUL = String.fromCharCode(0);
  if (content.includes(NUL)) return { ok: false, code: 'notFile' };

  const basename = path.basename(resolved);
  const relPath = path.relative(root, resolved);

  // (f + g) Open the document thread. startThread does NOT truncate — the caller owns
  // the THREAD_NAME_LIMIT cap (format.ts).
  const threadName = truncate('📄 ' + basename, THREAD_NAME_LIMIT);
  const thread = await req.channel.startThread(threadName);

  // (h) First message: a short meta line + the original .md as an attachment (always
  // present — the plugin input contract, R7). discord.js reads the file from `path`.
  const meta = `\`${relPath}\` · ${(stat.size / 1024).toFixed(1)} KiB`;
  await thread.send({ content: meta, files: [{ path: resolved, name: basename }] });

  // (i) Body per bodyMode. attachment_only posts nothing further; preview clips to
  // previewMaxChars; full posts the whole file. deliverAnswer renders tables/mermaid
  // when renderImage is present, otherwise it is the plain chunkMessage behavior.
  if (options.bodyMode !== 'attachment_only') {
    const bodyText =
      options.bodyMode === 'preview' && content.length > options.previewMaxChars
        ? content.slice(0, options.previewMaxChars) + PREVIEW_NOTICE
        : content;
    await deliverAnswer(bodyText, { channel: threadAsChannel(thread), renderImage: req.renderImage });
  }

  // (j)
  return { ok: true, threadName, path: relPath };
}

// Wrap a send-only MessageThread as a MessageChannel so deliverAnswer can post the
// body inside the thread without changing its signature (D5). Nested threading is
// unreachable here (deliverAnswer only ever calls send), so startThread is a throwing
// stub that documents the invariant rather than silently returning a bad value.
export function threadAsChannel(thread: MessageThread): MessageChannel {
  return {
    send: (m) => thread.send(m),
    startThread: () => {
      throw new Error('threadAsChannel: nested thread unsupported');
    },
  };
}

// --- Path confinement (replicated from mcpFileTool.ts; DO NOT consolidate — D4) ---

// Realpath a path, falling back to the realpath of its deepest existing ancestor
// joined with the non-existent tail — so confinement holds for paths that do not
// exist yet while still resolving symlinks in the part that does.
function realpathOrResolve(target: string): string {
  const abs = path.resolve(target);
  let existing = abs;
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break; // reached the filesystem root
    tail.unshift(path.basename(existing));
    existing = parent;
  }
  try {
    const realExisting = fs.realpathSync(existing);
    return tail.length > 0 ? path.join(realExisting, ...tail) : realExisting;
  } catch {
    return abs;
  }
}

// True when `child` is the same as, or nested under, `root`. Uses path.relative so it
// is not fooled by shared string prefixes (e.g. /ws vs /ws-evil).
function isWithin(root: string, child: string): boolean {
  const rel = path.relative(root, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
