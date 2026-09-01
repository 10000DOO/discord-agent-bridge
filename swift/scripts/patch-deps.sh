#!/bin/bash
# Applies swift/patches/*.patch to the resolved SwiftPM checkouts. Idempotent, so it is safe to
# run before every build. It has to run after `swift package resolve` and before `swift build`:
# resolve re-clones dependencies and drops any local edit.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$here/.build/checkouts/DiscordBM"
patch_file="$here/patches/discordbm-zstd-incomplete-frame.patch"

[ -d "$target" ] || { echo "patch-deps: $target not resolved yet — run 'swift package resolve' first" >&2; exit 1; }
chmod -R u+w "$target/Sources/DiscordGateway"
if patch -d "$target" -p1 -N -s -r /dev/null --dry-run < "$patch_file" >/dev/null 2>&1; then
    patch -d "$target" -p1 -N -s -r /dev/null < "$patch_file"
    echo "patch-deps: applied discordbm-zstd-incomplete-frame"
else
    echo "patch-deps: discordbm-zstd-incomplete-frame already applied"
fi
