# discord-agent-bridge

🌐 [한국어](README.ko.md) | **English**

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, and more — per channel. Role-based access, multi-server, extensible.

**A self-hosted Discord bot that connects an AI coding agent — Claude Code or Codex — to each channel.** It runs on your own machine, with role-based permissions, multi-server support, and an extensible backend design.

- Currently supports: **Claude Code**, **Codex**
- Extensible: add a mode plugin to connect other agents (e.g. opencode) in the future

> ✅ **Published on npm.** Run it instantly with `npx discord-agent-bridge` (recommended), or install globally / build from source. Supports both **Claude Code** and **Codex** backends.

---

## What is this?

Send a message in a Discord channel like you're chatting, and Claude Code (or Codex) works on that project's folder from your own computer.

- **One channel = one session = one project.** When you create a channel, you set its working folder and backend (Claude/Codex).
- **Invite the same bot to multiple servers** — each server/project gets its own independent configuration.
- **Roles control who can use it.**

---

## Prerequisites

- **Node.js 20 or later**
- The CLI for whichever backend you use must already be **installed and logged in**:
  - **Claude mode** → [Claude Code](https://docs.anthropic.com/en/docs/claude-code) authentication (`claude` login, or an `ANTHROPIC_API_KEY`). Viewing the usage/limits panel requires being **logged in with a Claude Pro/Max subscription**.
  - **Codex mode** → the `codex` CLI installed and logged in.
- **A Discord bot token** (create one in Step 1 below)

---

## Step 1 — Create a Discord bot (Developer Portal)

You need to create your own bot. Takes about 5 minutes.

1. Go to the **[Discord Developer Portal](https://discord.com/developers/applications)** → top-right **New Application** → enter a name (e.g. `my-agent-bot`) → **Create**.
2. Left sidebar **Bot** tab → **Reset Token** → **copy the token** and keep it somewhere safe.
   - ⚠️ This token is a password. If it's ever exposed, reset it immediately with **Reset Token**.
3. Still under the **Bot** tab, in **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **required** (the bot needs to read message content)
   - ✅ **SERVER MEMBERS INTENT** — recommended (used for role-based permission checks)
   - Enable them and **Save Changes**.
4. Left sidebar **OAuth2** tab → copy the **Client ID (Application ID)** (needed for setup).
5. **Build an invite link** — OAuth2 → **URL Generator**:
   - **Scopes**: `bot`, `applications.commands`
   - **Bot Permissions**: `Manage Channels`, `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Create Public Threads`, `Send Messages in Threads`, `Manage Threads`, `Add Reactions`
   - Paste the generated URL into your browser and **invite it to your server**.
   - (The setup wizard can also generate this invite link for you automatically — see Step 2.)

---

## Step 2 — Install & run

### Keep it running across reboots — macOS (launchd, recommended)

On macOS this is the recommended way. Run the bot directly under **launchd**, the built-in macOS service manager — it starts at login and restarts automatically if it stops. (PM2's fork wrapper can prevent the bot from opening its gateway connection on macOS, so launchd is more reliable there.)

```bash
# 1) Install globally (and run setup once if you haven't)
npm install -g discord-agent-bridge
discord-agent-bridge --setup      # skip if already configured

# 2) Create a launcher wrapper — it finds nvm's default node dynamically,
#    so it keeps working even after you switch node versions.
mkdir -p ~/.discord-agent-bridge
cat > ~/.discord-agent-bridge/run.sh <<'EOF'
#!/bin/bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm use default >/dev/null 2>&1 || nvm use node >/dev/null 2>&1
exec discord-agent-bridge
EOF
chmod +x ~/.discord-agent-bridge/run.sh
# Not using nvm? run.sh can just be `#!/bin/bash` + `exec discord-agent-bridge` (node must be on PATH).

# 3) Create the LaunchAgent ($HOME is expanded to an absolute path as the file is written)
cat > ~/Library/LaunchAgents/com.discord-agent-bridge.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.discord-agent-bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/.discord-agent-bridge/run.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>HOME</key><string>$HOME</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$HOME/.discord-agent-bridge/agent.out.log</string>
    <key>StandardErrorPath</key><string>$HOME/.discord-agent-bridge/agent.err.log</string>
</dict>
</plist>
EOF

# 4) Start it
launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist

# 5) Verify — seeing 'gateway ready' means success (Ctrl+C only exits the log view; the bot keeps running)
tail -f ~/.discord-agent-bridge/agent.out.log
```

Management:

```bash
launchctl list | grep discord-agent-bridge                                # status (col 1 = PID, col 2 = last exit code)
launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist    # stop
launchctl load  -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist  # start
```

Upgrading:

```bash
npm install -g discord-agent-bridge@latest
launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist
launchctl load  -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist
```

> ⚠️ If you switch node versions with nvm, run `npm install -g discord-agent-bridge` once under the new version (nvm keeps global packages per version). The wrapper follows nvm's default node, so the plist itself never needs editing.

### Keep it running across reboots — PM2 (Linux/Windows)

> On macOS, prefer the **launchd** method above. On Linux/Windows, [PM2](https://pm2.keymetrics.io/) is convenient.

Another way to keep the bot running after logout/reboot is [PM2](https://pm2.keymetrics.io/). It gives you logs, restart, and status in one place.

```bash
# 1) Install the bot globally (so PM2 has a stable command to run)
npm install -g discord-agent-bridge

# 2) Run --setup once if you haven't yet
discord-agent-bridge --setup

# 3) Install PM2
npm install -g pm2

# 4) Register the bot with PM2 and start it
pm2 start discord-agent-bridge --name discord-agent-bridge

# 5) Snapshot the current process list (so PM2 knows what to restore on boot)
pm2 save

# 6) Register PM2 to start at boot (on macOS this wires up launchd)
pm2 startup
# ↑ Copy-paste the `sudo ...` command it prints and run it once.
```

Day-to-day management:

```bash
pm2 status                          # is it running?
pm2 logs discord-agent-bridge       # tail logs
pm2 restart discord-agent-bridge    # restart (also do this after upgrading)
pm2 stop discord-agent-bridge       # stop
pm2 delete discord-agent-bridge     # unregister
```

Upgrading under PM2:

```bash
npm install -g discord-agent-bridge@latest
pm2 restart discord-agent-bridge
```

> ⚠️ If you use nvm/asdf, PM2 needs to find the same `node` at boot time as it does in your shell. Verify with `which node` and make sure that path is available to the boot environment — otherwise PM2 may fail to start the bot on reboot.

### Run with npx (quick try)

Use this to spin it up once without installing. `npx` fetches the latest version and runs it; on first run, the setup wizard appears first and the bot starts right after. (Closing the terminal stops the bot — use PM2 above to keep it running.)

```bash
# First run — the setup wizard runs automatically, then the bot starts.
# (asks for your token/Client ID, checks intents, generates an invite link — no other defaults are asked)
npx discord-agent-bridge

# Later runs — if already configured, the bot starts directly.
npx discord-agent-bridge

# To reconfigure only (without starting the bot)
npx discord-agent-bridge --setup
```

Global install also works: `npm install -g discord-agent-bridge`, then `discord-agent-bridge` / `discord-agent-bridge --setup`.

### Upgrading

When a new version is released:

```bash
# npx users — appending @latest always fetches the newest version (npx can otherwise cache).
npx discord-agent-bridge@latest

# Global-install users
npm install -g discord-agent-bridge@latest
```

Check your installed version with: `discord-agent-bridge --version`.

**What the setup wizard (`--setup`) asks for** — the **token (secret) is the only thing you type into the terminal**. Nothing else is asked here:
1. Your Discord bot **token** (secret — paste it only in the terminal)
2. Your **Client ID**
3. Confirmation that Message Content Intent is enabled
4. Generates an invite URL → invite it to your server

> **Roles and defaults are never configured in the terminal.** After inviting the bot to your server, configure them in Discord with the **`/config`** command:
> - **Role tiers** — assign them by **clicking** a role name (no need to copy a role ID or enable Developer Mode). Until assigned, access is **deny-by-default**.
> - **Defaults** — **default backend, model, permission mode, and language (locale)** are saved instantly from a dropdown; the **Codex base path (codexHome)** is set via the "Set Codex Path" button → a text-input modal. Language choices are `한국어 (ko)` / `English (en)`.

Configuration is stored under `~/.discord-agent-bridge/` (token file permissions 600). Per-server roles and defaults are stored in `servers/<guildId>.json`.

---

## Step 3 — Using it in Discord

Once the bot joins a server, it **automatically creates a control channel (`#session-generator`), a sessions category, and a notifications channel (`#agent-status`)** (as long as it has the Manage Channels permission). From there, the flow is: **`/config` → `/agent start`**.

1. **(Automatic)** This channel structure is created when the bot starts or is invited to a server. An admin can also recreate it manually with **`/init`** (existing channels are reused — no duplicates).
2. **`/config`** (admin) → set role tiers and defaults. (Server Administrators can always use the bot, even without an assigned role.)
3. In `#session-generator`, run **`/agent start`** → the **wizard** walks you through, in order:
   **choose a working folder → backend (Claude / Codex) → model → reasoning effort → permission mode**. Each step advances with a **"Next" button**. The folder browser supports **navigating to parent/other volumes, creating new folders, and resuming a previous session**. Once confirmed, a **dedicated session channel (`proj-<folder>`) is created** and bound to it, named after the project folder.
4. In the newly created session channel, **just chat with normal messages**. Claude mode shows streaming output, tool-execution threads, and permission approval buttons.
5. Use the commands below whenever you need them.

### Key commands
| Command | Description |
|---|---|
| `/init` | (admin) Create the control channel + sessions category (reuses them if already present) |
| `/agent start` | Start a new session — creates a dedicated session channel once the wizard is confirmed |
| `/agent resume` | Resume a previous session |
| `/agent close` | End the session and delete its session channel |
| `/agent stats` | View active sessions, session statistics, and Claude usage (visible only to you) |
| `/mode <claude\|codex>` | Switch backend (⚠️ starts a new conversation — prior context is not carried over) |
| `/mode perm <mode\|profile>` | Switch permission mode/profile (session context is preserved) |
| `/stop` | Immediately stop the current session (kill switch) |
| `/stop-all` | (admin) Stop all sessions |
| `/config` | (admin) Configure role tiers + defaults (backend, model, permission mode, language, Codex path) — roles are set by **clicking**, defaults via dropdown/modal |

### Permission modes (how autonomous a session is)
- `default` — confirms every tool execution with **Allow/Deny buttons** (safest)
- `acceptEdits` — file edits are accepted automatically
- `plan` — only plans first, holds off on execution
- `bypassPermissions` — fully automatic (only for projects you trust)

(Codex maps these to the CLI's own approval/sandbox modes.)

### Event notifications (`#agent-status`)

Summarizes **completions and errors** from all your sessions into a single `#agent-status` channel. Toggle it on/off and change the target channel from `/config` → **🔔 Notification Settings**.

---

## Permissions & role setup (important)

This bot runs code **on your machine, with your account's permissions**. That means anyone who can command the bot is effectively **someone who can run commands on your computer** — so role-based access control is essential.

- **3 role tiers** — assign them in Discord via **`/config`** by **clicking** a role name (no role ID or Developer Mode needed). admin ⊇ execute ⊇ read-only:
  - **admin** — manages settings/`stop-all`/`config`
  - **execute** — can start sessions and run commands
  - **read-only** — read access only
  - > `/config` can initially only be opened by someone with **server Administrator** permission (bootstraps even with an empty allow-list); afterward, the admin tier can use it too.
- **Deny-by-default** — anyone not on the allow-list can do nothing. Until you configure it via `/config`, no one can run anything.
- **Per-project access control (ACL)** — restrict a specific project to only the roles/people you designate.
- **Audit log** — who did what and when is recorded in `~/.discord-agent-bridge/audit/`.

> ⚠️ **Security note:** Don't invite the bot to servers you don't trust, and don't grant the execute role too broadly. Access outside the working folder (e.g. `~/.ssh`) is blocked by default.

---

## Claude mode vs. Codex mode

| | Claude mode | Codex mode |
|---|---|---|
| Real-time streaming | ✅ | ❌ (final result only) |
| Tool-execution threads | ✅ | ❌ |
| Permission approval buttons | ✅ | ❌ (replaced by approval/sandbox modes) |
| Session resume | ✅ | ✅ |
| **Usage/limits display** | ✅ (5-hour · weekly · context) | ❌ (Codex CLI limitation) |

### Is this the same as using the terminal?

- **Claude mode** — uses the **same engine** as the `claude` terminal (the official Claude Agent SDK). It reads the project's `.claude/` configuration as-is, so **subagents, skills, hooks, and MCP all behave identically**. The only difference is the **presentation**: input comes from Discord messages, output renders as embeds/threads. (TUI-only slash commands you'd type in the interactive terminal are handled through the SDK's mechanism rather than the TUI's own.)
- **Codex mode** — runs via `codex exec` (non-interactive). It loads the same Codex engine with your config/MCP, and we've **empirically confirmed hooks (SessionStart/UserPromptSubmit/Stop, etc.) fire correctly in non-interactive mode too**. Approval flow is mapped differently than interactive mode, though (see Permission modes above).

### Custom slash commands / skills / plugin commands

Messages you send in a session channel are forwarded to Claude/Codex verbatim, so **commands/skills defined under `.claude/commands/`, `.claude/skills/` (Claude) or `.codex/skills/` (Codex), as well as commands installed by plugins**, work exactly as they do in the terminal — just type `/name` as-is (verified against the real Claude/Codex CLIs). This doesn't conflict with the bot's own Discord slash commands (`/agent`, `/config`, etc.) since it's just a plain text message in a session channel.

---

## Configuration file locations

```
~/.discord-agent-bridge/
├─ config.json            # bot token · Client ID · defaults · limits (permissions 600)
├─ servers/<guildId>.json # per-server role tiers · defaults · channel structure (control/sessions/status) IDs · notification settings (permissions 600)
├─ state.json             # channel↔session bindings (auto-restored after restart)
└─ audit/audit.jsonl      # audit log
```
Configuration is overridden in the order **global → server → project**.

---

## Troubleshooting

- **The bot doesn't respond to messages** → Check that **Message Content Intent** is enabled in the Developer Portal.
- **Slash commands don't show up** → Check that you included the `applications.commands` scope when inviting the bot (registration can take a few minutes).
- **Channel creation fails with a permission error** → Check that the bot has the `Manage Channels` permission.
- **The usage panel doesn't appear** → You need to be **logged in with a Claude Pro/Max subscription** (`~/.claude`). This panel is hidden (as expected) if you're only using an API key.
- **"No authorized role for this actor (fail-secure)."** → The account you signed in with has no role on the allow-list. This is deny-by-default. Fix it with one of these:
  1. **Simplest** — give that account Discord's **server Administrator** permission. Administrators are unconditionally treated as the admin tier and bypass the allow-list.
  2. **Assign a listed role** — in the Discord server's member list, give the account one of the roles that's already tied to a tier under `/config`.
  3. **Add the role to a tier** — from an admin account, open `/config` → **Role tiers** and click the account's role into the tier you want (admin/execute/read-only).

---

## Development

```bash
npm install
npm run dev         # tsx watch (dev mode)
npm run typecheck   # type checking
npm run test        # tests (vitest)
```

## License

MIT
