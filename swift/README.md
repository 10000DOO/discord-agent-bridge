# Discord Agent Bridge (Swift)

SwiftPM package for **discord-agent-bridge** — product binary `dab` and library `DiscordAgentBridge`.

- **User guide:** [`../README.md`](../README.md) · [`../README.ko.md`](../README.ko.md)
- **Claude sidecar protocol:** [`../docs/CLAUDE_SIDECAR_PROTOCOL.md`](../docs/CLAUDE_SIDECAR_PROTOCOL.md) (local `docs/`, gitignored)
- **Discord library:** [DiscordBM](https://github.com/DiscordBM/DiscordBM) (executable `dab` only)
- **Library target:** Foundation + sqlite3 (Claude sidecar client, Codex app-server, Grok ACP) — no DiscordBM

## Requirements

- macOS 13+ (primary; Linux/Windows via Swift toolchain also supported by install scripts)
- Swift 6.1+
- Node.js 20+ only if you use **Claude** (sidecar). Codex/Grok need their CLIs only.

## Build & test

```bash
# Prefer isolated scratch if SourceKit index lock hangs on swift/.build
swift test --package-path swift --scratch-path /tmp/dab-ci
swift build --package-path swift --scratch-path /tmp/dab-ci
```

From repo root: `bash verify.sh` (build + test + best-effort backend smokes).

## Run

Token from env (preferred) or first CLI argument. Run from **repo root** so the Claude sidecar can find `src/sidecar` / `node_modules`.

```bash
export DISCORD_BOT_TOKEN=your_bot_token   # or DISCORD_TOKEN
# optional:
export DAB_CWD="$HOME/Projects/my-repo"
export DAB_PERM_MODE=default              # safer; bypassPermissions skips tool permission UI
export DAB_TURN_TIMEOUT_SEC=120

swift run --package-path swift dab
```

On success: `ready: username=<bot> id=<snowflake> app=<application id>`

In Discord:

```text
!claude what files are in the current directory?
!codex summarize the last commit
!grok explain this error
```

Slash path: **`/setup` → `/config` → `/agent start`**, then normal messages in the session channel.

Enable **Message Content Intent** in the [Discord Developer Portal](https://discord.com/developers/applications).

### CLI

| Command | Role |
|---------|------|
| `dab` | Run the bot |
| `dab --version` | Print version |
| `dab --setup` | Print first-time setup guidance |
| `dab service status` | macOS launchd status |
| `dab service restart` | macOS launchd restart |
| `dab sidecar-smoke` | Claude sidecar handshake |
| `dab codex-smoke` | Codex app-server initialize (exit 0 if CLI missing) |
| `dab grok-smoke` | Grok ACP smoke (exit 0 if CLI missing) |

Install / uninstall: `swift/scripts/install.sh` · `install-linux.sh` · `install-windows.ps1` (and matching uninstall scripts).

### Env summary

| Env | Default | Notes |
|-----|---------|--------|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | required for gateway |
| `DAB_CWD` | home dir | default session cwd |
| `DAB_PERM_MODE` | `bypassPermissions` | prefer `default` with permission UI |
| `DAB_TURN_TIMEOUT_SEC` | `120` | wait for turn result |
| `DAB_DEV_GUILD_ID` | — | guild-scoped slash registration |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | override sidecar spawn |
| `DAB_RENDER` | (config) | `0` force off PNG; `1` prefer on when Chrome present |
| `DAB_MERMAID_JS` | auto | path to `mermaid.min.js` |
| `DAB_CHROMIUM_CACHE` | `~/.dab/chromium` | provisioned Chrome cache |
| `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` | system scan | override Chrome binary |

### Image render

GFM tables and fenced `mermaid` blocks become PNG when render is enabled and a browser is available (system Chrome/Edge/Chromium or provisioned under `DAB_CHROMIUM_CACHE`). Uses **headless Chrome CLI** (`--headless=new --screenshot=… file://…`). Failures fall back to markdown. Caps: 15s timeout, 20k chars/block, 2000 table cells, max 2 concurrent.

### Sidecar / backend smokes

```bash
# from repo root
swift run --package-path swift dab sidecar-smoke
swift run --package-path swift dab codex-smoke
swift run --package-path swift dab grok-smoke
```

Claude sidecar resolution:

1. `DAB_CLAUDE_SIDECAR_CMD` (space-split)
2. `node dist/sidecar/claude/cli.js` if present
3. `node node_modules/tsx/dist/cli.mjs src/sidecar/claude/cli.ts`

## Deploy (service install)

Per-user OS auto-start. **Deploy unit = whole repo checkout** so the Claude sidecar can find `src/sidecar` / `node_modules`. Keep Node deps installed if you use Claude.

### macOS (launchd)

```bash
bash swift/scripts/install.sh
bash swift/scripts/uninstall.sh
dab service status
dab service restart
```

| Path | Role |
|------|------|
| `~/Library/LaunchAgents/com.discord-agent-bridge.plist` | LaunchAgent (`KeepAlive`) |
| `~/.dab/run.sh` | PATH + env + `cd` repo + exec dab |

### Linux (systemd --user)

```bash
bash swift/scripts/install-linux.sh
systemctl --user status discord-agent-bridge
systemctl --user restart discord-agent-bridge
```

| Path | Role |
|------|------|
| `~/.config/systemd/user/discord-agent-bridge.service` | user unit |
| `~/.dab/run.sh` | launcher |

### Windows (Task Scheduler / onlogon)

```powershell
powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1
schtasks /Run /TN discord-agent-bridge
```

| Path | Role |
|------|------|
| Task `discord-agent-bridge` | onlogon (no crash auto-restart) |
| `%USERPROFILE%\.dab\run.cmd` | launcher |
| `%USERPROFILE%\.dab\bin\dab.exe` | release binary |

### Shared `~/.dab`

| Path | Role |
|------|------|
| `bin/dab` | release binary |
| `env` (0600) | secrets — never in plist/unit/task |
| `logs/agent.{out,err}.log` | stdout / stderr |

If `node` / `codex` / `grok` live outside the baked PATH (e.g. nvm), add that bin dir to `run.sh` / `run.cmd` or export `PATH` in `env`.

## Layout

| Path | Role |
|------|------|
| `Sources/DiscordAgentBridge/` | Library: config, sessions, bridges, render, usage, update |
| `Sources/DiscordAgentBridge/Sidecar/` | Envelope, AgentEvent, spawn, transport, ClaudeSidecarClient |
| `Sources/DiscordAgentBridge/Codex/` | Codex app-server JSON-RPC client |
| `Sources/DiscordAgentBridge/Grok/` | Grok ACP client |
| `Sources/DiscordAgentBridge/Bridges/` | Claude / Codex / Grok session bridges |
| `Sources/DiscordAgentBridge/Session/` | Lifecycle, store, wizards, confinement, slash specs, … |
| `Sources/DiscordAgentBridge/Render/` | Answer delivery, embeds, threads, Chromium PNG |
| `Sources/DiscordAgentBridge/Service/` | `dab service status\|restart` (launchd) |
| `Sources/dab/` | Executable: gateway, slash, component wiring, smokes |
| `Tests/DiscordAgentBridgeTests/` | Library unit tests (no live Discord token) |
| `scripts/` | install / uninstall (macOS, Linux, Windows) |
| `deploy/env.example` | Template for `~/.dab/env` |

## Note

Live Discord token is not required for `swift build` / `swift test`. Gateway connect and real agent CLIs need credentials and are manual.
