#!/usr/bin/env bash
# One-command verification for discord-agent-bridge (Swift).
#
# The product is Swift; the TypeScript code is reference-only and is NOT tested here.
# Gate (must pass, aborts on failure): Swift build, Swift tests.
# Backend smokes are best-effort: each spawns a real CLI and exits 0 when it is absent,
# so they never fail the gate — informational only.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> [1/2] Swift build"
swift build --package-path swift

echo "==> [2/2] Swift tests"
swift test --package-path swift

echo "==> Swift backend smokes (best-effort; missing/unauth CLI is OK)"
for s in sidecar-smoke codex-smoke grok-smoke; do
  echo "--- dab $s ---"
  swift run --package-path swift dab "$s" || echo "($s exited non-zero — informational, not a gate failure)"
done

echo "==> ALL GREEN — Swift gate passed"
