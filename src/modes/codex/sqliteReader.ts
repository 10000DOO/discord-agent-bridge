// TODO(Phase 1): bundled JS/WASM SQLite (sql.js) reader over ~/.codex/state_*.sqlite.
// No external sqlite3 CLI. On open/read failure → caller degrades to index-only, fail-safe exclude (C3, §7.3).
export interface CodexThreadState {
  sessionId: string;
  cwd?: string;
  updatedAt?: string;
}

export class CodexSqliteReader {
  readThreadStates(_dbPath: string): Promise<CodexThreadState[]> {
    throw new Error('not implemented');
  }
}
