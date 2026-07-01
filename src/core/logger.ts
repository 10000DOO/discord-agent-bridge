import type { Logger } from './contracts.js';

// TODO(Phase 1): redacting logger — never log raw event payloads / secrets at info level (§7.3, A7).
export function createLogger(_name: string): Logger {
  throw new Error('not implemented');
}
