#!/usr/bin/env node
import { boot } from './app.js';
import { runSetupWizard } from './setup/wizard.js';

// TODO(Phase 1): entrypoint — `--setup` | run | `--version` (§4).
async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.includes('--version')) {
    // TODO(Phase 1): print version from package.json.
    throw new Error('not implemented');
  }

  if (args.includes('--setup')) {
    await runSetupWizard();
    return;
  }

  await boot();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
