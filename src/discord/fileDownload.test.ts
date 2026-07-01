import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { FileDownload, WorkspaceEscapeError } from './fileDownload.js';

let root: string;
let outside: string;

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-ws-'));
  outside = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-out-'));
  fs.mkdirSync(path.join(root, 'src'));
  fs.writeFileSync(path.join(root, 'src', 'a.ts'), 'export const a = 1;');
  fs.writeFileSync(path.join(outside, 'secret.txt'), 'nope');
});
afterEach(() => {
  fs.rmSync(root, { recursive: true, force: true });
  fs.rmSync(outside, { recursive: true, force: true });
});

describe('FileDownload', () => {
  it('downloads an in-workspace file', () => {
    const dl = new FileDownload(root);
    const file = dl.download('src/a.ts');
    expect(file.path).toBe(fs.realpathSync(path.join(root, 'src', 'a.ts')));
    expect(file.name).toBe('a.ts');
  });

  it('browses an in-workspace directory (dirs first, dotfiles hidden)', () => {
    fs.mkdirSync(path.join(root, '.git'));
    const dl = new FileDownload(root);
    const entries = dl.browse('.');
    expect(entries.map((e) => e.name)).toEqual(['src']);
    expect(entries[0].isDirectory).toBe(true);
  });

  it('rejects a path escaping the workspace via ..', () => {
    const dl = new FileDownload(root);
    const rel = path.join('..', path.basename(outside), 'secret.txt');
    expect(() => dl.download(rel)).toThrow(WorkspaceEscapeError);
  });

  it('rejects an absolute path outside the workspace', () => {
    const dl = new FileDownload(root);
    expect(() => dl.download(path.join(outside, 'secret.txt'))).toThrow(WorkspaceEscapeError);
  });

  it('rejects a symlink that points outside the workspace', () => {
    const link = path.join(root, 'escape');
    try {
      fs.symlinkSync(outside, link);
    } catch {
      return; // symlinks unsupported on this platform — skip
    }
    const dl = new FileDownload(root);
    expect(() => dl.download(path.join('escape', 'secret.txt'))).toThrow(WorkspaceEscapeError);
  });

  it('throws a plain error for a missing file or a directory target', () => {
    const dl = new FileDownload(root);
    expect(() => dl.download('src/missing.ts')).toThrow(/not found/i);
    expect(() => dl.download('src')).toThrow(/not a file/i);
  });
});
