# Discord Agent Bridge (Swift)

SwiftPM package for the Swift port of discord-agent-bridge.

- **Design / progress:** [`../SWIFT_PORT_PLAN.md`](../SWIFT_PORT_PLAN.md) (§0 snapshot)
- **Claude sidecar protocol:** [`../CLAUDE_SIDECAR_PROTOCOL.md`](../CLAUDE_SIDECAR_PROTOCOL.md)
- **Discord library:** [DiscordBM](https://github.com/DiscordBM/DiscordBM) (executable `dab` only)
- **Library target:** Foundation-only (Claude sidecar + Codex app-server + Grok ACP clients)

### Port status (short)

| Piece | Status |
|-------|--------|
| Gateway login + `!dab` → Claude via Node sidecar | **MVP working** |
| Claude sidecar protocol client | done (`Sidecar/`) |
| Codex `app-server` client | scaffold only (`Codex/`) |
| Grok ACP client | scaffold only (`Grok/`) |
| Full orchestrator / slash / multi-mode | not yet (see plan W10–W11) |

## Requirements

- macOS 13+
- Swift 6.1+ (Xcode / command-line tools)
- Node.js (optional; only for `sidecar-smoke` / live Claude sidecar)

## Build & test

```bash
cd swift
swift build
swift test
```

## Run (Discord + `!dab` Claude)

Token from env (preferred) or first CLI argument. Run from **repo root** so the sidecar spawn can find `src/sidecar` / `node_modules`.

```bash
export DISCORD_BOT_TOKEN=your_bot_token   # or DISCORD_TOKEN
# optional:
export DAB_CWD="$HOME/Projects/my-repo"  # Claude working directory (default: home)
export DAB_PERM_MODE=bypassPermissions   # default; skips tool permission UI — use only in trusted envs
# export DAB_PERM_MODE=default           # safer; tools may hang without permission UI
export DAB_TURN_TIMEOUT_SEC=120

swift run --package-path swift dab
```

On success:

```text
ready: username=<bot> id=<snowflake> app=<application id>
```

In any guild channel the bot can see, send:

```text
!dab what files are in the current directory?
```

Flow: lazy-spawn Node Claude sidecar → `session.start` once per channel → `session.send` → collect text events until `result` (or timeout) → bot replies once (≤2000 chars).

Missing token → usage on stderr, exit 1.

Enable **Message Content Intent** in the [Discord Developer Portal](https://discord.com/developers/applications) for the bot application.

### Env summary

| Env | Default | Notes |
|-----|---------|--------|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | required for gateway |
| `DAB_CWD` | home dir | Claude session cwd |
| `DAB_PERM_MODE` | `bypassPermissions` | **dangerous** default for smoke; prefer `default` when permission UI exists |
| `DAB_TURN_TIMEOUT_SEC` | `120` | wait for result/text |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | override sidecar spawn |

## Sidecar smoke (W9)

Spawns the real Node Claude sidecar, waits for `sidecar.ready`, calls `session.start`. SDK/login failures are acceptable; the goal is protocol handshake.

```bash
# from repo root (so spawn can find src/sidecar or dist)
cd /path/to/discord-agent-bridge

# default: node + tsx src/sidecar/claude/cli.ts (or dist if built)
swift run --package-path swift dab sidecar-smoke

# or explicit override
DAB_CLAUDE_SIDECAR_CMD="node $(pwd)/node_modules/tsx/dist/cli.mjs $(pwd)/src/sidecar/claude/cli.ts" \
  swift run --package-path swift dab sidecar-smoke
```

Spawn resolution (mirrors TS):

1. `DAB_CLAUDE_SIDECAR_CMD` (space-split)
2. `node dist/sidecar/claude/cli.js` if present
3. `node node_modules/tsx/dist/cli.mjs src/sidecar/claude/cli.ts`

## Codex smoke (W10 slice1)

Spawns real `codex app-server` if the CLI is on PATH, sends `initialize`. Missing CLI → **exit 0** with a clear message (CI-friendly).

```bash
swift run --package-path swift dab codex-smoke

# optional override
CODEX_CMD=/path/to/codex swift run --package-path swift dab codex-smoke
```

Library: `CodexAppServerClient` (JSON-RPC NDJSON over stdio; inject `SidecarTransport` for tests). Not wired to Discord/`AgentMode` yet.

## Deploy (launchd)

Runs `dab` as a per-user macOS LaunchAgent (starts at login, kept alive).

**Deploy unit = the whole repo checkout.** The launcher `cd`s into the repo root so
the Claude sidecar spawn can find `src/sidecar` / `dist` + `node_modules`. Keep the
checkout in place (and Node deps installed) — the LaunchAgent points at it by absolute path.

```bash
# build (release), install to ~/.dab, register + start
bash swift/scripts/install.sh

# validate only — generate + plutil -lint the plist and run.sh, no build, no load
bash swift/scripts/install.sh --dry-run

# stop + unregister + remove plist/bin/run.sh (keeps ~/.dab/env and ~/.dab/logs)
bash swift/scripts/uninstall.sh
```

What install lays down:

| Path | Role |
|------|------|
| `~/.dab/bin/dab` | copied release binary |
| `~/.dab/env` (0600) | secrets + `DAB_*` (from `swift/deploy/env.example` on first install) |
| `~/.dab/run.sh` (0755) | launcher: sets PATH (finds node/codex/grok), sources env, `cd` repo root, execs dab |
| `~/Library/LaunchAgents/com.discord-agent-bridge.plist` (0644) | LaunchAgent; carries **HOME only** — no tokens |
| `~/.dab/logs/agent.{out,err}.log` | stdout / stderr |

After editing `~/.dab/env`, reload: `launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist && launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist`.

Two launchd traps the launcher solves: launchd hands children a minimal PATH (Homebrew /
user-local CLIs unfindable) and defaults cwd to `/` (breaks repo-relative sidecar paths).
If `node` / `codex` / `grok` live outside the baked PATH (e.g. nvm, custom npm prefix), add
that bin dir to `~/.dab/run.sh`'s PATH export.

## Layout

| Path | Role |
|------|------|
| `Sources/DiscordAgentBridge/` | Library: token helpers, sidecar protocol + client |
| `Sources/DiscordAgentBridge/Sidecar/` | Envelope, AgentEvent, spawn, transport, ClaudeSidecarClient |
| `Sources/DiscordAgentBridge/Codex/` | Codex app-server JSON-RPC client scaffold (W10) |
| `Sources/dab/` | Executable: Discord `!dab` path + `sidecar-smoke` / `codex-smoke` |
| `Tests/DiscordAgentBridgeTests/` | Protocol roundtrip + fake-transport client tests |

## Note

Live Discord token is not required for `swift build` / `swift test`. Gateway connect and real Claude SDK need credentials and are manual.
