import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import type { ComponentRow, EmbedSpec, SelectSpec } from './ports.js';
import { t } from './i18n.js';

// Filesystem folder navigation used by the channel wizard (§9): list dirs, go up,
// go into, select the current path. By default (no allowedRoots) the admin driver can
// browse ANYWHERE up to the filesystem root '/', so the session cwd can be a project on
// any volume (e.g. /Volumes/<other-drive> on macOS): ⬆ up is enabled at every path
// except '/' itself. When allowedRoots IS supplied, navigation stays CONFINED within
// them (the original A5 path-escape guard, still used by callers that want a bounded
// picker). NOTE: this governs only CHOOSING the cwd; the per-session file-access
// confinement (attach/download realpath-confined to the chosen cwd) is a SEPARATE
// mechanism and is unaffected. Pure FS + string logic — no discord.js — so it is
// unit-testable against temp dirs; the render() output is a plain component spec that
// 7b maps onto discord.js.
//
// custom_id scheme (parsed by 7b's interactionRouter):
//   dir:into    (string-select; value = child folder name)
//   dir:up      (button — go to the parent folder)
//   dir:here    (button — select the current folder / Session Start)
//   dir:resume  (button — start the resume-session flow for the current folder)
//   dir:create  (button — open the create-folder modal in the current folder)
//   dir:manual  (button — open the manual absolute-path modal; jumps the browser there)
//   dir:panel   (button — open a native folder picker on the host; jumps the browser there)
//   cancel      (button — cancel the wizard)

// Discord select limits (A4D MAX_SELECT_OPTIONS / label length).
const MAX_SELECT_OPTIONS = 25;
const MAX_LABEL_LENGTH = 95;

export interface DirectoryBrowserOptions {
  // Absolute directories the user may browse within. Any navigation target must be
  // inside at least one root. When OMITTED/empty the browser is UNBOUNDED: the driver
  // can navigate up to the filesystem root '/' and into any volume (the admin picks the
  // session cwd anywhere). Supply roots only for a deliberately bounded picker.
  allowedRoots?: string[];
  // Where to start; must resolve inside an allowed root (bounded mode) or it is clamped
  // to the first root. Defaults to the first allowed root, or to home when unbounded.
  startPath?: string;
  // Offer the 🖥️ native host-side folder picker button (dir:panel). The router sets
  // this only when a picker implementation is wired (macOS host, §folderPanel.ts) —
  // the browser stays pure and platform-agnostic; it just renders one more button.
  nativePanel?: boolean;
}

export class DirectoryBrowser {
  // The confinement roots, or null when the browser is unbounded (browse anywhere up to
  // '/'). Kept separate from `current` so navigation checks pick the right rule.
  private readonly roots: string[] | null;
  private readonly nativePanel: boolean;
  private current: string;

  constructor(options: DirectoryBrowserOptions = {}) {
    const bounded = Boolean(options.allowedRoots && options.allowedRoots.length > 0);
    this.roots = bounded ? options.allowedRoots!.map((r) => path.resolve(r)) : null;
    this.nativePanel = options.nativePanel ?? false;
    const fallbackStart = this.roots ? this.roots[0] : os.homedir();
    const start = options.startPath ? path.resolve(options.startPath) : fallbackStart;
    this.current = this.confine(start) ? start : fallbackStart;
  }

  // The folder currently in view.
  cwd(): string {
    return this.current;
  }

  // Names of immediate subdirectories of the current folder (sorted, capped). Unreadable
  // dirs and non-directory entries are skipped; a permission error yields an empty list.
  // Hidden (dot) folders ARE listed, but sorted AFTER normal folders so they can't push
  // real project folders past the MAX_SELECT_OPTIONS cap; each group stays alphabetical.
  listChildren(): string[] {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(this.current, { withFileTypes: true });
    } catch {
      return [];
    }
    return entries
      .filter((e) => e.isDirectory())
      .map((e) => e.name)
      .sort((a, b) => {
        const ah = a.startsWith('.'), bh = b.startsWith('.');
        if (ah !== bh) return ah ? 1 : -1; // non-dot first, dot last
        return a.localeCompare(b);
      })
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

  // Go up one level. No-ops (returns false) at the filesystem root ('/', where
  // dirname(p) === p) and — in bounded mode — at an allowed-root boundary. In unbounded
  // mode the only stop is '/', so the driver can reach any volume above the start dir.
  up(): boolean {
    const parent = path.dirname(this.current);
    if (parent === this.current) return false;
    if (!this.confine(parent)) return false;
    this.current = parent;
    return true;
  }

  // Jump directly to an absolute path typed via the 📝 manual-path option. No-ops
  // (returns false) if the path does not exist, is not a directory, or would escape an
  // allowed root — the SAME confinement rule as into()/up(). On success the current view
  // moves there so ✅ Start selects it (the driver still confirms; no auto-start).
  goTo(target: string): boolean {
    const resolved = path.resolve(target);
    if (!this.confine(resolved)) return false;
    if (!isDirectory(resolved)) return false;
    this.current = resolved;
    return true;
  }

  // Select the current folder as the session cwd. Returns its absolute path.
  select(): string {
    return this.current;
  }

  // True when navigation to `target` is permitted. Unbounded mode (roots === null)
  // allows any absolute path (the whole filesystem, up to '/'). Bounded mode requires
  // `target` to be the same as, or nested under, at least one allowed root; path.relative
  // is used so /ws is not fooled by /ws-evil.
  private confine(target: string): boolean {
    const resolved = path.resolve(target);
    if (this.roots === null) return true;
    return this.roots.some((root) => isWithin(root, resolved));
  }

  // Build the interactive spec (embed + component rows) for the current view, A4D-style:
  // the embed shows the CURRENT path + how-to guidance, a select menu lists subfolders,
  // and a single action row mirrors A4D's folder-step buttons —
  // ⬆ 상위(Parent) · ✅ 시작(Session Start) · 세션 재개(Resume) · 📁 폴더 만들기(Create) ·
  // 취소(Cancel) — driving navigation, selection, resume, create, and cancel. Two rows
  // total (select + buttons), well within Discord's 5-row-per-message limit. Pure data;
  // 7b turns it into a discord.js reply/update.
  render(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const children = this.listChildren();
    const embed: EmbedSpec = {
      title: t('wizard.step.folder'),
      description: t('dir.guide') + '\n\n' + t('dir.current') + ': `' + this.current + '`',
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
          { type: 'button', customId: 'dir:resume', label: t('dir.resume'), style: 'primary' },
          { type: 'button', customId: 'dir:create', label: t('dir.create'), style: 'secondary' },
          { type: 'button', customId: 'cancel', label: t('wizard.cancel'), style: 'secondary' },
        ],
      },
      {
        // A separate row (the button row above is already at Discord's 5-button limit):
        // type an absolute path instead of clicking down to it (also handy on mobile /
        // for deep paths). Opens a modal; on submit the browser jumps there. When a
        // native host-side picker is wired (macOS), dir:panel joins it — pick the
        // folder in a real Finder open-panel instead of typing.
        components: [
          { type: 'button', customId: 'dir:manual', label: t('dir.manual'), style: 'secondary' },
          ...(this.nativePanel
            ? [{ type: 'button' as const, customId: 'dir:panel', label: t('dir.panel'), style: 'secondary' as const }]
            : []),
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
