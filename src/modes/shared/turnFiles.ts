import * as fs from 'node:fs';
import * as path from 'node:path';
import type { TurnInput } from '../../core/contracts.js';

// Classify TurnInput.files for multimodal backends (Claude/Codex/Grok). Images are
// sent as vision blocks; non-images are mentioned in the text so the agent can Read them.

const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp']);

export interface ClassifiedTurnFile {
  path: string;
  mime: string;
  isImage: boolean;
}

export function classifyTurnFiles(files: NonNullable<TurnInput['files']> | undefined): ClassifiedTurnFile[] {
  if (!files || files.length === 0) return [];
  return files.map((f) => {
    const ext = path.extname(f.path).toLowerCase();
    const fromMime = typeof f.mime === 'string' && f.mime.startsWith('image/');
    const fromExt = IMAGE_EXTS.has(ext);
    const isImage = fromMime || fromExt;
    const mime =
      typeof f.mime === 'string' && f.mime.length > 0
        ? f.mime
        : mimeFromExt(ext) ?? (isImage ? 'image/png' : 'application/octet-stream');
    return { path: f.path, mime, isImage };
  });
}

export function readImageBase64(filePath: string): string {
  return fs.readFileSync(filePath).toString('base64');
}

export function appendNonImageHints(text: string, nonImages: ClassifiedTurnFile[]): string {
  if (nonImages.length === 0) return text;
  const lines = nonImages.map((f) => `Attached file: ${f.path}`);
  const base = text.trim().length > 0 ? text : '';
  return base.length > 0 ? `${base}\n\n${lines.join('\n')}` : lines.join('\n');
}

function mimeFromExt(ext: string): string | undefined {
  switch (ext) {
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.webp':
      return 'image/webp';
    default:
      return undefined;
  }
}
