import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

// The package version, read from package.json. Extracted from cli.ts so both the CLI
// and the update layer (app.ts's AutoUpdater) can read it WITHOUT importing cli.ts —
// app.ts ← cli.ts would be a composition-root ↔ entrypoint cycle. cli.ts re-exports
// this so its existing `readVersion` callers (and cli.test) keep working unchanged.
//
// Resolves ../package.json relative to THIS module: dist/version.js → ../package.json
// in a real install, and src/version.ts → ../package.json in dev (same layout as the
// old cli.ts location). Kept as a function so a test can call it directly.
export function readVersion(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const pkgPath = path.join(here, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8')) as { version?: string };
  return pkg.version ?? '0.0.0';
}
