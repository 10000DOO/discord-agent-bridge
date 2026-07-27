// Claude sidecar process entry: NDJSON over stdio.
// Run: npm run sidecar:claude  (tsx src/sidecar/claude/cli.ts)
// Or:  node dist/sidecar/claude/cli.js

import { SidecarServer } from './server.js';

async function main(): Promise<void> {
  // Keep the process alive for stdin even if nothing is piped yet (interactive).
  if (process.stdin.isTTY) {
    process.stdin.resume();
  }

  const server = new SidecarServer({
    input: process.stdin,
    output: process.stdout,
  });

  const onSignal = () => {
    void server.stop().finally(() => process.exit(0));
  };
  process.once('SIGINT', onSignal);
  process.once('SIGTERM', onSignal);

  await server.run();
  process.exit(0);
}

main().catch((err) => {
  console.error('[sidecar] fatal', err);
  process.exit(1);
});
