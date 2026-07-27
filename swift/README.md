# Discord Agent Bridge (Swift)

SwiftPM package for the Swift port of discord-agent-bridge.

- **Design / progress:** [`../SWIFT_PORT_PLAN.md`](../SWIFT_PORT_PLAN.md) (§0 snapshot)
- **Parity gap backlog:** [`../SWIFT_TS_PARITY_GAPS.md`](../SWIFT_TS_PARITY_GAPS.md) (P0–P2 closed; OK-DIFF / DEFER only)
- **Claude sidecar protocol:** [`../CLAUDE_SIDECAR_PROTOCOL.md`](../CLAUDE_SIDECAR_PROTOCOL.md)
- **Discord library:** [DiscordBM](https://github.com/DiscordBM/DiscordBM) (executable `dab` only)
- **Library target:** Foundation-only (Claude sidecar + Codex app-server + Grok ACP clients)

### Port status (short)

| Piece | Status |
|-------|--------|
| Gateway + slash + `!claude`/`!codex`/`!grok`/`!custom` | **working** (W11–W16) |
| Claude sidecar / Codex app-server / Grok ACP | **done** — Discord-wired (`!codex`/`!grok`, session bridges) |
| Table/mermaid → PNG (S3) | **done** — headless Chrome CLI (not puppeteer-in-Swift) |
| Mainline port | **complete** (~99% product parity; P0–P2 gap backlog closed) |
| Residual | **W13-b product-deferred** (keep bypass default) · OK-DIFF only |

## Requirements

- macOS 13+
- Swift 6.1+ (Xcode / command-line tools)
- Node.js (optional; only for `sidecar-smoke` / live Claude sidecar)

## Build & test

```bash
# Prefer isolated scratch (avoids SourceKit index lock hang on swift/.build)
swift test --package-path swift --scratch-path /tmp/dab-ci
swift build --package-path swift --scratch-path /tmp/dab-ci
```

## Run (Discord + agents)

Token from env (preferred) or first CLI argument. Run from **repo root** so the Claude sidecar spawn can find `src/sidecar` / `node_modules`.

```bash
export DISCORD_BOT_TOKEN=your_bot_token   # or DISCORD_TOKEN
# optional:
export DAB_CWD="$HOME/Projects/my-repo"  # session working directory (default: home)
export DAB_PERM_MODE=bypassPermissions   # default; skips tool permission UI — use only in trusted envs
# export DAB_PERM_MODE=default           # safer; tools may hang without permission UI
export DAB_TURN_TIMEOUT_SEC=120

swift run --package-path swift dab
```

On success:

```text
ready: username=<bot> id=<snowflake> app=<application id>
```

In Discord (bound session channel, or with prefix):

```text
!claude what files are in the current directory?
!codex summarize the last commit
!grok explain this error
```

Slash path: **`/setup` → `/config` → `/agent start`**, then normal messages in the session channel. Prefix paths spawn/bind per channel without the full wizard.

Flow (Claude): lazy-spawn Node sidecar → `session.start` once per channel → `session.send` → stream/result → bot replies (chunked / embeds / optional PNG). Codex/Grok use native stdio clients the same way.

Missing token → usage on stderr, exit 1.

Enable **Message Content Intent** in the [Discord Developer Portal](https://discord.com/developers/applications) for the bot application.

### CLI / service equivalents (TS npm ↔ Swift)

Swift does **not** ship a full npm-style CLI (`discord-agent-bridge --setup` / `service install`). OS install scripts + Discord `/setup` + env cover the same jobs:

| Concern | Legacy TS (npm) | Swift |
|---------|-----------------|--------|
| Interactive first-time setup | `discord-agent-bridge --setup` | Discord **`/setup`** (admin) + edit `~/.dab/env` |
| Install auto-start service | `discord-agent-bridge service install` | `bash swift/scripts/install.sh` (macOS) · `install-linux.sh` · `install-windows.ps1` |
| Uninstall service | `discord-agent-bridge service uninstall` | `uninstall.sh` / `uninstall-linux.sh` / `install-windows.ps1 -Uninstall` |
| Status / restart | `service status` / `service restart` | `launchctl` / `systemctl --user` / `schtasks` (see Deploy below) |
| One-shot run | `discord-agent-bridge` / `npm run dev` | `swift run --package-path swift dab` |
| Token / secrets | wizard / service env | `~/.dab/env` → `DISCORD_BOT_TOKEN` |
| Config root | `DAB_HOME` or `~/.discord-agent-bridge` | **same** |

Root README migration table: [Migrating from npm TypeScript → Swift `dab`](../README.md#migrating-from-npm-typescript--swift-dab).

### Env summary

| Env | Default | Notes |
|-----|---------|--------|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | required for gateway |
| `DAB_CWD` | home dir | Claude session cwd |
| `DAB_PERM_MODE` | `bypassPermissions` | **dangerous** default for smoke; prefer `default` when permission UI exists |
| `DAB_TURN_TIMEOUT_SEC` | `120` | wait for result/text |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | override sidecar spawn |
| `DAB_RENDER` | (config) | `0` force off table/mermaid PNG; `1` prefer on when Chrome present |
| `DAB_MERMAID_JS` | auto | path to `mermaid.min.js` (else repo `node_modules/…` or `~/.dab/render/`) |
| `DAB_CHROMIUM_CACHE` | `~/.dab/chromium` | provisioned Chrome for Testing cache |
| `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` | system scan | override Chrome binary |

### Image render (S3 — done)

GFM tables and fenced `mermaid` blocks in answers (and `/doc` body) become PNG attachments when:

1. `config.render.enabled` is true (default; toggle in `/config` → 🖼 render panel), and
2. a browser is available: system Chrome/Edge/Chromium **or** provisioned under `DAB_CHROMIUM_CACHE` (Install Chromium downloads via `npx @puppeteer/browsers` when Node is present).

**Approach vs TS:** TypeScript uses **puppeteer** in-process. Swift uses **headless Chrome CLI** only (`--headless=new --screenshot=… file://…`) — no puppeteer runtime in the Swift binary. Mermaid.js is loaded from `DAB_MERMAID_JS`, else repo `node_modules/mermaid/dist/mermaid.min.js`, else `~/.dab/render/mermaid.min.js`.

Render failures fall back to raw markdown (never throw into the turn path). Caps: 15s timeout, 20k chars/block, 2000 table cells, max 2 concurrent.

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

Library: `CodexAppServerClient` (JSON-RPC NDJSON over stdio; inject `SidecarTransport` for tests). Discord path: `CodexSessionBridge` + `!codex` / bound session backend.

## Deploy (service install)

Runs `dab` as a **per-user** OS auto-start service. Pick the script for your platform
(mirrors TS `service/*` / `discord-agent-bridge service install`: launchd / systemd / schtasks).

**Deploy unit = the whole repo checkout.** The launcher `cd`s into the repo root so
the Claude sidecar spawn can find `src/sidecar` / `dist` + `node_modules`. Keep the
checkout in place (and Node deps installed) — the service points at it by absolute path.

### macOS (launchd)

```bash
bash swift/scripts/install.sh              # build + install + load
bash swift/scripts/install.sh --dry-run    # plutil -lint only
bash swift/scripts/uninstall.sh            # stop + unregister (keeps env/logs)
```

| Path | Role |
|------|------|
| `~/Library/LaunchAgents/com.discord-agent-bridge.plist` | LaunchAgent (`KeepAlive`) |
| `~/.dab/run.sh` | PATH + env + `cd` repo + exec dab |

Reload after editing env:  
`launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist && launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist`.

### Linux (systemd --user)

Requires `systemctl` (user session). `Restart=always`; best-effort `loginctl enable-linger`
so the unit can start before interactive login (same as TS `src/service/systemd.ts`).

```bash
bash swift/scripts/install-linux.sh              # build + enable --now
bash swift/scripts/install-linux.sh --dry-run    # generate + bash -n only
bash swift/scripts/uninstall-linux.sh
systemctl --user status discord-agent-bridge
systemctl --user restart discord-agent-bridge    # after editing ~/.dab/env
```

| Path | Role |
|------|------|
| `~/.config/systemd/user/discord-agent-bridge.service` | user unit |
| `~/.dab/run.sh` | PATH + `DAB_SUPERVISED=1` + env + `cd` repo + exec dab |

### Windows (Task Scheduler / onlogon)

No admin required. **No crash auto-restart** (onlogon only — same trade-off as TS
`src/service/schtasks.ts`). Needs Swift for Windows on PATH, or a prebuilt binary.

```powershell
powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1
powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1 -Uninstall
# optional: -BinaryPath C:\path\to\dab.exe
schtasks /Run /TN discord-agent-bridge   # start now
```

| Path | Role |
|------|------|
| Task `discord-agent-bridge` | onlogon trigger |
| `%USERPROFILE%\.dab\run.cmd` | load env + `cd` repo + run `dab.exe` |
| `%USERPROFILE%\.dab\bin\dab.exe` | release binary |

### Shared layout (`~/.dab` / `%USERPROFILE%\.dab`)

| Path | Role |
|------|------|
| `bin/dab` (`.exe` on Windows) | copied release binary |
| `env` (0600 on Unix) | secrets + `DAB_*` (from `swift/deploy/env.example` on first install) |
| `logs/agent.{out,err}.log` | stdout / stderr |

Secrets live **only** in `env` — never in the plist / unit / task definition.

Supervisor traps the launcher solves: minimal service PATH (Homebrew / linuxbrew /
user-local CLIs unfindable) and default cwd `/` or system dir (breaks repo-relative
sidecar paths). If `node` / `codex` / `grok` live outside the baked PATH (e.g. nvm),
add that bin dir to `run.sh` / `run.cmd` or export `PATH` in `env`.

## Layout

| Path | Role |
|------|------|
| `Sources/DiscordAgentBridge/` | Library: sessions, bridges, render, config, usage |
| `Sources/DiscordAgentBridge/Sidecar/` | Envelope, AgentEvent, spawn, transport, ClaudeSidecarClient |
| `Sources/DiscordAgentBridge/Codex/` | Codex app-server JSON-RPC client |
| `Sources/DiscordAgentBridge/Grok/` | Grok ACP client |
| `Sources/DiscordAgentBridge/Bridges/` | Claude / Codex / Grok session bridges (Discord turn path) |
| `Sources/DiscordAgentBridge/Session/` | Lifecycle, store, wizards, confinement, FileDownload, … |
| `Sources/dab/` | Executable: Discord gateway + slash + smokes |
| `Tests/DiscordAgentBridgeTests/` | Library unit tests (no live Discord token) |

## Note

Live Discord token is not required for `swift build` / `swift test`. Gateway connect and real Claude SDK need credentials and are manual.
