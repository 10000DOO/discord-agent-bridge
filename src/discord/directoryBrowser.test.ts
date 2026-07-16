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
  it('lists subdirectories (files excluded), hidden (dot) folders included but sorted last', () => {
    fs.mkdirSync(path.join(root, '.hidden'));
    fs.mkdirSync(path.join(root, 'aaa'));
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    // file.txt is still skipped; '.hidden' is now included, ordered after the normal folders.
    expect(b.listChildren()).toEqual(['aaa', 'sub', '.hidden']);
  });

  it('orders all non-dot folders before all dot folders, each group alphabetical', () => {
    for (const name of ['banana', '.zeta', 'apple', '.alpha', 'cherry']) {
      fs.mkdirSync(path.join(root, name));
    }
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const list = b.listChildren();
    // 'sub' pre-exists in the fixture; it sorts within the non-dot group.
    expect(list).toEqual(['apple', 'banana', 'cherry', 'sub', '.alpha', '.zeta']);
    // Structural guarantee: a non-dot prefix, then a dot suffix — no interleaving.
    const firstDot = list.findIndex((n) => n.startsWith('.'));
    expect(firstDot).toBeGreaterThan(0);
    expect(list.slice(0, firstDot).every((n) => !n.startsWith('.'))).toBe(true);
    expect(list.slice(firstDot).every((n) => n.startsWith('.'))).toBe(true);
  });

  it('protects real (non-dot) folders from the 25-option cap: dots never crowd them out', () => {
    // Many hidden folders + a few normal ones; even capped at 25, all normals survive.
    for (let i = 0; i < 30; i++) fs.mkdirSync(path.join(root, `.hidden${i}`));
    for (const name of ['proj-a', 'proj-b', 'proj-c']) fs.mkdirSync(path.join(root, name));
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const list = b.listChildren();
    expect(list).toHaveLength(25); // MAX_SELECT_OPTIONS
    // Every non-dot folder (fixture 'sub' + the three projects) is present, up front.
    for (const name of ['proj-a', 'proj-b', 'proj-c', 'sub']) expect(list).toContain(name);
    const firstDot = list.findIndex((n) => n.startsWith('.'));
    expect(list.slice(0, firstDot).every((n) => !n.startsWith('.'))).toBe(true);
  });

  it('can descend INTO a hidden (dot) folder (regression)', () => {
    fs.mkdirSync(path.join(root, '.hidden'));
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.into('.hidden')).toBe(true);
    expect(b.cwd()).toBe(path.join(root, '.hidden'));
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

  it('goTo() jumps to a valid absolute path (deep, in one hop)', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.goTo(path.join(root, 'sub', 'nested'))).toBe(true);
    expect(b.cwd()).toBe(path.join(root, 'sub', 'nested'));
  });

  it('goTo() rejects a nonexistent path, a file, and an out-of-bounds path (no view change)', () => {
    const b = new DirectoryBrowser({ allowedRoots: [path.join(root, 'sub')], startPath: path.join(root, 'sub') });
    expect(b.goTo(path.join(root, 'sub', 'does-not-exist'))).toBe(false);
    expect(b.goTo(path.join(root, 'sub', 'file.txt'))).toBe(false);
    expect(b.goTo(os.tmpdir())).toBe(false); // outside the allowed root
    expect(b.cwd()).toBe(path.join(root, 'sub'));
  });

  it('render() offers the 📝 manual-path button (dir:manual)', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const ids = b
      .render()
      .rows.flatMap((r) => r.components)
      .map((c) => (c as { customId?: string }).customId);
    expect(ids).toContain('dir:manual');
  });
});

describe('DirectoryBrowser unbounded (Fix 1: reach the filesystem root and other volumes)', () => {
  it('with NO allowedRoots, can navigate all the way UP to the filesystem root "/"', () => {
    const b = new DirectoryBrowser({ startPath: root });
    // Walk up repeatedly; each up() succeeds until we hit '/'.
    let guard = 0;
    while (b.up() && guard < 100) guard++;
    expect(b.cwd()).toBe(path.parse(root).root); // '/' on POSIX
    // At the filesystem root, up() is a no-op (dirname('/') === '/').
    expect(b.up()).toBe(false);
  });

  it('⬆ up is ENABLED at every path except "/" in the render', () => {
    // Deep-ish start: up is enabled here.
    const deep = new DirectoryBrowser({ startPath: path.join(root, 'sub', 'nested') });
    const upBtn = (rows: { components: { type: string; customId: string; disabled?: boolean }[] }[]) =>
      rows.flatMap((r) => r.components).find((c) => c.type === 'button' && c.customId === 'dir:up');
    expect(upBtn(deep.render().rows)?.disabled).toBe(false);

    // At the filesystem root, up is disabled.
    const atRoot = new DirectoryBrowser({ startPath: path.parse(root).root });
    expect(upBtn(atRoot.render().rows)?.disabled).toBe(true);
  });

  it('from "/" can enter a top-level directory (the path to other volumes, e.g. /Volumes)', () => {
    const fsRoot = path.parse(root).root; // '/'
    const b = new DirectoryBrowser({ startPath: fsRoot });
    expect(b.cwd()).toBe(fsRoot);
    // "/" lists its top-level entries (on macOS this includes 'Volumes', the mount root
    // for other drives). Entering any of them descends off the root — the exact behavior
    // the user needs to reach a project on another volume.
    const children = b.listChildren();
    expect(children.length).toBeGreaterThan(0);
    const first = children[0];
    expect(b.into(first)).toBe(true);
    expect(b.cwd()).toBe(path.join(fsRoot, first));
  });

  it('bounded mode still cannot ascend past an allowed root (confinement unchanged)', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    expect(b.up()).toBe(false);
    expect(b.cwd()).toBe(root);
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

  it('mirrors A4D folder-step buttons: Parent · Start · Resume · 📁 Create · Cancel in ONE row (≤5 rows)', () => {
    const b = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const { rows } = b.render();
    // Three rows (subfolder select + the five-button row + the manual-path row) — the
    // manual-path button needs its own row because the main button row is already at
    // Discord's 5-button limit. Still well under Discord's 5-row-per-message cap.
    expect(rows.length).toBeLessThanOrEqual(5);
    expect(rows).toHaveLength(3);
    // The subfolder select stays in its own row.
    expect(rows[0].components.every((c) => c.type === 'select')).toBe(true);
    // The button row carries exactly the five A4D-style buttons, in order.
    const buttonRow = rows[1].components;
    expect(buttonRow.every((c) => c.type === 'button')).toBe(true);
    expect(buttonRow.map((c) => c.customId)).toEqual(['dir:up', 'dir:here', 'dir:resume', 'dir:create', 'cancel']);
    // The manual-path button is on its own third row.
    expect(rows[2].components.map((c) => c.customId)).toEqual(['dir:manual']);
  });
});
