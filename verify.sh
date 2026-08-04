#!/usr/bin/env bash
# One-command verification for discord-agent-bridge (Swift + TypeScript sidecar).
#
# The product is Swift; the TypeScript sidecar (src/sidecar/claude) compiles to
# dist/ and is spawned by the Swift bot as a child process — it must be built here
# so a stale dist/ never ships silently (see swift/.../Sidecar/Spawn.swift).
# Gate (must pass, aborts on failure): TypeScript build, Swift build, Swift tests.
# Backend smokes are best-effort: each spawns a real CLI and exits 0 when it is absent,
# so they never fail the gate — informational only.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> [1/3] TypeScript build"
npm run build

echo "==> [2/3] Swift build"
swift build --package-path swift

echo "==> [3/3] Swift tests"
swift test --package-path swift

echo "==> Swift backend smokes (best-effort; missing/unauth CLI is OK)"
for s in sidecar-smoke codex-smoke grok-smoke; do
  echo "--- dab $s ---"
  swift run --package-path swift dab "$s" || echo "($s exited non-zero — informational, not a gate failure)"
done

echo "==> ALL GREEN — Swift + TypeScript gate passed"
