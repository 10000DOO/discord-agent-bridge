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
- 🔀 **Claude ⇄ Codex ⇄ Grok (and custom) on the fly.** Switch backends with `/mode` when a session is bound.
- ⚙️ **Same power as the terminal.** Project `.claude/` / `.codex/` configs are used as-is — subagents, skills, hooks, MCP, and plugin commands behave like the CLI.
- 💾 **Session presets.** Save backend/model/effort/perm combos per guild and restart sessions in two steps (folder → preset).
- 🖼 **Rich answers.** GFM tables and Mermaid diagrams can render as PNG; tool runs open work threads with diffs; usage panels show Claude / Codex / Grok limits.

---

## Prerequisites

This guide is **macOS-first**. For Linux and Windows see [Other operating systems](#other-operating-systems--linux--windows) at the bottom.

| Requirement | Notes |
|---|---|
| **macOS 13+** | Product binary is SwiftPM `dab` |
| **Swift 6.1+** | Xcode or Command Line Tools (`xcode-select --install`) |
| **Node.js 20+** | **Claude only** — spawns the Claude sidecar; not needed for Codex/Grok |
| Backend CLIs, installed & logged in | **Claude Code** (`claude` login or `ANTHROPIC_API_KEY`); **Codex** CLI; **Grok** CLI as needed. Resolved from `PATH`, then the usual user bin dirs (`~/.local/bin`, `~/.dab/bin`, `~/.cargo/bin`, `~/.grok/bin`, Homebrew) — a service started with a minimal `PATH` still finds them |
| **Discord bot token** | Step 1 below |

---

## Step 1 — Create a Discord bot and get its token

About 3 minutes. The only thing you need out of this step is **the token** — Step 3 builds the server invite link for you.

1. Open the **[Discord Developer Portal](https://discord.com/developers/applications)** → **New Application** → name it (e.g. `my-agent-bot`) → **Create**.
2. **Bot** tab (left sidebar) → **Reset Token** → copy the token it shows.
   - Discord shows a token **exactly once**. Viewing it again means resetting again, which immediately invalidates the old one.
   - ⚠️ **Not the OAuth2 tab's Client Secret.** A bot token is a ~70-char string in three dot-separated parts; a client secret is 32 chars with no dots. dab never uses the client secret.
   - The token is a password. If it leaks, **Reset Token** immediately.
3. Same **Bot** tab, under **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **required** (without it the bot cannot read messages)
   - ✅ **SERVER MEMBERS INTENT** — recommended (role checks)
   - Save Changes.

You don't need to invite the bot yet. Step 3 generates an invite URL with every required permission baked in — and if you already invited it, it just lists the server for you to pick.

---

## Step 2 — Install (macOS)

```bash
brew tap 10000DOO/discord-agent-bridge
brew install 10000DOO/discord-agent-bridge/dab
```

Builds `dab` from source and installs the Claude sidecar alongside it — no separate `npm install`. Node.js 20+ and Swift 6.1+ must already be present (see Prerequisites); the formula only checks for them.

<details>
<summary>Build from source instead of Homebrew</summary>

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install                      # Claude sidecar only (skip if you use Codex/Grok only)
bash swift/scripts/install.sh    # build + register a launchd agent for login
```

The in-Discord `/update` command only works with this install method. Homebrew installs use `brew upgrade`.

</details>

---

## Step 3 — Connect it with one command: `dab --setup`

```bash
dab --setup
```

Answer the prompts and you're done. No files to locate and edit, no server id to hunt down.

```text
$ dab --setup

dab 설정을 시작합니다. 물어보는 대로 답하면 나머지는 알아서 처리합니다.

1) 봇 토큰을 붙여넣고 엔터를 누르세요. (입력은 화면에 보이지 않습니다)
   Discord Developer Portal → 내 애플리케이션 → 왼쪽 [Bot] 탭 → [Reset Token]
   ⚠️ OAuth2 탭의 Client Secret 이 아닙니다 — 점(.)이 2개 들어간 70자 내외 문자열입니다.

   확인 중…
   ✓ 확인 완료 — 봇 이름: my-agent-bot

2) 이 봇을 쓸 서버를 고릅니다.

   이 봇이 들어가 있는 서버가 없습니다. 아래 주소를 열어 서버에 초대해 주세요:

   https://discord.com/api/oauth2/authorize?client_id=…&scope=bot%20applications.commands&permissions=…

   초대를 마쳤으면 엔터를 누르세요. (건너뛰려면 s 입력)

   ✓ my-team

