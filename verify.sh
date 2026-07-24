#!/usr/bin/env bash
# One-command full verification for discord-agent-bridge (TS + Swift).
#
# Gate (must pass, aborts on failure):
#   1. TS typecheck   2. TS tests (vitest)   3. Swift build   4. Swift tests
# Smokes are best-effort: each spawns a real backend CLI and exits 0 when the CLI
# is absent, so they never fail the gate — they are informational only.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> [1/4] TS typecheck"
npm run --silent typecheck

echo "==> [2/4] TS tests"
npm test

echo "==> [3/4] Swift build"
swift build --package-path swift

echo "==> [4/4] Swift tests"
swift test --package-path swift

echo "==> Swift smokes (best-effort; missing/unauth backend CLI is OK)"
for s in sidecar-smoke codex-smoke grok-smoke; do
  echo "--- dab $s ---"
  swift run --package-path swift dab "$s" || echo "($s exited non-zero — informational, not a gate failure)"
done

echo "==> ALL GREEN — gate passed"
