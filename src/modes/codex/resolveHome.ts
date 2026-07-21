import * as os from 'node:os';
import * as path from 'node:path';

// Resolve the configured codexHome to an absolute path: default to <home>/.codex
// when unset/empty, and expand a leading `~`/`~/` (config stores it as '~/.codex').
export function resolveCodexHome(configured: string | undefined): string {
  if (!configured || configured.length === 0) return path.join(os.homedir(), '.codex');
  if (configured === '~') return os.homedir();
  if (configured.startsWith('~/')) return path.join(os.homedir(), configured.slice(2));
  return configured;
}
