# discord-agent-bridge

🌐 [한국어](README.ko.md) | **English**

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, Grok, and more — per channel. Role-based access, multi-server, extensible.

**A self-hosted Discord bot that puts Claude Code (or Codex / Grok) into a Discord channel, running on your own machine.**

The **product path is Swift** (`dab`). Claude Code still needs a thin **Node (TypeScript) sidecar** because the official Agent SDK is Node-only. The old npm TypeScript standalone bot has been **removed from this repo** — TypeScript now exists solely as that Claude sidecar process.

---

## Why this?

- 🏠 **Fully self-hosted.** The bot runs on your PC. Your code, your sessions, and your CLI tokens never leave your machine.
- 📱 **You don't need to be at your desk.** Fire off a task from Discord on your phone — streaming output, tool-run logs, and permission prompts all show up in the channel.
- 🗂️ **One channel = one project = one session.** Each channel is bound to its own folder, backend, model, and permission mode. Isolated by design.
- 👥 **Team-friendly by default.** Anyone in the channel can watch the session unfold. A 3-tier role system (admin / execute / read-only) controls who can actually run things.
- 🔀 **Claude ⇄ Codex ⇄ Grok on the fly.** Switch backends with `/mode` (when the session is bound).
- ⚙️ **Same power as the terminal.** Reads your project's `.claude/` and `.codex/` configs as-is — subagents, skills, hooks, MCP, and plugin commands work like they do in the CLI (Claude path via sidecar).

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **macOS 13+** | Primary target for the Swift product |
| **Swift 6.1+** | Xcode or Command Line Tools |
| **Node.js 20+** | **Claude only** — required to spawn the sidecar; not used for Codex/Grok |
| Backend CLIs, installed & logged in | **Claude Code** (`claude` login or `ANTHROPIC_API_KEY`); **Codex** CLI; **Grok** CLI as needed |
| **Discord bot token** | Step 1 below |

---

## Step 1 — Create a Discord bot

You need your own bot. About 5 minutes.

