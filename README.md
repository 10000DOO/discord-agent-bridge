# discord-agent-bridge

🌐 [한국어](README.ko.md) | **English**

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, Grok, and custom backends — per channel. Role-based access, multi-server, extensible.

**A self-hosted Discord bot that puts Claude Code, Codex, or Grok into a Discord channel, running on your own machine.**

The product is a **Swift** binary (`dab`). Claude Code still uses a thin **Node sidecar** (official Agent SDK is Node-only). Codex and Grok talk to their CLIs natively over stdio — no Node required for those backends.

---

## Why this?

- 🏠 **Fully self-hosted.** The bot runs on your PC. Code, sessions, and CLI tokens stay on your machine.
- 📱 **Not tied to your desk.** Start a task from Discord on your phone — streaming output, tool logs, and permission prompts land in the channel.
- 🗂️ **One channel = one project = one session.** Each channel binds its own folder, backend, model, effort, and permission mode.
- 👥 **Team-friendly.** Anyone in the channel can watch the session. A 3-tier role system (admin / execute / read-only) controls who can run things.
- 🔀 **Claude ⇄ Codex ⇄ Grok (and custom) on the fly.** Switch backends with `/dab-mode` when a session is bound.
- ⚙️ **Same power as the terminal.** Project `.claude/` / `.codex/` configs are used as-is — subagents, skills, hooks, MCP, and plugin commands behave like the CLI.
- 💾 **Session presets.** Save backend/model/effort/perm combos per guild and restart sessions in two steps (folder → preset).
- 🖼 **Rich answers.** GFM tables and Mermaid diagrams can render as PNG; tool runs open work threads with diffs; usage panels show Claude / Codex / Grok limits.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **macOS 13+** (primary), or Linux / Windows with Swift | Product binary is SwiftPM `dab` |
| **Swift 6.1+** | Xcode or Command Line Tools (Windows: Swift toolchain) |
| **Node.js 20+** | **Claude only** — spawns the Claude sidecar; not needed for Codex/Grok |
| Backend CLIs, installed & logged in | **Claude Code** (`claude` login or `ANTHROPIC_API_KEY`); **Codex** CLI; **Grok** CLI as needed |
| **Discord bot token** | Step 1 below |

---

## Step 1 — Create a Discord bot

About 5 minutes.

