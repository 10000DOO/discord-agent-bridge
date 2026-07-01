import * as fs from 'node:fs';
import * as path from 'node:path';
import type { OutgoingFile } from './ports.js';

// Read-only file browse/download, realpath-confined to the session workspace
// (§4, §7.5, fixes A5). Every browsed/downloaded path is realpath-resolved and
// must stay inside the workspace root — a symlink pointing outside the root is
// caught, not just a literal `..`. Reuses the confinement approach from
// mcpFileTool/sessionOrchestrator (realpath the deepest existing ancestor).
//
// This is a "read" component: it lists entries and resolves a download path, but
// never mutates the filesystem. The actual Discord attachment is built by 7b from
// the OutgoingFile this returns. Pure FS logic — unit-testable with temp dirs.

export class WorkspaceEscapeError extends Error {
  constructor(public readonly requestedPath: string) {
    super(`Path escapes the workspace: ${requestedPath}`);
    this.name = 'WorkspaceEscapeError';
  }
}

export interface DirEntry {
  name: string;
  isDirectory: boolean;
}

export class FileDownload {
  private readonly root: string;

  constructor(workspaceRoot: string) {
    this.root = realpathOrResolve(workspaceRoot);
  }

  // List the entries of a directory inside the workspace. `relativeDir` is resolved
  // against the workspace root; anything escaping the root throws WorkspaceEscapeError.
  browse(relativeDir = '.'): DirEntry[] {
    const target = this.resolveConfined(relativeDir);
    const entries = fs.readdirSync(target, { withFileTypes: true });
    return entries
      .filter((e) => !e.name.startsWith('.'))
      .map((e) => ({ name: e.name, isDirectory: e.isDirectory() }))
      .sort((a, b) => {
        if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
  }

  // Resolve a download target inside the workspace, returning an OutgoingFile that
  // 7b turns into a discord.js attachment. Throws WorkspaceEscapeError when the path
  // escapes the workspace, or a plain Error when the target is missing / not a file.
  download(relativePath: string): OutgoingFile {
    const target = this.resolveConfined(relativePath);
    let stat: fs.Stats;
    try {
      stat = fs.statSync(target);
    } catch {
      throw new Error(`File not found: ${relativePath}`);
    }
    if (!stat.isFile()) {
      throw new Error(`Not a file: ${relativePath}`);
    }
    return { path: target, name: path.basename(target) };
  }

  // Resolve `requested` against the workspace root, realpath-confining it. Throws
  // WorkspaceEscapeError if the resolved path is outside the root.
  private resolveConfined(requested: string): string {
    const resolved = realpathOrResolve(path.resolve(this.root, requested));
    if (!isWithin(this.root, resolved)) {
      throw new WorkspaceEscapeError(requested);
    }
    return resolved;
  }
}

// Realpath a path, falling back to the realpath of its deepest existing ancestor
// joined with the non-existent tail — so confinement holds for paths that do not
// exist yet while still resolving symlinks in the part that does. (Same approach as
// core/sessionOrchestrator realpathOrResolve; duplicated locally to keep the
// discord layer free of a core import for a tiny helper.)
function realpathOrResolve(target: string): string {
  const abs = path.resolve(target);
  let existing = abs;
  const tail: string[] = [];
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break;
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

function isWithin(root: string, child: string): boolean {
  const rel = path.relative(root, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}
