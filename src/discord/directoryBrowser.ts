import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import type { ComponentRow, EmbedSpec, SelectSpec } from './ports.js';
import { t } from './i18n.js';

// Filesystem folder navigation used by the channel wizard (§9): list dirs, go up,
// go into, select the current path. Browsing is CONFINED to configured allowed
// roots (else the user's home): navigation can never escape a root (fixes the A5
// class of path-escape, applied to the browse UI). Pure FS + string logic — no
// discord.js — so it is unit-testable against temp dirs; the render() output is a
// plain component spec that 7b maps onto discord.js.
//
// custom_id scheme (parsed by 7b's interactionRouter):
//   dir:into  (string-select; value = child folder name)
//   dir:up    (button)
//   dir:here  (button — select the current folder)

// Discord select limits (A4D MAX_SELECT_OPTIONS / label length).
const MAX_SELECT_OPTIONS = 25;
const MAX_LABEL_LENGTH = 95;

export interface DirectoryBrowserOptions {
  // Absolute directories the user may browse within. Any navigation target must be
  // inside at least one root. Defaults to [home] when omitted/empty.
  allowedRoots?: string[];
  // Where to start; must resolve inside an allowed root or it is clamped to the
  // first root. Defaults to the first allowed root.
  startPath?: string;
}

export class DirectoryBrowser {
  private readonly roots: string[];
  private current: string;

  constructor(options: DirectoryBrowserOptions = {}) {
    const roots = (options.allowedRoots && options.allowedRoots.length > 0
      ? options.allowedRoots
      : [os.homedir()]
    ).map((r) => path.resolve(r));
    this.roots = roots;
    const start = options.startPath ? path.resolve(options.startPath) : roots[0];
    this.current = this.confine(start) ? start : roots[0];
  }

  // The folder currently in view.
  cwd(): string {
    return this.current;
  }

  // Names of immediate subdirectories of the current folder (sorted, capped). Unreadable
  // dirs and non-directory entries are skipped; a permission error yields an empty list.
  listChildren(): string[] {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(this.current, { withFileTypes: true });
    } catch {
      return [];
    }
    return entries
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => e.name)
      .sort((a, b) => a.localeCompare(b))
      .slice(0, MAX_SELECT_OPTIONS);
  }

  // Descend into a child folder. No-ops (returns false) if the child does not exist,
  // is not a directory, or would escape an allowed root.
  into(childName: string): boolean {
    const target = path.resolve(this.current, childName);
    if (!this.confine(target)) return false;
    if (!isDirectory(target)) return false;
    this.current = target;
    return true;
  }

  // Go up one level. No-ops (returns false) at a root boundary, so the user cannot
  // ascend past an allowed root.
  up(): boolean {
    const parent = path.dirname(this.current);
    if (parent === this.current) return false;
    if (!this.confine(parent)) return false;
    this.current = parent;
    return true;
  }

  // Select the current folder as the session cwd. Returns its absolute path.
  select(): string {
    return this.current;
  }

  // True when `target` (already resolved) is the same as, or nested under, at least
  // one allowed root. Uses path.relative so /ws is not fooled by /ws-evil.
  private confine(target: string): boolean {
    const resolved = path.resolve(target);
    return this.roots.some((root) => isWithin(root, resolved));
  }

  // Build the interactive spec (embed + component rows) for the current view. Pure
  // data; 7b turns it into a discord.js reply/update.
  render(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const children = this.listChildren();
    const embed: EmbedSpec = {
      title: t('wizard.step.folder'),
      description: '`' + this.current + '`',
    };
    const select: SelectSpec = {
      type: 'select',
      customId: 'dir:into',
      placeholder: children.length > 0 ? t('dir.select') : t('dir.empty'),
      options:
        children.length > 0
          ? children.map((name) => ({ label: clip(name, MAX_LABEL_LENGTH), value: name }))
          : [{ label: t('dir.empty'), value: '__none__' }],
    };
    const rows: ComponentRow[] = [
      { components: [select] },
      {
        components: [
          { type: 'button', customId: 'dir:up', label: t('dir.up'), style: 'secondary', disabled: !this.canGoUp() },
          { type: 'button', customId: 'dir:here', label: t('dir.here'), style: 'success' },
        ],
      },
    ];
    return { embed, rows };
  }

  private canGoUp(): boolean {
    const parent = path.dirname(this.current);
    return parent !== this.current && this.confine(parent);
  }
}

function isDirectory(p: string): boolean {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}

function isWithin(root: string, child: string): boolean {
  const rel = path.relative(root, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function clip(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1) + '…';
}
