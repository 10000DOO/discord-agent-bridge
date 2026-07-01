// TODO(Phase 1): read-only file browser/download, realpath-confined to the workspace root (§4, §7.5, A5).
export class FileDownload {
  browse(_dir: string): unknown {
    throw new Error('not implemented');
  }

  download(_path: string): unknown {
    throw new Error('not implemented');
  }
}
