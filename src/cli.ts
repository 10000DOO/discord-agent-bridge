#!/usr/bin/env node
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startBot } from './app.js';
import { runSetup } from './setup/wizard.js';

// Thin entrypoint (§4): `--version` prints the package version, `--setup` runs the
// first-run wizard (a stub until chunk 8b), and the default/no-flag path boots the
// bot. All real work lives in app.ts / setup/wizard.ts; this file only parses argv
// and dispatches, so it stays trivial to reason about.

// Read the package version from package.json (two levels up from dist/cli.js, and
// from src/cli.ts in dev). Kept as a function so a test can call it directly.
export function readVersion(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  // dist/cli.js → ../package.json ; src/cli.ts → ../package.json
  const pkgPath = path.join(here, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8')) as { version?: string };
  return pkg.version ?? '0.0.0';
}

export async function run(argv: string[]): Promise<void> {
  if (argv.includes('--version')) {
    console.log(readVersion());
    return;
  }
  if (argv.includes('--setup')) {
    await runSetup();
    return;
  }
  await startBot();
}

// Only auto-run when invoked as the CLI, not when imported by a test.
const isMain =
  typeof process.argv[1] === 'string' &&
  import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (isMain) {
  run(process.argv.slice(2)).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