1. Open the **[Discord Developer Portal](https://discord.com/developers/applications)** → top-right **New Application** → give it a name (e.g. `my-agent-bot`) → **Create**.
2. Left sidebar **Bot** tab → **Reset Token** → **copy the token** and stash it somewhere safe.
   - ⚠️ This token is a password. If it leaks, hit **Reset Token** immediately.
3. Still on the **Bot** tab, under **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **required** (the bot has to read message content)
   - ✅ **SERVER MEMBERS INTENT** — recommended (used for role checks)
   - Enable and **Save Changes**.
4. Left sidebar **OAuth2** tab → copy the **Client ID (Application ID)**.
5. **Build an invite link** — OAuth2 → **URL Generator**:
   - **Scopes**: `bot`, `applications.commands`
   - **Bot Permissions**: `Manage Channels`, `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Create Public Threads`, `Send Messages in Threads`, `Manage Threads`, `Add Reactions`
   - Paste the generated URL into your browser and **invite it to your server**.

---

## Step 2 — Install & run (Swift)

Clone this repo (the Claude sidecar still resolves paths relative to the checkout), then install the binary as a per-user LaunchAgent:

```bash
git clone https://github.com/<you>/discord-agent-bridge.git
cd discord-agent-bridge
# Node deps only needed for Claude sidecar
npm install

bash swift/scripts/install.sh
# first install copies swift/deploy/env.example → ~/.dab/env (0600)
# edit the token, then reload launchd if you already loaded once
```

Edit secrets (token lives only here — never in the plist):

```bash
$EDITOR ~/.dab/env
# DISCORD_BOT_TOKEN=...
```

Reload after editing env:

```bash
launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist
launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist
```

### One-shot (no launchd)

From the **repo root** (so the sidecar can find `src/sidecar` / `node_modules`):

```bash
export DISCORD_BOT_TOKEN=your_bot_token
# optional: DAB_CWD, DAB_PERM_MODE, DAB_TURN_TIMEOUT_SEC, DAB_DEV_GUILD_ID
swift run --package-path swift dab
```

Uninstall (keeps `~/.dab/env` and logs):

```bash
bash swift/scripts/uninstall.sh
```

### Paths (Swift)

| Path | Role |
|---|---|
| `~/.dab/bin/dab` | Release binary (install.sh) |
| `~/.dab/env` | Secrets + env (0600) — token, optional `DAB_*` |
| `~/.dab/run.sh` | Launcher: PATH + `cd` repo root + exec `dab` |
| `~/Library/LaunchAgents/com.discord-agent-bridge.plist` | LaunchAgent (HOME only; no tokens) |
| `~/.dab/logs/` | stdout / stderr |
| `~/.discord-agent-bridge/` | **Config & state** (same layout as the legacy TS bot; override with `DAB_HOME`) |

Config dir layout:

| File | Role |
|---|---|
| `config.json` | Global config (auth roles, defaults, …) |
| `servers/<guildId>.json` | Per-server overrides |
| `swift-state.json` | Swift session bindings (versioned) |

More detail: [`swift/README.md`](swift/README.md) · design: [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md).

### Hybrid Claude sidecar (important)

```
Swift dab  ──stdio JSON-RPC──►  Node Claude sidecar  ──►  Claude Agent SDK
Codex / Grok                 ──stdio (native clients)──►  their CLIs
```

- **Swift always** talks to Claude through the Node sidecar process (spawned automatically).
- You still need **Node + `npm install` in the checkout** for Claude mode; Codex/Grok do not need Node.
- Override spawn with `DAB_CLAUDE_SIDECAR_CMD` if needed.
- Protocol: [`CLAUDE_SIDECAR_PROTOCOL.md`](CLAUDE_SIDECAR_PROTOCOL.md).

> **`DAB_CLAUDE_SIDECAR=1`** is a **legacy TypeScript-main** switch only (opt-in sidecar inside the npm bot). The Swift product does not use that env var — it always uses the sidecar for Claude.

---

## Step 3 — Using it in Discord

Typical flow: **`/setup` → `/config` → `/agent start`**, then normal messages in the session channel.

1. **`/setup`** (admin) — control channel, sessions category, status channel (reuses existing).
2. **`/config`** (admin) — role tiers + defaults (mode/model/effort/perm, dmPolicy) + notifications + **image/chromium render** sub-panels (enable + Install Chromium).
3. **`/agent start`** — wizard: **folder → backend → model → effort → permission**. Folder browser supports navigate / create / native pick. On confirm, creates an A4D session channel when `/setup` has run, then binds it.
4. In a bound channel, **send normal messages**. Prefix shortcuts still work: `!claude` / `!codex` / `!grok` / `!custom`.

### Key commands (Swift)

| Command | Description |
|---|---|
| `/setup` | (admin) Provision control + sessions category + status |
| `/agent start` | Wizard: bind backend / model / effort / perm (+ folder) |
| `/agent resume` | Resume a previous session (binding layer) |
| `/agent close` | End session (backend stop) |
| `/agent stats` | Session stats + Claude/Grok usage where available |
| `/mode` · `/model` · `/effort` · `/mode perm` | Live binding updates |
| `/clear` | Fresh conversation, same config |
| `/stop` · `/stop-all` | Interrupt current / all (admin) |
| `/config` | (admin) Role tiers + core defaults |
| `/doc` | Share a workspace markdown into a thread |
| `/update` | (admin) Check npm registry for newer package version |

Permission modes: `default` · `acceptEdits` · `plan` · `bypassPermissions` (and backend-specific profiles where catalogued). Default smoke path may still use `bypassPermissions` — prefer `default` when using the Allow/Deny UI.

> **Parity note:** Swift is the product path at **~99% product parity** (port mainline complete; **P0–P2 gap backlog closed**). Residual is **W13-b product-deferred** (keep `bypassPermissions` default) and intentional **OK-DIFF** only — not incomplete mainline work. See [Compatibility matrix](#swift-vs-typescript-compatibility), [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md) §0, and [`SWIFT_TS_PARITY_GAPS.md`](SWIFT_TS_PARITY_GAPS.md).

---

## Migrating from npm TypeScript → Swift `dab`

If you already run `npm install -g discord-agent-bridge` / `discord-agent-bridge service install`:

1. **Stop the legacy service** so two bots do not share the same token:
   ```bash
   discord-agent-bridge service uninstall   # or stop/status first
   ```
2. **Keep config** under `~/.discord-agent-bridge/` (or your `DAB_HOME`). Swift uses the **same directory and `config.json` / `servers/*.json` layout** for auth and defaults.
3. **Session state is separate:** TS used `state.json`; Swift uses `swift-state.json` (versioned). Bindings are not auto-imported one-to-one — re-run `/agent start` (or restore via Swift resume paths) after switching.
4. **Install Swift** with `bash swift/scripts/install.sh` from a full checkout that still has Node deps for Claude.
5. **Env mapping**

   | Concern | Legacy TS | Swift |
   |---|---|---|
   | Token | wizard / service env | `~/.dab/env` → `DISCORD_BOT_TOKEN` |
   | First-time guild structure | `discord-agent-bridge --setup` | Discord **`/setup`** (admin) |
   | Config root | `DAB_HOME` or `~/.discord-agent-bridge` | **same** |
   | Auto-start | `discord-agent-bridge service install` | `swift/scripts/install.sh` · `install-linux.sh` · `install-windows.ps1` |
   | Service uninstall | `service uninstall` | `uninstall.sh` / `uninstall-linux.sh` / `install-windows.ps1 -Uninstall` |
   | Claude process | in-process **or** `DAB_CLAUDE_SIDECAR=1` | **always sidecar** |
   | Sidecar spawn override | (sidecar path) | `DAB_CLAUDE_SIDECAR_CMD` |
   | Working dir default | config / wizard | `DAB_CWD` env + wizard folder step |
   | Binary / logs (deploy) | under service home | `~/.dab/` |
   | Full npm CLI | `discord-agent-bridge …` | not reimplemented — scripts + `/setup` + env (see [`swift/README.md`](swift/README.md#cli--service-equivalents-ts-npm--swift)) |

6. **Do not run both mains** against one bot token. Sidecar alone is fine (spawned by Swift).

---

## Swift vs TypeScript compatibility

Status is intentional: **Swift-first product**; the legacy TS standalone bot has been removed, TS tree now holds only the Claude sidecar. Table below reflects the legacy TS main's capability **before removal**, for historical comparison. **~99% product parity — port mainline complete; P0–P2 gap backlog closed.** Residual: **W13-b product-deferred** (keep bypass default) · intentional **OK-DIFF** · optional polish only. Full gap list: [`SWIFT_TS_PARITY_GAPS.md`](SWIFT_TS_PARITY_GAPS.md).

| Area | Swift (`dab`) | Legacy TS main |
|---|---|---|
| Discord gateway + slash | ✅ DiscordBM | ✅ discord.js |
| Claude turns | ✅ via **Node sidecar** (always) | ✅ in-process default; sidecar opt-in `DAB_CLAUDE_SIDECAR=1` |
| Codex / Grok | ✅ native stdio clients | ✅ |
| Custom backend + shell env | ✅ | ✅ |
| Session bind / restart reconnect | ✅ `SessionStore` + lazy resume | ✅ orchestrator |
| Auth roles / audit / path confinement | ✅ (W13-b tool allowlist **product-deferred** while default stays `bypassPermissions`) | ✅ |
| 3-layer config | ✅ global → server → binding | ✅ |
| `/agent start` folder wizard | ✅ folder · resume · reconfigure · A4D · preset | ✅ full |
| Live slash model/effort/mode/clear/stop | ✅ binding + Claude live `setModel`/`setEffort` RPC + displayName re-resolve | ✅ |
| Usage / HUD | ✅ stats + Claude/Grok usage + tools/subagent HUD + live stream status embed | ✅ richer panels |
| Tool thread / diff / status embed / notifier | ✅ Claude/Codex/Grok mid-turn tool path + pin (best-effort) | ✅ |
| `/config` panel | ✅ roles·mode/model/effort/perm·dm·notif·locale·**image render (S3)** | ✅ fuller UI |
| `/setup` · `/doc` · Always-Allow | ✅ | ✅ |
| Auto-update | ✅ registry check + Yes/No + **install.sh + launchctl restart** | ✅ npm reinstall path |
| Chromium table/mermaid render | ✅ **headless Chrome CLI** (system Chrome or provisioned; not puppeteer-in-Swift) | ✅ puppeteer |
| Host file attach to Discord | ✅ confined upload (`host.file.attach`) | ✅ (sidecar path) |
| Linux/Windows service | ✅ launchd / systemd / schtasks scripts | ✅ launchd / systemd / schtasks |
| npm global install | ❌ (checkout + build) | ✅ |

**Residual (not mainline incomplete work):** **W13-b** product-deferred (allowlist when default perm moves off bypass) · **OK-DIFF** (sidecar always, Chromium CLI, etc.) · **optional polish** — see [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md) §0 and [`SWIFT_TS_PARITY_GAPS.md`](SWIFT_TS_PARITY_GAPS.md).

---

## Legacy TypeScript standalone bot — removed

The old npm TypeScript standalone bot (`discord-agent-bridge --setup`, `service install`, in-process Claude mode, etc.) has been deleted from this repo's source tree — see [`docs/finish-swift-port-remove-legacy-ts.md`](docs/finish-swift-port-remove-legacy-ts.md). It has no `bin`/CLI entry point anymore and cannot be installed or run standalone.

TypeScript now exists **only** as the thin Claude sidecar process that Swift `dab` spawns automatically — see [Hybrid Claude sidecar](#hybrid-claude-sidecar-important). Install with **Swift** ([Step 2](#step-2--install--run-swift)).

---

## Development

```bash
bash verify.sh
```

Gate (must pass): Swift build + Swift tests under `swift/`. Backend smokes (`sidecar` / `codex` / `grok`) are best-effort and skip cleanly when a CLI is missing.

⚠️ Prefer an isolated scratch path if `swift test` hangs on the package `.build` indexer lock:

```bash
swift test --package-path swift --scratch-path /tmp/dab-ci
```

Port tracking: [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md). Parity gaps (closed): [`SWIFT_TS_PARITY_GAPS.md`](SWIFT_TS_PARITY_GAPS.md). Package notes: [`swift/README.md`](swift/README.md).

---

License: MIT