저장했습니다 → /Users/me/.dab/env

백그라운드 서비스를 재시작해서 지금 적용할까요? [Y/n]

끝났습니다. 디스코드의 my-team 서버에서 /setup 을 쳐보세요.
```

> The CLI speaks Korean, matching `dab service`'s existing output.

What the wizard handles for you:

- **Verifies the token on the spot.** A truncated paste or a Client Secret is caught before anything is saved; on success it prints the bot's name so you can see which bot you just wired up.
- **Builds the invite URL.** Every permission the bot can use is already baked in — no picking checkboxes in the OAuth2 URL Generator, and no second re-authorization click the first time a feature needs one more bit. Member moderation (kick / ban / timeout), voice, and `Administrator` are deliberately **not** requested; Discord shows you the full list before you approve.
- **Lists the servers your bot is in and lets you pick one.** No Developer Mode, no right-click-copy-id. This is what makes slash commands register **instantly** — without it Discord propagates them globally, which takes up to an hour.
- **Writes `~/.dab/env` (0600).** Existing lines and comments are preserved; only the relevant keys are updated.

Running plain `dab` with no token saved starts the same wizard. Re-run `dab --setup` any time to switch bots.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `✗ 이건 봇 토큰이 아닙니다` | You pasted the OAuth2 tab's **Client Secret**. Use **Bot** tab → **Reset Token** |
| `✗ 디스코드가 거절했습니다` | The token expired (you pressed Reset Token again) or the paste was truncated. Issue a fresh one |
| Bot is online but `/setup` isn't listed | You skipped the server at step 2 (up to 1h wait). Re-run `dab --setup` and pick it for instant registration |
| Bot stays offline | Check that **MESSAGE CONTENT INTENT** (Step 1) is enabled |
| You have a `~/.discord-agent-bridge/config.json` | Leftover from the TypeScript bridge. `~/.dab/env` now takes precedence, so it's harmless |
| Token may have leaked | Developer Portal → Bot → **Reset Token**, then re-run `dab --setup` |

### Keep it running

```bash
brew services start dab      # start (auto-restarts on crash/reboot)
brew services list           # status
brew services restart dab    # after changing settings
brew services stop dab       # stop
```

Logs: `$(brew --prefix)/var/log/dab.log` · `dab.error.log`
(Source installs: `dab service status` / `dab service restart`, logs in `~/.dab/logs/agent.out.log`)

A successful connection logs:

```text
ready: username=<bot> id=<snowflake> app=<application id>
registered setup, config, agent, ... to guild <server id>
```

Update:

```bash
brew upgrade 10000DOO/discord-agent-bridge/dab
brew services restart dab   # only if running as a service
```

> ⚠️ **Don't run two instances with the same bot token.** Foreground `dab`, `brew services`, and a source install all read the same token. A second instance won't crash — it just runs alongside the first and causes duplicate or conflicting replies.

---

## Step 4 — Use it in Discord

Typical flow: **`/setup` → `/config` → `/agent start`**, then normal messages in the session channel.

1. **`/setup`** (admin) — control channel, sessions category, status channel (reuses existing).
2. **`/config`** (admin) — role tiers, defaults (backend / model / effort / perm), locale, notifications, image/Chromium render, per-user access overrides.
3. **`/agent start`** — wizard: **folder → [preset if any] → backend → model → effort → permission**. After `/setup`, can create an A4D `<random-id>-<folder>-proj` channel under the sessions category and bind it.
4. In a bound channel, **send normal messages** — plain text goes to the channel's own backend. Message prefixes send one turn to a specific backend instead:

```text
!claude what files are in the current directory?
!codex summarize the last commit
!grok explain this error
!custom <prompt>          # Claude path + the configured shell-env overlay
```

Prefixes only work in a channel that is **already bound** — an unbound channel can never start a backend by typing one, and DMs are ignored outright. A prefix with an empty prompt just prints its usage line.

### Slash commands

| Command | Who | Description |
|---|---|---|
| `/setup` | Admin | Provision control + sessions category + status channel |
| `/config` | Admin | Roles, defaults, locale, notifications, render, access panel |
| `/agent start` | Execute+ | Wizard: bind folder / backend / model / effort / perm (+ presets) |
| `/agent resume` | Execute+ | Re-bind stored session, post status, soft reconnect |
| `/agent close` | Execute+ | Stop backend and unbind this channel |
| `/agent stats` | Execute+ | Active bindings + Claude / Codex / Grok usage when available |
| `/mode backend` | Execute+ | Switch backend (fresh context) |
| `/mode perm` | Execute+ | Switch permission mode (session kept) |
| `/model` | Execute+ | Switch model (autocomplete from provider catalog) |
| `/effort` | Execute+ | Switch reasoning effort (autocomplete) |
| `/clear` | Execute+ | Fresh conversation, same folder/settings (on an orchestrator channel, its module sessions are cleared too) |
| `/stop` | Execute+ | Hard-stop this channel’s session |
| `/stop-all` | Admin | Hard-stop every bound session |
| `/doc path:` | Execute+ | Share a workspace markdown file into a document thread |
| `/diff` | Execute+ | Open a thread with this folder's uncommitted changes (file picker + expand all) |
| `/redmine` | Execute+ | Modal (URL / API key / project) to connect Redmine notifications |
| `/redmine-issue-select` | Execute+ | Pick a New/Doing Redmine issue from a dropdown and kick a session off it |
| `/command` | Execute+ | Run a slash command this channel's backend itself advertises (autocomplete + prompt modal) |
| `/command-list` | Execute+ | List every slash command this channel's backend supports |
| `/update` | Admin | Check for a newer release and offer install / restart |

Commands register under their bare name, with no prefix. `/setup`, `/config`, `/stop-all`, and `/update` need the admin tier (or Discord's Administrator permission); everything else needs execute or higher. `/setup` has a one-time bootstrap exception: on a guild with no admins configured yet, whoever runs it first claims admin.

Commands that act on *this channel's* session (`/model`, `/effort`, `/mode`, `/clear`, `/stop`) reply "no session" unless the channel is bound.

A few backend commands only exist inside the CLI's own interactive screen, so asking for them over the protocol returns a one-line summary or "isn't available in this environment" — for those (`/status`, `/mcp`, `/memory`, `/skills`, `/plugin` on Claude; `/context` on Grok) the bridge rebuilds the screen from the live session's own facts (version, cwd, model, permission mode, MCP servers, skills/plugins, memory files) and posts that instead. When a fact never arrived, the backend's original text passes through unchanged — nothing is invented.

### Permission modes

`default` · `acceptEdits` · `plan` · `bypassPermissions` (plus backend-specific profiles when catalogued).

When tools need approval, the bot posts **Allow / Always-Allow / Deny** buttons. Prefer `default` for real use; `bypassPermissions` skips the UI (trusted machines only). Mid-turn **Interrupt (stop)** stops the running turn without unbinding the channel.

---

## Features

### Session wizard & presets

- Folder browser: navigate, create folders, favorites roots (`config.favorites`), native pick where available.
- **Presets** (per guild): after a normal start, save backend/model/effort/perm as a named preset. Next `/agent start` can pick a preset then only choose the folder.
- **Resume** and **reconfigure** paths from the start flow / slash commands.
- Bot restart restores bindings from `swift-state.json` (optional one-time import from older `state.json` if present).

### Live session UX

- Streaming status embed (text / tool progress). The title's elapsed clock (`Responding… · 3m 34s`) is re-rendered on a timer, so it keeps moving through a stretch of a turn that emits no events at all — a session that is working never looks the same as one that has hung.
- **Tool-input progress (Claude).** A tool's input is built before the call itself is announced, so a large `Write`/`Edit` used to leave the channel silent for minutes. The tool's name now posts as soon as its input starts building, with the accumulated size following every 8KB (`Write` → `Write: 8.0KB` → …). Codex reports the equivalent from its own `item/started` notifications; Grok's CLI delivers a tool's input in one final batch, so only the elapsed clock moves there.
- Tool activity → Discord work threads with formatted tool output and **diff** views. The activity log line is a one-line CLI-style summary; the thread carries the **whole** result body — output longer than one message is split across several instead of being cut off.
- Status-channel notifications for key events (configurable in `/config`).
- Usage embeds (Claude OAuth, Codex rate limits, Grok weekly) from `/agent stats`.
- Idle watchdog notice if a turn goes quiet for a few minutes.
- Host file attach / document share from the agent (`host.file.attach` / share) into the channel, path-confined.
- **Attachments you drop in the channel** are downloaded into `<workspace>/.dab-attachments/<uuid>/` (realpath-confined, one directory per message so concurrent turns can't clobber each other). Images become vision input for backends that take it; everything else is passed as an absolute-path hint appended to the prompt.

### Task panel (pinned)

All three backends publish a task list as they work (Claude `TaskCreate`/`TaskUpdate` — or `TodoWrite` on older CLIs, Codex `update_plan`, Grok ACP plan updates). That list becomes **one pinned message per channel** — a checklist with `✓` done / `▶` in progress / `•` pending, plus a `done/total` count that turns green when everything is finished. Open it from the channel's 📌 at any time instead of scrolling back.

It is pinned **once** and edited from then on: Discord posts a system line on every pin and caps a channel at 50 pins, so re-pinning each update would spam the channel. A turn that publishes no list leaves the previous one standing; `/clear`, `/stop`, and unbinding remove the panel. After a restart the bot re-attaches to the panel already pinned in the channel rather than pinning a second one.

Pinning needs the `Manage Messages` permission — or, on servers where Discord has split pinning into its own `Pin Messages` permission, that one. The invite link asks for both. Without either the panel is posted as a normal message and the bot explains once how to fix it — including a ready-made re-authorization link. Discord refuses to let a bot grant itself a permission it lacks, so one click is the minimum; there is no fully automatic path.

### Uncommitted changes (`/diff`)

`/diff` opens a thread for the channel's folder holding a summary (file list with `+`/`-` counts, repo and branch) and a **file picker** plus **Expand all**. Diff bodies are posted in ```diff``` fences and never clipped — a long one costs extra messages, not content. More than 25 changed files means more than one picker, not a truncated list. A folder with no uncommitted changes, or one that isn't a git repository, gets a one-line answer and no thread.

### Image render (tables & Mermaid)

GFM tables and fenced `mermaid` blocks become PNG attachments when:

1. Render is enabled (`/config` → 🖼 render, default on), and  
2. A browser is available: system Chrome/Edge/Chromium, or provisioned under `~/.dab/chromium` (Install Chromium from `/config` or post-`/setup` prompt; needs Node for the download helper).

Implementation: **headless Chrome CLI** screenshots of local HTML (not an in-process browser runtime). Failures fall back to raw markdown. Caps: ~15s timeout, size/cell limits, limited concurrency.

Env overrides: `DAB_RENDER=0|1`, `DAB_MERMAID_JS`, `DAB_CHROMIUM_CACHE`, `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH`.

### Redmine integration

`/redmine` opens a modal for **URL**, **API key**, and optional **project**. Once saved, a per-guild poller checks every 5 minutes for issues in a New/Doing status and posts an issue card (title with number, link, description, project, target version) into the configured report channel. Status IDs are resolved per instance rather than hardcoded, and bilingual labels like `신규(New)` / `진행(Doing)` match.

An issue card offers **Start / Cancel**: Start either opens the session wizard seeded with that issue, or kicks the issue off into an existing session after a confirm step. `/redmine-issue-select` reaches the same dropdown on demand (same status filter, no "since last check" cutoff); Discord caps a dropdown at 25 options, so longer lists are split across several messages instead of truncated.

API keys are encrypted at rest with `DAB_REDMINE_KEY_SECRET` — generated into `~/.dab/env` on first boot if absent. Without it, encrypt and decrypt both fail rather than falling back to plaintext.

### Auth & multi-server

- Global config + per-guild `servers/<guildId>.json` overrides (3-layer: global → server → channel binding).
- Role tiers and optional **user-id** tier grants; member default tier + per-member exceptions in `/config` Access.
- DM policy, audit log channel, path confinement for file ops.

### Auto-update

`/update` checks the release registry; with confirmation, runs the platform install path and restarts the service (e.g. `install.sh` + launchctl on macOS). Toggle via `autoUpdate.enabled` in config. **Needs a full repo checkout** (the manual/from-source install above) — it does not work for a Homebrew install; use `brew upgrade` instead (see Homebrew install steps above).

The same `autoUpdate.enabled` switch also keeps the **backend runtimes** current. Once an hour the bot checks the Claude Agent SDK, the Codex CLI and the Grok CLI and upgrades whichever is behind — npm-global installs and Homebrew casks are supported; any other install layout reports `unsupported` and is left alone. A swap only starts when no turn is running anywhere, and new turns wait just for its duration. After a swap the runtime restarts and its model catalog is probed; a broken upgrade rolls back. One `dab` process at a time does this (cross-process lock file), and an update interrupted by a kill is rolled forward or back on the next boot. Results go to the log as `provider-runtime: …` lines, not to Discord.

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

The Discord token belongs in **`~/.dab/env`** — that is what `dab --setup` writes and what `dab` loads on every start, service or foreground. Token lookup order: `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` in the process env (which `~/.dab/env` populates) → first CLI argument → `config.json`'s `discord.token` as a last-resort fallback for old TypeScript-era installs.

### Environment variables

| Env | Default | Notes |
|---|---|---|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | Required for gateway |
| `DAB_CWD` | home | Default session working directory |
| `DAB_PERM_MODE` | `bypassPermissions` | Prefer `default` with permission UI |
| `DAB_TURN_TIMEOUT_SEC` | `120` | Wait for turn result |
| `DAB_DEV_GUILD_ID` | — | Instant guild slash registration (else global, up to ~1h) |
| `DAB_HOME` | `~/.discord-agent-bridge` | Config + state root |
| `DAB_CAPS` | (config) | Render-capability overrides (`toolThreads` / `fileDiff` / `usagePanel` / `streaming`); outranks global + server config |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | Override Claude sidecar spawn command |
| `DAB_RENDER` | (config) | `0` force off PNG; `1` prefer on when Chrome present |
| `DAB_MERMAID_JS` | auto | Path to `mermaid.min.js` |
| `DAB_CHROMIUM_CACHE` | `~/.dab/chromium` | Provisioned browser cache |
| `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` | system scan | Override Chrome binary |
| `CODEX_CMD` | `codex` | Codex CLI override (spawn + smokes) |
| `GROK_CMD` | `grok` | Grok CLI override (spawn + smokes) |

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
dab attach-mcp          # stdio MCP server (file attach / doc share / order / report tools)
```

