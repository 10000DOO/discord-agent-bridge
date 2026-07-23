# discord-agent-bridge

🌐 [한국어](README.ko.md) | **English**

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, and more — per channel. Role-based access, multi-server, extensible.

**A self-hosted Discord bot that puts Claude Code (or Codex) into a Discord channel, running on your own machine.** Published on npm — one `npm install -g` and three commands to auto-start.

---

## Why this?

- 🏠 **Fully self-hosted.** The bot runs on your PC. Your code, your sessions, and your CLI tokens never leave your machine.
- 📱 **You don't need to be at your desk.** Fire off a task from Discord on your phone — streaming output, tool-run logs, and permission prompts all show up in the channel.
- 🗂️ **One channel = one project = one session.** Each channel is bound to its own folder, backend, model, and permission mode. Isolated by design.
- 👥 **Team-friendly by default.** Anyone in the channel can watch the session unfold. A 3-tier role system (admin / execute / read-only) controls who can actually run things.
- 🔀 **Claude ⇄ Codex on the fly.** Switch backends with a single `/mode` command.
- ⚙️ **Same power as the terminal.** Reads your project's `.claude/` and `.codex/` configs as-is — subagents, skills, hooks, MCP, and plugin commands all work exactly like they do in the CLI.

---

## Prerequisites

- **Node.js 20 or later**
- The CLI for whichever backend you'll use, already **installed and logged in**:
  - **Claude mode** → [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` login, or `ANTHROPIC_API_KEY`)
  - **Codex mode** → the `codex` CLI, logged in
- **A Discord bot token** (Step 1 below)

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

## Step 2 — Install & run

Three lines take you from install to auto-start on reboot. `service install` picks the right auto-start for your OS — **launchd on macOS, systemd on Linux, Task Scheduler on Windows**.

```bash
npm install -g discord-agent-bridge      # install
discord-agent-bridge --setup             # first run only (enter token, etc.)
discord-agent-bridge service install     # register auto-start + start now
```

Manage it:

```bash
discord-agent-bridge service status      # is it registered / running?
discord-agent-bridge service restart     # restart
discord-agent-bridge service uninstall   # remove
```

Upgrade:

```bash
npm install -g discord-agent-bridge@latest
discord-agent-bridge service restart
```

> ⚠️ **Windows note**: registers a Task Scheduler logon trigger, so the bot **starts at login** (no admin needed). It doesn't guarantee auto-restart on crash (macOS/Linux do).

---

## Step 3 — Using it in Discord

Once the bot joins a server, it **automatically creates a control channel (`#session-generator`), a sessions category, and a notifications channel (`#agent-status`)** (as long as it has Manage Channels). From there: **`/config` → `/agent start`**.

1. **(Automatic)** Channel structure is created on bot start / server invite. Admins can rebuild it manually with **`/setup`** (existing channels are reused).
2. **`/config`** (admin) — set role tiers and defaults. Server Administrators can always use the bot even before roles are configured.
3. In `#session-generator`, run **`/agent start`**. The **wizard** walks you through: **working folder → backend (Claude / Codex) → model → reasoning effort → permission mode**. Each step advances with a **Next** button. The folder browser lets you navigate to parents/other volumes, create folders, and resume prior sessions. On confirm, a **dedicated session channel (`proj-<folder>`)** is created and bound.
4. In that session channel, **just send normal messages**. Claude mode gives you streaming output, tool-run threads, and permission approval buttons.

### Key commands

| Command | Description |
|---|---|
| `/setup` | (admin) Create the control channel + sessions category (reuses existing) |
| `/agent start` | Start a new session — creates a dedicated session channel on confirm |
| `/agent resume` | Resume a previous session |
| `/agent close` | End the session and delete its channel |
| `/agent stats` | Active sessions, session stats, and Claude usage (only you can see it) |
| `/mode <claude\|codex>` | Switch backend (⚠️ starts a fresh conversation — prior context is not carried over) |
| `/mode perm <mode\|profile>` | Switch permission mode/profile (session context is preserved) |
| `/stop` | Stop the current session immediately (kill switch) |
| `/stop-all` | (admin) Stop every session |
| `/config` | (admin) Configure role tiers + defaults (backend, model, permission mode, language, Codex path) |

### Permission modes

- `default` — asks before each tool run with **Allow/Deny buttons** (safest)
- `acceptEdits` — file edits auto-accepted
- `plan` — plans only, no execution
- `bypassPermissions` — fully automatic (trusted projects only)

Codex maps these onto its own approval/sandbox modes.

### Event notifications (`#agent-status`)

Completions and errors from all your sessions get summarized into a single `#agent-status` channel. Toggle it and change the target channel from `/config` → **🔔 Notification Settings**.

### Sharing documents

`/doc path:docs/foo.md` in a session channel posts a workspace markdown file into a `📄` thread — the original `.md` is always attached, plus the body text (tables/mermaid rendered as images when rendering is on). Or just ask the agent to share a document (the `share_document` tool). Usage & config: [docs/document-share-usage.md](docs/document-share-usage.md) (Korean).

---

License: MIT
