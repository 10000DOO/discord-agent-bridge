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

describe('DirectoryBrowser render (A4D-style folder picker)', () => {
  function selectOf(rows: { components: { type: string; customId: string; options?: { label: string; value: string }[]; placeholder?: string }[] }[]) {
    return rows.flatMap((r) => r.components).find((c) => c.type === 'select' && c.customId === 'dir:into');
  }
  function buttonOf(rows: { components: { type: string; customId: string; disabled?: boolean }[] }[], id: string) {
    return rows.flatMap((r) => r.components).find((c) => c.type === 'button' && c.customId === id);
  }

  it('shows the CURRENT path + guidance, a subfolder select, and ⬆ up / ✅ start buttons', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const { embed, rows } = b.render();
    // The embed carries the how-to guidance and the current absolute path.
    expect(embed.description).toContain('프로젝트 폴더');
    expect(embed.description).toContain(root);
    // Subfolder select lists the child directory as a navigation option.
    const select = selectOf(rows);
    expect(select?.customId).toBe('dir:into');
    expect(select?.options?.map((o) => o.value)).toContain('sub');
    // Up button is DISABLED at a root boundary; the start button is present.
    expect(buttonOf(rows, 'dir:up')?.disabled).toBe(true);
    const start = buttonOf(rows, 'dir:here');
    expect(start).toBeDefined();
    if (start && 'label' in start) expect(start.label).toContain('시작');
  });

  it('after navigating INTO a subfolder, the render reflects the new path and enables ⬆ up', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.into('sub')).toBe(true);
    const { embed, rows } = b.render();
    expect(embed.description).toContain(path.join(root, 'sub'));
    // Now inside a subfolder, going up is allowed.
    expect(buttonOf(rows, 'dir:up')?.disabled).toBe(false);
    // 'nested' is offered as the next descent.
    expect(selectOf(rows)?.options?.map((o) => o.value)).toContain('nested');
  });

  it('navigating UP returns to the parent path in the render', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    b.into('sub');
    expect(b.up()).toBe(true);
    expect(b.render().embed.description).toContain(root);
  });

  it('an empty folder renders a disabled-style placeholder option, not a crash', () => {
    const empty = path.join(root, 'sub', 'nested');
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: empty });
    const select = selectOf(b.render().rows);
    // The single sentinel option (never a real folder) keeps the select non-empty.
    expect(select?.options).toHaveLength(1);
    expect(select?.options?.[0].value).toBe('__none__');
  });
});