Only `dab` with no subcommand boots the gateway; every subcommand above runs and exits.

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

## Other operating systems — Linux / Windows

The guide above is macOS-first. Step 1 (create the bot) and Step 3 (`dab --setup`) are identical everywhere; only installation and service registration differ.

### Linux (systemd --user)

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install                              # Claude sidecar only (skip for Codex/Grok only)
bash swift/scripts/install-linux.sh
dab --setup                              # token → server → saved
systemctl --user restart discord-agent-bridge
```

Status/logs: `systemctl --user status discord-agent-bridge` · `journalctl --user -u discord-agent-bridge -f`
Update: `git pull && bash swift/scripts/install-linux.sh` (or `/update` in Discord)
Uninstall: `bash swift/scripts/uninstall-linux.sh`

### Windows (Task Scheduler / onlogon)

```powershell
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install
powershell -ExecutionPolicy Bypass -File swift\scripts\install-windows.ps1
dab --setup
schtasks /Run /TN discord-agent-bridge
```

Settings live in `%USERPROFILE%\.dab\env`.
Update: `git pull`, then re-run `install-windows.ps1` (or `/update` in Discord)
Uninstall: `install-windows.ps1 -Uninstall`

### One-shot (no service)

```bash
dab
```

Reads `~/.dab/env` directly, so no environment setup is needed. With no token saved, the setup wizard starts automatically.

---

## License

MIT — see [LICENSE](LICENSE).
