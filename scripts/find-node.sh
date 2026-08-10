#!/bin/bash
# Locate a usable Node.js (>= 20) no matter how the user installed it.
#
# Three callers share this one rule set, which is the whole point of the file:
#   - the Homebrew formula, at install time (needs node to run `npm install`)
#   - the `dab` wrapper, at every launch (builds DAB_CLAUDE_SIDECAR_CMD)
#   - homebrew-self-update.sh, before handing PATH to `brew upgrade`
# and swift/scripts/install.sh's generated run.sh on the source-install path.
#
# Why resolve at run time instead of baking the path in at install time: version managers
# put node under a per-version directory (~/.nvm/versions/node/v24.12.0/bin/node). Baking
# that string means the next `nvm install` silently breaks both the Claude sidecar and the
# updater's own node lookup. Re-resolving costs one `node --version` per launch.
#
# Usage:
#   scripts/find-node.sh              # prints the path, exit 1 when nothing qualifies
#   . scripts/find-node.sh; dab_find_node
#
# Inputs (all optional):
#   DAB_NODE               absolute path to force a specific node
#   DAB_NODE_FALLBACK_DIR  directory recorded at install time, tried last
#   DAB_NODE_MIN_MAJOR     minimum major version (default 20)
#
# bash-only on purpose: this runs under launchd's minimal environment and inside
# Homebrew's build sandbox, neither of which gives us zsh or GNU coreutils.

dab_node_min_major() {
  local min="${DAB_NODE_MIN_MAJOR:-20}"
  case "$min" in
    ''|*[!0-9]*) echo 20 ;;
    *) echo "$min" ;;
  esac
}

# Executable, runs, and reports a high enough major version. A candidate that fails any of
# these is skipped rather than fatal — a half-removed version manager entry must not stop
# the search.
dab_node_ok() {
  local candidate="$1"
  [ -n "$candidate" ] || return 1
  [ -x "$candidate" ] || return 1
  local raw major
  raw="$("$candidate" --version 2>/dev/null)" || return 1
  major="${raw#v}"
  major="${major%%.*}"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -ge "$(dab_node_min_major)" ]
}

# Highest-versioned first over a glob of per-version node binaries.
#
# Deliberately no `sort`/`sort -V`: this may run with a PATH that has no coreutils at all,
# and an unavailable `sort` would turn an ordering preference into a hard failure. Bash
# expands the glob in ascending lexicographic order, so walking the array backwards gives
# descending order. That ordering is not true semver — "v9" sorts above "v10" — but it only
# decides *which* qualifying node wins, never *whether* one qualifies: dab_node_ok gates
# every candidate on the major version anyway.
dab_node_newest_of() {
  local pattern="$1"
  local -a matches=()
  local candidate i
  # shellcheck disable=SC2206
  matches=( $(compgen -G "$pattern" 2>/dev/null) )
  for (( i=${#matches[@]}-1; i>=0; i-- )); do
    candidate="${matches[$i]}"
    if dab_node_ok "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

dab_find_node() {
  local candidate

  # 1. Explicit override always wins — the escape hatch when detection guesses wrong.
  if dab_node_ok "${DAB_NODE:-}"; then
    printf '%s\n' "$DAB_NODE"
    return 0
  fi

  # 2. Whatever the caller's PATH already selected. Respects the user's own choice when
  #    there is one; under launchd this simply finds nothing and we fall through.
  candidate="$(command -v node 2>/dev/null || true)"
  if dab_node_ok "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # 3. nvm — ask nvm itself first (respects the user's `default` alias), then scan.
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$nvm_dir/nvm.sh" ]; then
    # shellcheck disable=SC1090
    candidate="$(. "$nvm_dir/nvm.sh" >/dev/null 2>&1 && { nvm which default 2>/dev/null || nvm which node 2>/dev/null; })"
    if dab_node_ok "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  if candidate="$(dab_node_newest_of "$nvm_dir/versions/node/*/bin/node")"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # 4. volta
  if dab_node_ok "$HOME/.volta/bin/node"; then
    printf '%s\n' "$HOME/.volta/bin/node"
    return 0
  fi

  # 5. fnm — two layouts depending on install flavour.
  if candidate="$(dab_node_newest_of "$HOME/.fnm/node-versions/*/installation/bin/node")"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if candidate="$(dab_node_newest_of "$HOME/Library/Application Support/fnm/node-versions/*/installation/bin/node")"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # 6. asdf (shim resolves the active version itself)
  if dab_node_ok "$HOME/.asdf/shims/node"; then
    printf '%s\n' "$HOME/.asdf/shims/node"
    return 0
  fi

  # 7. mise
  if candidate="$(dab_node_newest_of "$HOME/.local/share/mise/installs/node/*/bin/node")"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # 8. n
  if candidate="$(dab_node_newest_of "/usr/local/n/versions/node/*/bin/node")"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # 9. Fixed system locations.
  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if dab_node_ok "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  # 10. The directory recorded when this install was built. Last because it is the one
  #     value guaranteed to go stale.
  if [ -n "${DAB_NODE_FALLBACK_DIR:-}" ] && dab_node_ok "$DAB_NODE_FALLBACK_DIR/node"; then
    printf '%s\n' "$DAB_NODE_FALLBACK_DIR/node"
    return 0
  fi

  return 1
}

# Only act as a CLI when executed directly, so callers can source this for the function.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dab_find_node
fi
