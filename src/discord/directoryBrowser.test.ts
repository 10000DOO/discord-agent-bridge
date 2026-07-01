import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { DirectoryBrowser } from './directoryBrowser.js';

let root: string;

beforeEach(() => {
  // root/
  //   sub/
  //     nested/
  //   file.txt
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-dir-'));
  fs.mkdirSync(path.join(root, 'sub', 'nested'), { recursive: true });
  fs.writeFileSync(path.join(root, 'file.txt'), 'x');
});
afterEach(() => {
  fs.rmSync(root, { recursive: true, force: true });
});

describe('DirectoryBrowser', () => {
  it('lists only subdirectories, sorted, hiding files and dotfiles', () => {
    fs.mkdirSync(path.join(root, '.hidden'));
    fs.mkdirSync(path.join(root, 'aaa'));
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.listChildren()).toEqual(['aaa', 'sub']);
  });

  it('descends into a child and back up', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.into('sub')).toBe(true);
    expect(b.cwd()).toBe(path.join(root, 'sub'));
    expect(b.into('nested')).toBe(true);
    expect(b.cwd()).toBe(path.join(root, 'sub', 'nested'));
    expect(b.up()).toBe(true);
    expect(b.cwd()).toBe(path.join(root, 'sub'));
  });

  it('select() returns the current absolute path', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    b.into('sub');
    expect(b.select()).toBe(path.join(root, 'sub'));
  });

  it('cannot ascend above an allowed root', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.up()).toBe(false); // already at the root boundary
    expect(b.cwd()).toBe(root);
  });

  it('cannot descend outside an allowed root via traversal', () => {
    const b = new DirectoryBrowser({ allowedRoots: [path.join(root, 'sub')], startPath: path.join(root, 'sub') });
    // Attempt to escape up-and-out with a relative component.
    expect(b.into('..')).toBe(false);
    expect(b.cwd()).toBe(path.join(root, 'sub'));
  });

  it('into a nonexistent or non-directory target is a no-op', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.into('does-not-exist')).toBe(false);
    expect(b.into('file.txt')).toBe(false);
    expect(b.cwd()).toBe(root);
  });

  it('clamps a start path outside the roots back to the first root', () => {
    const b = new DirectoryBrowser({ allowedRoots: [path.join(root, 'sub')], startPath: os.tmpdir() });
    expect(b.cwd()).toBe(path.join(root, 'sub'));
  });
});