1. Open the **[Discord Developer Portal](https://discord.com/developers/applications)** → **New Application** → name it (e.g. `my-agent-bot`) → **Create**.
2. **Bot** tab → **Reset Token** → copy the token and store it safely.
   - ⚠️ The token is a password. If it leaks, **Reset Token** immediately.
3. Same **Bot** tab, under **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **required**
   - ✅ **SERVER MEMBERS INTENT** — recommended (role checks)
   - Save Changes.
4. **OAuth2** → copy **Client ID (Application ID)**.
5. **OAuth2 → URL Generator**:
   - **Scopes**: `bot`, `applications.commands`
   - **Bot Permissions**: `Manage Channels`, `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Create Public Threads`, `Send Messages in Threads`, `Manage Threads`, `Add Reactions`
   - Open the generated URL and invite the bot to your server.

---

## Step 2 — Install & run

### macOS (recommended — Homebrew)

```bash
brew tap 10000DOO/discord-agent-bridge
brew install 10000DOO/discord-agent-bridge/dab
```

Builds `dab` from source and npm-installs the Claude sidecar alongside it — no separate `npm install` step. Needs Node.js 20+ and Swift 6.1+ already on `PATH` (see Prerequisites above); the formula only checks for them, it won't install or upgrade either.

Secrets (`DISCORD_BOT_TOKEN` etc.) live in `~/.dab/env` (0600) — same file the manual install below uses:

```bash
mkdir -p ~/.dab && touch ~/.dab/env && chmod 600 ~/.dab/env
$EDITOR ~/.dab/env
# DISCORD_BOT_TOKEN=...
```

Run once in the foreground:

```bash
dab
```

Or run as a background service that auto-restarts on crash/reboot (launchd, via `brew services`):

```bash
brew services start dab      # start
brew services list           # check status
brew services restart dab    # after editing ~/.dab/env
brew services stop dab       # stop
```

Logs: `$(brew --prefix)/var/log/dab.log` / `dab.error.log`.

Update:

```bash
brew update
brew upgrade 10000DOO/discord-agent-bridge/dab
brew services restart dab   # only needed if running as a service — brew upgrade alone doesn't restart it
```

The in-Discord `/dab-update` command (see Features → Auto-update below) does **not** work for a Homebrew install — it looks for a `swift/scripts/install.sh` checkout, which a Homebrew install doesn't have. Always use `brew upgrade` for this install method.

> ⚠️ **Don't run two instances with the same bot token at the same time.** `dab` (foreground, `brew services`, or the manual/from-source install below) all read the same `DISCORD_BOT_TOKEN`. Starting a second instance with that token opens a second gateway connection to the same bot account — it won't crash, it'll just run alongside the first one and cause duplicate/conflicting replies. Pick exactly one install method per bot token.

### macOS (manual — from source)

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge

# Claude sidecar deps (skip if you only use Codex/Grok)
npm install

bash swift/scripts/install.sh
# first install copies swift/deploy/env.example → ~/.dab/env (0600)
```

Edit secrets (token lives **only** here — never in the plist):

```bash
$EDITOR ~/.dab/env
# DISCORD_BOT_TOKEN=...
```

Reload after editing env:

```bash
launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist
launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist
```

Service helpers (after install):

```bash
dab service status    # or: ~/.dab/bin/dab service status
dab service restart
```

Update: from Discord, `/dab-update` checks the release registry and rebuilds/restarts automatically (Features → Auto-update below). To do it manually instead:

```bash
cd discord-agent-bridge   # repo root
git pull
bash swift/scripts/install.sh   # rebuild + reload the LaunchAgent
```

Uninstall (keeps `~/.dab/env` and logs):

```bash
bash swift/scripts/uninstall.sh
```

### Linux (systemd --user)

```bash
bash swift/scripts/install-linux.sh
# edit ~/.dab/env, then:
systemctl --user restart discord-agent-bridge
systemctl --user status discord-agent-bridge
```

Update: `git pull && bash swift/scripts/install-linux.sh` (or `/dab-update` from Discord).

Uninstall: `bash swift/scripts/uninstall-linux.sh`

### Windows (Task Scheduler / onlogon)

```powershell
powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1
# edit %USERPROFILE%\.dab\env
schtasks /Run /TN discord-agent-bridge
```

Update: `git pull` then re-run `install-windows.ps1` (or `/dab-update` from Discord).

Uninstall: `install-windows.ps1 -Uninstall`

### One-shot (no service)

From the **repo root** (Claude sidecar resolves paths relative to the checkout):

```bash
export DISCORD_BOT_TOKEN=your_bot_token
# optional: DAB_CWD, DAB_PERM_MODE, DAB_TURN_TIMEOUT_SEC, DAB_DEV_GUILD_ID
swift run --package-path swift dab
```

On success:

```text
ready: username=<bot> id=<snowflake> app=<application id>
```

---

## Step 3 — Use it in Discord

Typical flow: **`/dab-setup` → `/dab-config` → `/dab-agent start`**, then normal messages in the session channel.

1. **`/dab-setup`** (admin) — control channel, sessions category, status channel (reuses existing).
2. **`/dab-config`** (admin) — role tiers, defaults (backend / model / effort / perm), locale, notifications, image/Chromium render, per-user access overrides.
3. **`/dab-agent start`** — wizard: **folder → [preset if any] → backend → model → effort → permission**. After `/dab-setup`, can create an A4D `proj-<folder>` channel under the sessions category and bind it.
4. In a bound channel, **send normal messages**. Prefix shortcuts also work without the full wizard:

```text
!claude what files are in the current directory?
!codex summarize the last commit
!grok explain this error
!custom <prompt>
```

### Slash commands

| Command | Who | Description |
|---|---|---|
| `/dab-setup` | Admin | Provision control + sessions category + status channel |
| `/dab-config` | Admin | Roles, defaults, locale, notifications, render, access panel |
| `/dab-agent start` | Execute+ | Wizard: bind folder / backend / model / effort / perm (+ presets) |
| `/dab-agent resume` | Execute+ | Re-bind stored session, post status, soft reconnect |
| `/dab-agent close` | Execute+ | Stop backend and unbind this channel |
| `/dab-agent stats` | Execute+ | Active bindings + Claude / Codex / Grok usage when available |
| `/dab-mode backend` | Execute+ | Switch backend (fresh context) |
| `/dab-mode perm` | Execute+ | Switch permission mode (session kept) |
| `/dab-model` | Execute+ | Switch model (autocomplete from provider catalog) |
| `/dab-effort` | Execute+ | Switch reasoning effort (autocomplete) |
| `/dab-clear` | Execute+ | Fresh conversation, same folder/settings |
| `/dab-stop` | Execute+ | Hard-stop this channel’s session |
| `/dab-stop-all` | Admin | Hard-stop every bound session |
| `/dab-doc path:` | Execute+ | Share a workspace markdown file into a document thread |
| `/dab-update` | Admin | Check for a newer release and offer install / restart |

### Permission modes

`default` · `acceptEdits` · `plan` · `bypassPermissions` (plus backend-specific profiles when catalogued).

When tools need approval, the bot posts **Allow / Always-Allow / Deny** buttons. Prefer `default` for real use; `bypassPermissions` skips the UI (trusted machines only). Mid-turn **Interrupt (stop)** stops the running turn without unbinding the channel.

---

## Features

### Session wizard & presets

- Folder browser: navigate, create folders, favorites roots (`config.favorites`), native pick where available.
- **Presets** (per guild): after a normal start, save backend/model/effort/perm as a named preset. Next `/dab-agent start` can pick a preset then only choose the folder.
- **Resume** and **reconfigure** paths from the start flow / slash commands.
- Bot restart restores bindings from `swift-state.json` (optional one-time import from older `state.json` if present).

### Live session UX

- Streaming status embed (text / tool progress).
- Tool activity → Discord work threads with formatted tool output and **diff** views.
- Status-channel notifications for key events (configurable in `/dab-config`).
- Usage embeds (Claude OAuth, Codex rate limits, Grok weekly) from `/dab-agent stats`.
- Idle watchdog notice if a turn goes quiet for a few minutes.
- Host file attach / document share from the agent (`host.file.attach` / share) into the channel, path-confined.

### Image render (tables & Mermaid)

GFM tables and fenced `mermaid` blocks become PNG attachments when:

1. Render is enabled (`/dab-config` → 🖼 render, default on), and  
2. A browser is available: system Chrome/Edge/Chromium, or provisioned under `~/.dab/chromium` (Install Chromium from `/dab-config` or post-`/dab-setup` prompt; needs Node for the download helper).

Implementation: **headless Chrome CLI** screenshots of local HTML (not an in-process browser runtime). Failures fall back to raw markdown. Caps: ~15s timeout, size/cell limits, limited concurrency.

Env overrides: `DAB_RENDER=0|1`, `DAB_MERMAID_JS`, `DAB_CHROMIUM_CACHE`, `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH`.

### Auth & multi-server

- Global config + per-guild `servers/<guildId>.json` overrides (3-layer: global → server → channel binding).
- Role tiers and optional **user-id** tier grants; member default tier + per-member exceptions in `/dab-config` Access.
- DM policy, audit log channel, path confinement for file ops.

### Auto-update

`/dab-update` checks the release registry; with confirmation, runs the platform install path and restarts the service (e.g. `install.sh` + launchctl on macOS). Toggle via `autoUpdate.enabled` in config. **Needs a full repo checkout** (the manual/from-source install above) — it does not work for a Homebrew install; use `brew upgrade` instead (see Homebrew install steps above).

---

## Paths & configuration

### Deploy layout (`~/.dab` / `%USERPROFILE%\.dab`)

| Path | Role |
|---|---|
| `bin/dab` (`.exe` on Windows) | Release binary |
| `env` (0600 on Unix) | Secrets + `DAB_*` (from `swift/deploy/env.example` on first install) |
| `run.sh` / `run.cmd` | Launcher: PATH + `cd` repo root + exec binary |
| `logs/agent.{out,err}.log` | stdout / stderr |
| `chromium/` | Optional provisioned Chrome for Testing |

### Config & state (`~/.discord-agent-bridge/`, override with `DAB_HOME`)

| Path | Role |
|---|---|
| `config.json` | Global config (token optional here, roles defaults, favorites, locale, render, autoUpdate, …) |
| `servers/<guildId>.json` | Per-server auth, defaults, presets, notifications |
| `swift-state.json` | Session bindings (versioned) |

Prefer putting the Discord token in **`~/.dab/env`** for service installs. First-run can also use env / argv only until config exists.

### Environment variables

| Env | Default | Notes |
|---|---|---|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | Required for gateway |
| `DAB_CWD` | home | Default session working directory |
| `DAB_PERM_MODE` | `bypassPermissions` | Prefer `default` with permission UI |
| `DAB_TURN_TIMEOUT_SEC` | `120` | Wait for turn result |
| `DAB_DEV_GUILD_ID` | — | Instant guild slash registration (else global, up to ~1h) |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | Override Claude sidecar spawn command |
| `DAB_RENDER` | (config) | `0` force off PNG; `1` prefer on when Chrome present |
| `DAB_MERMAID_JS` | auto | Path to `mermaid.min.js` |
| `DAB_CHROMIUM_CACHE` | `~/.dab/chromium` | Provisioned browser cache |
| `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` | system scan | Override Chrome binary |
| `CODEX_CMD` | `codex` | Codex CLI override (smokes / discovery) |

### CLI surface (`dab`)

```bash
dab                     # run the bot (token from env / config)
dab --version
dab --setup             # print first-time setup guidance
dab service status      # macOS launchd status
dab service restart     # macOS launchd restart
dab sidecar-smoke       # Claude sidecar protocol handshake
dab codex-smoke         # Codex app-server initialize (exit 0 if CLI missing)
dab grok-smoke          # Grok ACP smoke (exit 0 if CLI missing)
```

Install / uninstall remain shell/PowerShell scripts under `swift/scripts/`.

---

## Architecture

```text
Discord  ◄──►  dab (Swift / DiscordBM)
                 │
                 ├─ Claude  ──stdio JSON-RPC──►  Node sidecar  ──►  Claude Agent SDK
                 ├─ Codex   ──stdio JSON-RPC──►  codex app-server
                 ├─ Grok    ──stdio ACP───────►  grok CLI
                 └─ custom  ──shell env / spawn──►  configured command
```

- **Claude** always goes through the Node sidecar (spawned automatically). Keep a full checkout with `npm install` if you use Claude.
- **Codex / Grok** use native Swift clients; only the matching CLI on `PATH` is required.
- Protocol notes for the Claude sidecar: [`docs/CLAUDE_SIDECAR_PROTOCOL.md`](docs/CLAUDE_SIDECAR_PROTOCOL.md) (local `docs/`, gitignored).

Package layout: [`swift/README.md`](swift/README.md).

---

## Development

```bash
# from repo root
bash verify.sh
# or:
swift build --package-path swift
swift test --package-path swift
```

If `swift test` hangs on a SourceKit / `.build` lock, use an isolated scratch path:

```bash
swift test --package-path swift --scratch-path /tmp/dab-ci
swift build --package-path swift --scratch-path /tmp/dab-ci
```

Backend smokes (`sidecar` / `codex` / `grok`) are best-effort and skip cleanly when a CLI is missing.

Live Discord token is **not** required for build/test. Gateway connect and real agent runs need credentials and are manual.

---

## License

MIT — see [LICENSE](LICENSE).
