#!/usr/bin/env node
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';
import { startBot } from './app.js';
import { runSetup } from './setup/wizard.js';
import { ConfigStore } from './core/config.js';

// Thin entrypoint (§4): `--version` prints the package version, `--setup` runs the
// first-run wizard only (explicit re-configure), and the default/no-flag path is a
// one-command first-run — it runs the wizard automatically when nothing is
// configured yet, then boots the bot. All real work lives in app.ts /
// setup/wizard.ts; this file only parses argv, decides, and dispatches.

// Read the package version from package.json (two levels up from dist/cli.js, and
// from src/cli.ts in dev). Kept as a function so a test can call it directly.
export function readVersion(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  // dist/cli.js → ../package.json ; src/cli.ts → ../package.json
  const pkgPath = path.join(here, '..', 'package.json');
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8')) as { version?: string };
  return pkg.version ?? '0.0.0';
}

// Is this a first run that needs the wizard? True when there is no config.json yet,
// OR a config exists but its Discord token is empty/whitespace — the same two
// EXPECTED first-run conditions startBot() treats as "not set up" (the friendly
// no-token check added by the friendly-startup fix). A present-but-INVALID config
// is deliberately NOT treated as needs-setup: load() throws, and we let that
// propagate to startBot() so a real corruption bug surfaces (it stays the friendly
// fallback's job to report a still-can't-start config).
function needsSetup(store: ConfigStore): boolean {
  if (!store.exists()) return true;
  return store.load().discord.token.trim().length === 0;
}

export async function run(argv: string[]): Promise<void> {
  if (argv.includes('--version')) {
    console.log(readVersion());
    return;
  }
  // Explicit re-configure: run the wizard ONLY, never auto-start afterwards.
  if (argv.includes('--setup')) {
    await runSetup();
    return;
  }
  // No flags: one-command first-run. When nothing is configured yet, run the wizard
  // and then start the bot in the same process; when already configured, start
  // directly. If setup was cancelled (or still wrote nothing usable), startBot's
  // own guardrails print the friendly "run --setup" fallback and exit non-zero.
  if (needsSetup(new ConfigStore())) {
    await runSetup();
    console.log('설정 완료. 봇을 시작합니다…');
  }
  await startBot();
}

// Only auto-run when invoked as the CLI, not when imported by a test. Compare
// REALPATHS: the npm-installed bin is a symlink, so process.argv[1] is the symlink
// path while import.meta.url resolves to the real dist/cli.js. fs.realpathSync
// resolves the symlink to the real path, which equals fileURLToPath(import.meta.url).
const isMain = (() => {
  const entry = process.argv[1];
  if (typeof entry !== 'string') return false;
  try {
    return fs.realpathSync(entry) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
})();

if (isMain) {
  run(process.argv.slice(2)).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
