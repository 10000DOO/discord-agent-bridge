# Merged Agent-Discord Bot — Design Document

> **One** self-hosted, npx-installable Discord bot — a **single bot (one token) that can join multiple servers** — driving **either Claude Code or Codex** as the agent backend, chosen **per channel** via a **mode** model (like A4D's model picker), with **role-tiered multi-user access**, **permission-mode selection**, a **3-level config hierarchy (global → server → project)**, JSON-file state (no DB), and clean seams for adding new modes and new features.
>
> Status: **DESIGN — awaiting approval.** No code written. References read first-hand: A4D (`/Volumes/SourceCode/Sample/Agent4Discord`), CDC (`/Volumes/SourceCode/Sample/codex-discord-connector`).

---

## 0. How this doc uses the two references

Per the revised brief, the two reference repos are used for **exactly two things**, and their layout/layering/naming are **not** copied:

1. **Integration/connection code** — *how* to drive each backend technically:
   - Claude Code: in-process `query()` from `@anthropic-ai/claude-agent-sdk` (grounded in `A4D/src/sessions/sessionManager.ts:76`).
   - Codex: spawn `codex exec --json` and scrape stdout JSON events (grounded in `CDC/apps/local-agent/src/codexRunner.ts:564`); discover native sessions from `~/.codex` (`CDC/packages/codex-adapter/src/parser.ts:96`).
2. **Feature ideas** — which Discord features to include (tool threads, **permission-mode selection**, streaming embeds, directory browser, file attach, transcript sync, scheduled commands, role allowlist, command policy tiers, **usage/limits panel**).

Everything else — module boundaries, the mode abstraction, state schema, auth placement — is designed fresh for this project.

> **Reference-grounded UX decisions used verbatim below:** (a) A4D's **permission-mode picker** in the session-start UI (`default / acceptEdits / bypassPermissions / plan / dontAsk`, selected via `handlePermModeSelect`, persisted in the embed footer `perm:` field — `A4D/src/interactions/directoryBrowser.ts:403-405,438,515-546`) is adopted as our permission control model (§7A). (b) A4D's **usage panel** — the undocumented Anthropic OAuth usage endpoint (`A4D/src/sessions/usageTracker.ts`) and SDK `query.getContextUsage()` (`A4D/src/sessions/eventHandler.ts:416-419`) — is adopted as our usage/limits feature (§7.4).

---

## 1. Goals & Non-Goals

### Goals
1. **Two first-class modes, one program.** A channel runs in **Claude Code mode** or **Codex mode**. Each mode owns its UX and flow; they are not flattened into one lossy common interface. Shared infrastructure is shared; mode-specific behavior lives in mode handlers.
2. **One bot, multiple servers, per-channel backend.** A **single Discord bot (one token)** joins **multiple servers (guilds)**; the backend (Claude vs Codex) is chosen **per channel** at session creation, exactly like A4D's model picker. State is keyed by `guildId + channelId`, with a per-server config layer (§8). *(Running dedicated per-backend bots on separate tokens is a possible future extension, not a requirement — see Non-Goals.)*
3. **Be better than either reference.** Improving on A4D's and CDC's concrete weaknesses (see §3) is a **core deliverable**, not incidental: role-based auth for *all* input (A4D has none), session survival across restart (A4D loses sessions), a real backend abstraction (CDC has none), hardened Codex event parsing (CDC swallows errors), fail-secure command policy (CDC defaults unknown commands to *allowed*), and dropping the unauthenticated Hub WebSocket entirely (CDC's critical hole).
4. **Role-tiered multi-user.** A config-based Discord role allowlist with **tiers (execute / read-only / admin)** governs who may drive the bot and run commands — applied uniformly to slash commands **and** free-text messages — plus optional **per-project access control** (§7).
5. **Permission control by mode selection.** Dangerous-action control is via a **permission-mode picker** at session start (adopting A4D's model, §7A), a **layered setting** (global/server/project default) that is also switchable mid-session via `/mode`. CommandPolicy tiers remain an additional safety net.
6. **Usage visibility as a core feature — Claude-only.** Show session **cost & token usage**, **context usage**, and **5-hour and weekly limit** remaining — verified **fully feasible for Claude** (A4D already implements all three). For **Codex the usage/limits panel is unsupported** (Codex CLI does not expose limits, and we do **not** promise an approximate context figure); Codex sessions simply state "usage/limits unavailable (Codex CLI limitation)." We reflect this honestly rather than pretend parity (§7.4).
7. **Extensibility as a first-class seam, in two axes:** adding a **new mode** (e.g. Gemini CLI) and adding a **new feature/command** are both clean, documented, low-blast-radius operations.
8. **Self-hosted, multi-server, JSON state.** Runs as one process on the operator's machine; all state in `~/.<name>/*.json`. Migration-friendly (versioned). Config resolves through a 3-level hierarchy (global → server → project, §8).
9. **npx-installable** single package.

### Non-Goals (explicit)
- **No database.** No Prisma, no SQLite-of-our-own. (CDC's Prisma is Hub-only bloat; see §3.) We *read* Codex's own `~/.codex` session DB directly with a **bundled JS/WASM SQLite reader** (no external `sqlite3` binary), where discovery needs it (§7.3).
- **No multi-computer Hub mode.** No control-api, no agent WebSocket, no remote agents. This deletes CDC's most severe security surface (unauthenticated agent registration → remote command execution, `CDC/apps/control-api/src/agentWebSocket.ts:156-171`). *(Multi-**server** is supported by one bot; multi-**computer** is not.)*
- **No multiple bot tokens / dedicated per-backend bots.** The finalized model is **one bot, per-channel backend** (Goal 2). A dedicated Claude-bot + Codex-bot on separate tokens is explicitly **out of scope** for this design; it is noted only as a possible future extension.
- **No cloud service / SaaS.** Runs on the operator's own machine against their own credentials.
- **Not a lowest-common-denominator abstraction.** We deliberately preserve Claude's rich UX rather than degrade it to match Codex.

### Security posture (prominent — read this)
Because the bot **runs agents on the operator's own PC, with the operator's credentials and filesystem access**, any user permitted in **any** connected server can cause code to execute on that machine. With one bot spanning multiple guilds, the blast radius is every guild the bot has joined. Therefore **per-server and per-project role authorization is mandatory, not optional** (deny-by-default; §7). Adding the bot to an untrusted server is equivalent to handing shell access to that server's allowed roles. This constraint drives the auth model (§7), the workspace-confinement baseline (§6), the permission-mode default (§7A), the kill switch and the audit log (§7.5).

---

## 2. High-Level Architecture

The system is **shared core + per-mode handlers**. The core knows nothing about SDKs or CLIs; a mode is the only place that touches a backend. A thin **normalized event contract** flows core→Discord so the Discord layer renders uniformly, and a **capability set** per mode tells the Discord layer *which* renderers to use and which to skip.

```
                             Discord (users, roles, channels, threads, buttons)
                                              │
                 ┌────────────────────────────┼─────────────────────────────┐
                 │                       DISCORD LAYER                        │
                 │  gateway client · interaction router · message router      │
                 │  renderers: stream embeds · tool threads · permission      │
                 │  buttons · transcript feed · diff view · usage panel ·      │
                 │  channel wizard · status/@mention · file dl                 │
                 │  (each renderer is gated by mode Capabilities)             │
                 └───────────▲───────────────────────────────┬───────────────┘
             normalized events (up)                    user turns / commands (down)
                             │                                 │
                 ┌───────────┴─────────────────────────────────▼───────────────┐
                 │                           CORE                                │
                 │  ChannelRegistry (guildId+channelId → mode + session binding) │
                 │  SessionOrchestrator (turn lifecycle, queueing, resume-boot,  │
                 │                       kill switch /stop + stop-all)           │
                 │  EventBus (normalized AgentEvent stream, per channel)         │
                 │  Auth (role tiers + per-project ACL) · CommandPolicy (tiers)  │
                 │  PermissionResolver (mode selection: global→server→project)   │
                 │  ConfigResolver (global → server → project layering)          │
                 │  UsageService (Claude OAuth usage + ctx; Codex: unsupported) │
                 │  AuditLog (who/when/what → JSON file, optional channel)       │
                 │  CommandRouter (namespaced slash + `!` message commands)      │
                 │  StateStore (versioned JSON, atomic writes) · Config          │
                 └───────────▲───────────────────────────────┬───────────────────┘
                    ModeSession events                   start/send/stop/resume
                             │                                 │
        ┌────────────────────┴──────────┐        ┌──────────────┴───────────────────┐
        │   MODE: claude                │        │   MODE: codex                     │
        │   Capabilities:               │        │   Capabilities:                   │
        │    streaming, thinking,       │        │    progress, transcript,          │
        │    toolThreads, fileDiff,     │        │    sessionResume(re-spawn),       │
        │    permissionPrompts,         │        │    (NO permissionPrompts,         │
        │    usagePanel,                │        │     NO toolThreads, NO usagePanel,│
        │    sessionResume(SDK id),     │        │     NO live token stream)         │
        │    fileAttach(MCP)            │        │    permModes→sandbox/approval     │
        │    permModes(SDK)             │        │                                   │
        │   Drives: query() in-process  │        │   Drives: spawn `codex exec`      │
        └──────────────▲────────────────┘        └────────────────▲──────────────────┘
                       │                                            │
             @anthropic-ai/claude-agent-sdk              `codex` CLI subprocess  +  ~/.codex
             (SDK streaming + canUseTool +               (stdout JSON scrape + session discovery
              permissionMode + getContextUsage)           via bundled JS/WASM sqlite reader)

  STATE ON DISK (JSON, no DB):  ~/.<name>/config.json     (token, clientId, GLOBAL defaults, profiles)
                                ~/.<name>/servers/<guildId>.json   (per-server config overrides + auth)
                                ~/.<name>/state.json       (channels → {guildId, mode, sessionId, cwd,
                                                            owner, permMode, profile, project overrides})
                                ~/.<name>/audit/*.jsonl    (append-only audit log: who/when/what)
                                ~/.<name>/logs/            (redacted operational logs)
```

**Key architectural rules**
- The Discord layer depends on **core contracts only** (`AgentEvent`, `Capabilities`, `ModeSession`), never on the SDK or the Codex CLI. A mode is a plugin behind an interface.
- A mode emits a **normalized `AgentEvent` stream** and declares a **`Capabilities`** object. The Discord layer subscribes to the stream and, for each event kind, renders it *only if the capability is present* — this is the sole role of capabilities (per revised brief).
- **One bot spans many guilds.** All state and config are keyed by `guildId + channelId`. There is one gateway client, one interaction/message router; guild context is carried on every inbound event.
- **Config resolves through 3 layers** (`ConfigResolver`): global default → server (guild) override → project override (§8). Every layerable setting (default backend, permission mode, permission profile, model, allowed roles, auto-allow tools, limits) reads through this resolver, never a raw global.
- Auth, command policy, permission-mode resolution, and audit logging live in the core and run **before** any mode is invoked, so a new mode inherits them for free.

---

## 3. Reference Weaknesses → How This Design Improves (mandatory, code-grounded)

Evidence gathered first-hand and cited `path:line`. This table is the project's value proposition.

### 3a. Agent4Discord (Claude bot)

| # | Weakness (evidence) | Severity | Improvement in this design |
|---|---|---|---|
| A1 | **No role-based authorization.** Message handler relays *any* non-bot message to Claude with only a channel-membership check — `bot.ts:99-103`. Slash commands are gated only by `setDefaultMemberPermissions(Administrator)` (`commands/index.ts:25`); permission buttons check only session owner (`permissionHandler.ts:136-139`). | High | Core **Auth** gate on **every** inbound turn and command (§6), config-based role allowlist, applied uniformly to messages *and* slash commands. Deny-by-default. |
| A2 | **Live sessions lost on restart.** Sessions live only in an in-memory `Map` (`sessionManager.ts:38`); `ClientReady` only registers commands (`bot.ts:33-44`) — no rehydrate. `resumeSession()` is user-driven only. Guild JSON stores `sessionId`/`cwd` (`guild.ts:16-24`) but nothing auto-resumes. | High | **Resume-on-boot**: `SessionOrchestrator` reads `state.json` at startup and re-binds each channel to its mode; Claude re-attaches via SDK `resume` id, Codex is stateless-per-turn so simply re-binds. §8. |
| A3 | **`rate_limit_event` emitted but never consumed.** Emitted at `sessionManager.ts:322-326`; no `on('rate_limit')` listener anywhere. Users get no signal when throttled. | Medium | Normalized `error`/`progress` events carry rate-limit info; Discord renders a visible "rate-limited, retrying" notice; orchestrator backs off (§4, §5). |
| A4 | **Turn re-entrancy / message loss.** `sendMessage` resolves a single `resolveNext` with no queue (`sessionManager.ts:206-222`); the message handler calls it on every message (`bot.ts:145`). Two messages during one running turn → the earlier is silently dropped. | Medium | `SessionOrchestrator` maintains a **per-channel turn queue**; messages arriving mid-turn are enqueued (or rejected with a clear notice), never silently lost. §8. |
| A5 | **Unsandboxed file exfiltration.** MCP `attach_file` takes any absolute path (`tools/discordTools.ts:20-23`); the send callback validates only size, not location (`sessionManager.ts:248-276`). An `isPathSafe` helper exists but is unused by the tool. Claude can attach `~/.ssh/id_rsa`, `/etc/passwd`, etc. | High | File-attach and file-download renderers **confine paths to the workspace root** via realpath containment (reusing the hardened equivalent of CDC's `updateCwd`, `policy.ts:527`). §5, §6. |
| A6 | **Zero automated tests.** `find` for `*.test.ts`/`*.spec.ts` → **0 files**. | Medium | Test seam designed in from Phase 1 (Vitest). Core (auth, policy, state, event normalization) and each mode's parser/mapper are unit-tested; CDC already proves this is feasible (29 test files). §10. |
| A7 | **Secret-leak risk in logs.** Full SDK message JSON logged to console (`sessionManager.ts:284`, 500-char slice) — tool outputs may contain secrets. Token stored plaintext at `~/.agent4discord/config.json` (chmod 600 on non-Windows, `config.ts:65-70`). | Low/Med | Central **redacting logger**; never dump raw event payloads at info level. Token file keeps 0600; document Windows ACL guidance. §7. |
| A8 | **Hardcoded operational values.** Model default `'opus'` (`sessionManager.ts:80`); `AUTO_ALLOW_TOOLS` fixed set (`permissionHandler.ts:18`); 60 s permission timeout (`permissionHandler.ts:71,104`); `maxSessionsPerUser` enforced only in the browser path (`directoryBrowser.ts:378`), bypassable via other entry points. | Low | These move to `config.json` with documented defaults; limits enforced centrally in `SessionOrchestrator`, not per-entry-point. §7. |

### 3b. codex-discord-connector (Codex bot)

| # | Weakness (evidence) | Severity | Improvement in this design |
|---|---|---|---|
| C1 | **Unauthenticated Hub WebSocket → remote command execution.** `agentWebSocket.ts` accepts any connection that self-identifies via `agent-hello` with **no token/secret/mTLS** (`apps/control-api/src/agentWebSocket.ts:156-171`); client opens a plain `new WebSocket(wsUrl)` (`agentClient.ts:105`). Any host on the network can register as any `computerId` and receive `run-command` jobs. | **Critical** | **Hub mode is dropped entirely** (non-goal, §1). Single-process, in-machine only. The entire attack surface is removed — no network listener, no agent registry. |
| C2 | **Fragile Codex stdout scraping, silent failures.** `codex exec --json` output is parsed line-by-line and *every* parse error is swallowed: `parseCodexProgressLine` `catch { return null }` (`codexRunner.ts:154`), `parseThreadId` swallows too (`codexRunner.ts:104`). No schema version pin, no validation. A Codex CLI event-schema change silently blanks progress. | High | Codex mode's event mapper is a **small, isolated, unit-tested translation layer** with a **known-schema allowlist + explicit "unrecognized event" telemetry** (logged, surfaced as generic progress, counted) instead of silent drop. Pin/record the tested Codex CLI version in config and warn on mismatch. §4, §11. |
| C3 | **`sqlite3` CLI hard dependency, silently degrades.** Session discovery shells out to the `sqlite3` binary (`parser.ts:336`) and on any failure returns an empty map (`parser.ts` catch). If `sqlite3` is missing, thread state is silently unknown, and archived/sub-agent filtering can wrongly *include* sessions. | High | **Fully resolved, not mitigated:** we **bundle a JS/WASM SQLite reader** as an npm dependency and read `~/.codex/state_*.sqlite` in-process — **no external `sqlite3` install required**. If the read still fails, degrade to index-only discovery **with a visible warning** and treat unknown state as *exclude* (fail-safe), not include. §7.3, §8. |
| C4 | **`--full-auto` hardcoded — no permission surfacing, no operator control of sandbox/approval.** Every Codex invocation passes `--full-auto` (`codexRunner.ts:453,467,480`) plus `--skip-git-repo-check` (`:483`); Codex approves its own actions locally with a fixed policy, nothing reaches Discord and the operator cannot choose a safer sandbox. | Medium | Stop hardcoding `--full-auto`. Map our **permission-mode selection (§7A)** onto **Codex CLI's own approval-policy + sandbox flags** (e.g. sandbox `read-only` / `workspace-write` / `danger-full-access`; approval `untrusted` / `on-request` / `on-failure` / `never`), chosen per channel and layerable. Codex still declares `permissionPrompts: false` (no per-action Discord buttons — honest about C4), but the operator now controls how autonomous Codex is. **Exact flag names MUST be verified against the installed `codex` CLI in Phase 2** (§5b, §7A). CommandPolicy tiers remain an added safety net. |
| C5 | **No real backend abstraction.** Codex logic is spread across `local-agent` + `discord-bot` with no provider interface; adding a backend means editing many files. `runCodexPrompt` is a bespoke function, not an implementation of a contract. | Medium | The **`AgentMode` / `ModeSession` interface** (§4) is the explicit seam. Codex and Claude are two implementations; a third is an additive file (§9). |
| C6 | **Command policy is fail-open.** `classifySingleCommand` returns `normal-mutate` (allowed, no confirm) for **any unknown command** (`policy.ts:446`) — `curl … | bash`, `perl -e …`, arbitrary tools slip through without confirmation. | Medium | Port the classifier but **flip the default to fail-secure**: unknown → `dangerous-mutate` requires confirmation (or explicit allowlist). Keep the (good) shell-scan/quote-aware tokenizer. §6. |
| C7 | **Prisma/DB dependency for a JSON-mode tool.** `@prisma/client` + `prisma/schema.prisma` are root deps used only by Hub mode; Direct mode is pure JSON (`directState.ts:122-182`). Bloat + migration friction. | Low | **No DB at all.** One versioned JSON store (§7). Dropping Hub removes the only Prisma consumer. |
| C8 | **TOCTOU in path guard.** `updateCwd` checks containment then realpaths (`policy.ts:527-549`); a race between check and use exists. Low risk single-user, real under concurrency. | Low | Single-process removes cross-agent concurrency; we resolve realpath **once at use** and pass the resolved path down, narrowing the window. §6. |

**Net:** dropping Hub eliminates C1/C7/C8's severity; the mode abstraction fixes C5; the rest are addressed by hardening the ported connection code (C2/C3/C4/C6) and by giving Claude what it never had (A1/A2/A4/A5).

---

## 4. Project Layout — Recommendation & Justification

### Decision: **single npm package, internal module layout by concern.** Not a pnpm monorepo.

**Why not a monorepo (CDC's shape):** CDC's monorepo exists to support *multi-process, multi-computer* deployment (separate `control-api`, `local-agent`, `discord-bot` apps communicating over HTTP/WS). We have explicitly dropped that (non-goal). A monorepo's per-package `package.json`, cross-package build graph, and workspace tooling would be pure overhead for a single-process, single-artifact tool — a direct violation of the user's *no-overengineering* principle. CDC itself ships from one root `bin` anyway.

**Why not A4D's flat `src/*` either:** A4D's flat layout has no seam between "SDK integration" and "Discord rendering" — they reference each other directly (`eventHandler.ts` imports `sessionManager` and formatters and permission handler). That coupling is exactly why A4D has no backend abstraction. We need a real boundary.

**Chosen layout:** one package, one build, but with a **hard internal dependency rule**: `discord/` and `modes/*` may depend on `core/`; `core/` depends on neither; `modes/*` do not depend on each other or on `discord/`. This gives the two required seams (new mode, new feature) without monorepo machinery. It honors *minimal-change / no-overengineering* while satisfying the explicit *strong dual extensibility* requirement — extensibility comes from the **interface boundary**, not from package fragmentation.

```
merged-agent-discord/                 (single package.json, "bin": { "<name>": "./dist/cli.js" })
├─ package.json
├─ tsconfig.json
├─ vitest.config.ts
└─ src/
   ├─ cli.ts                          entrypoint: `--setup` | run | `--version`
   ├─ app.ts                          wires config → core → discord; boot + resume
   │
   ├─ core/                           ── depends on nothing app-specific ──
   │  ├─ contracts.ts                 AgentMode, ModeSession, Capabilities, PermMode, AgentEvent (THE seam)
   │  ├─ modeRegistry.ts              name → AgentMode factory; single place to register modes
   │  ├─ sessionOrchestrator.ts       turn lifecycle, per-channel queue, resume-on-boot, /stop kill switch
   │  ├─ channelRegistry.ts           guildId+channelId → { mode, sessionId, cwd, ownerId, permMode, profile } binding
   │  ├─ eventBus.ts                  typed pub/sub of AgentEvent per channel
   │  ├─ auth.ts                      role-TIER gate + per-project ACL (evolved from CDC authorizeCommand)
   │  ├─ commandPolicy.ts             tiered classifier (ported + fail-secure default)
   │  ├─ permissionResolver.ts        permission mode + named profiles; layered global→server→project
   │  ├─ configResolver.ts            3-level layering (global → server → project)
   │  ├─ usageService.ts              Claude OAuth usage endpoint + ctx-usage cache/backoff (Codex: n/a)
   │  ├─ auditLog.ts                  append-only who/when/what → audit/*.jsonl (+ optional channel)
   │  ├─ hookBridge.ts                local endpoint receiving agent-hook events → Discord notify
   │  ├─ commandRouter.ts             slash + `!`-prefixed message command parsing/dispatch (incl. /mode /stop)
   │  ├─ state/
   │  │  ├─ store.ts                  versioned JSON, atomic write, migrations
   │  │  └─ schema.ts                 AppState types + zod validation
   │  ├─ config.ts                    config.json + servers/<guildId>.json load/save (0600), zod-validated
   │  └─ logger.ts                    redacting logger
   │
   ├─ modes/                          ── each implements core/contracts, isolated ──
   │  ├─ claude/
   │  │  ├─ index.ts                  ClaudeMode: AgentMode (declares capabilities)
   │  │  ├─ session.ts                wraps query(); maps SDK msgs → AgentEvent
   │  │  ├─ permissions.ts            canUseTool ↔ permission_request events
   │  │  └─ mcpFileTool.ts            in-process MCP attach_file (path-confined)
   │  └─ codex/
   │     ├─ index.ts                  CodexMode: AgentMode (declares capabilities)
   │     ├─ runner.ts                 spawn `codex exec --json` (approval/sandbox flags, not --full-auto)
   │     ├─ eventMapper.ts            stdout JSON → AgentEvent (validated, non-silent)
   │     ├─ sqliteReader.ts           bundled JS/WASM SQLite reader over ~/.codex/state_*.sqlite
   │     └─ discovery.ts              ~/.codex session discovery (bundled-reader; index-only fallback)
   │
   ├─ discord/                        ── depends on core/contracts only ──
   │  ├─ client.ts                    gateway client + intents
   │  ├─ interactionRouter.ts         buttons / selects / modals dispatch
   │  ├─ messageRouter.ts             message → turn (after auth); attachments
   │  ├─ renderers/
   │  │  ├─ index.ts                  subscribes eventBus; dispatches by kind × capability
   │  │  ├─ streamEmbed.ts            live text/thinking embeds        (cap: streaming/thinking)
   │  │  ├─ toolThread.ts             per-tool threads + results       (cap: toolThreads)
   │  │  ├─ permissionButtons.ts      Allow/Always/Deny buttons        (cap: permissionPrompts)
   │  │  ├─ transcriptFeed.ts         Codex progress/result messages   (cap: transcript/progress)
   │  │  ├─ diffView.ts               file-change diff view            (cap: fileDiff, Claude)
   │  │  ├─ usageEmbed.ts             cost/tokens/ctx/5h+weekly panel  (cap: usagePanel, Claude)
   │  │  ├─ statusEmbed.ts            pinned session status (mode + permMode + usage-availability)
   │  │  ├─ mentionOnComplete.ts      @mention the turn owner when a turn finishes
   │  │  └─ resultLine.ts             done-line: cost/tokens/duration  (cap-aware)
   │  ├─ wizard/
   │  │  └─ channelWizard.ts          orchestrates one flow: folder → backend → model → permMode/profile
   │  ├─ directoryBrowser.ts          folder-picker sub-component used by the wizard (cwd selection)
   │  ├─ favorites.ts                 project favorites/bookmarks (saved cwd paths)
   │  ├─ i18n.ts                      Korean-default localizable bot messages (message catalog)
   │  └─ fileDownload.ts              read-only file browser/download (path-confined)
   │
   └─ setup/
      └─ wizard.ts                    interactive first-run config (token, roles, defaults)
```

Feature ideas ported (as *ideas*, re-implemented against contracts): stream embeds, tool threads, permission buttons, **permission-mode picker**, directory browser (folded into the **channel wizard**), MCP file attach, **usage panel** (all A4D); command policy tiers, transcript sync, `~/.codex` discovery, config role allowlist, **audit-event idea**, optional scheduled commands (all CDC).

---

## 5. The Contracts — Mode Interface, Capabilities, Normalized Events

The whole design turns on `src/core/contracts.ts`. This is the seam. Sketch (TypeScript, illustrative — DEV finalizes types):

```ts
// ---- Capabilities: sole purpose is "render only what this mode supports" ----
export interface Capabilities {
  streaming: boolean;          // live token-by-token text deltas
  thinking: boolean;           // extended-thinking stream
  toolThreads: boolean;        // per-tool-call Discord threads + tool results
  permissionPrompts: boolean;  // interactive Allow/Deny before a tool runs (Claude 'default' mode)
  progress: boolean;           // coarse operation-progress ("editing file…")
  transcript: boolean;         // post-hoc message/transcript feed
  sessionResume: boolean;      // can resume a prior session
  fileAttach: boolean;         // agent can push files to the channel
  fileDiff: boolean;           // can surface file-change diffs (Claude)
  usagePanel: boolean;         // supports the usage/limits panel (Claude only; Codex=false)
  permissionModes: PermMode[]; // which permission modes this backend accepts (see below)
}

// Permission modes — Claude uses A4D's set; Codex maps these onto its own
// approval-policy + sandbox flags (VERIFY against installed codex CLI in Phase 2, §7A).
export type PermMode =
  | 'default'            // Claude: interactive canUseTool Allow/Deny buttons
  | 'acceptEdits'        // Claude: auto-approve file edits
  | 'bypassPermissions'  // Claude: auto-approve all  (⚠ dangerous)
  | 'plan'               // Claude: read-only / planning
  | 'dontAsk';           // Claude: no prompts
// Codex-side mapping (illustrative, Phase-2-verified): plan→sandbox:read-only,
// default→approval:on-request, acceptEdits→sandbox:workspace-write,
// bypassPermissions→sandbox:danger-full-access / approval:never.

// ---- Normalized event stream every mode emits (superset union) ----
export type AgentEvent =
  | { kind: 'text';             text: string; delta: boolean }          // delta=true → streaming chunk
  | { kind: 'thinking';         text: string; delta: boolean }
  | { kind: 'tool_use';         id: string; name: string; input: unknown }
  | { kind: 'tool_result';      id: string; ok: boolean; content: string }
  | { kind: 'permission_request'; id: string; toolName: string; input: unknown } // resolved via ctx.resolvePermission
  | { kind: 'progress';         label: string; detail?: string }        // Codex operation-progress
  | { kind: 'result';           text?: string; costUsd?: number; tokensIn?: number; tokensOut?: number; durationMs?: number }
  | { kind: 'context_usage';    totalTokens: number; maxTokens: number; percentage: number }  // Claude: query.getContextUsage()
  | { kind: 'error';            message: string; retryable: boolean; rateLimit?: { resetAt?: string; rateLimitType?: string; utilization?: number } };

export interface PermissionDecision {
  behavior: 'allow' | 'deny';
  message?: string;
}

// ---- A running session for one channel ----
export interface ModeSession {
  readonly sessionId: string | null;            // backend session id (may be null pre-init)
  send(turn: TurnInput): Promise<void>;          // deliver a user turn
  stop(): Promise<void>;                         // abort / terminate
  // Modes that support permissionPrompts call ctx.onPermission (below); Discord resolves it.
}

export interface TurnInput {
  text: string;
  files?: { path: string; mime?: string }[];     // path-confined by core before reaching a mode
}

// ---- The mode plugin: the ONE thing a new backend implements ----
export interface AgentMode {
  readonly name: string;                          // 'claude' | 'codex' | 'gemini' | …
  readonly capabilities: Capabilities;
  start(ctx: ModeContext): Promise<ModeSession>;  // begin a fresh session
  resume(ctx: ModeContext, sessionId: string): Promise<ModeSession>; // rebind existing
  listResumable?(ctx: ModeContext): Promise<ResumableSession[]>;     // for resume UX
}

export interface ModeContext {
  guildId: string;
  channelId: string;
  cwd: string;
  ownerId: string;
  model?: string;
  permMode: PermMode;                             // resolved global→server→project (§7A/§8)
  emit(ev: AgentEvent): void;                     // → EventBus → Discord renderers
  requestPermission(req: { toolName: string; input: unknown }): Promise<PermissionDecision>;
  config: ModeConfigView;                         // resolved (layered) view: model, timeouts, codexHome, etc.
  logger: Logger;
  audit(entry: AuditEntry): void;                 // who/when/what → AuditLog (§7.5)
}
```

### 5a. Claude mode ↦ contract (grounded in A4D)
- `start()` calls `query({ prompt: <async turn stream>, options: { cwd, model, permissionMode, includePartialMessages: true, abortController, canUseTool, mcpServers, allowedTools } })` — the exact shape at `sessionManager.ts:76-89`.
- The SDK async iterable is consumed and mapped to `AgentEvent` (mirrors `sessionManager.ts:279-340` but emitting *normalized* events, not EventEmitter strings):
  - `system/init.session_id` → set `ModeSession.sessionId` (`:290`).
  - `stream_event` content_block_delta `text_delta` / `thinking_delta` → `text`/`thinking` with `delta:true` (mirrors `eventHandler.ts:175-184`).
  - `assistant` `tool_use` blocks → `tool_use` (`eventHandler.ts:239-296`).
  - `user` `tool_result` blocks → `tool_result` (`eventHandler.ts:301-321`).
  - `result` → `result` with `costUsd`/`usage`/`duration_ms` (`:307-313`, `eventHandler.ts:340`).
  - `rate_limit_event` → `error{ retryable:true, rateLimit }` (fixing A3; source `:322-326`).
- `permissionMode` is passed to `query({ options: { permissionMode } })` from the resolved `ctx.permMode` (A4D wires this at `directoryBrowser.ts:612,627`). In `default` mode, `canUseTool` bridges to `ctx.requestPermission(...)` and the Discord Allow/Deny buttons **are** the per-action confirm; return maps to SDK `PermissionResult` (`permissionHandler.ts:196-218`, `:46-119`). Other modes (`acceptEdits`/`bypassPermissions`/`plan`/`dontAsk`) behave per the SDK. Auto-allow-safe and always-allow logic preserved but made config-driven (fixing A8).
- **Usage:** emits `context_usage` via `query.getContextUsage()` (A4D `eventHandler.ts:416-419`); session/limit usage served by the core `UsageService` (§7.4).
- **Capabilities:** `{ streaming, thinking, toolThreads, permissionPrompts:true, progress:false, transcript:false, sessionResume:true, fileAttach:true, fileDiff:true, usagePanel:true, permissionModes:['default','acceptEdits','bypassPermissions','plan','dontAsk'] }`.

### 5b. Codex mode ↦ contract (grounded in CDC)
- Codex is **one-shot per turn**: `send()` spawns `codex exec [resume <id>] --json …` (`codexRunner.ts:447-490,590`), streams stdout, resolves when the process closes. It is **not** a persistent bidirectional session; `sessionId` is captured from the `thread.started` event (`codexRunner.ts:92-110,649`), and a follow-up turn re-spawns with `exec resume <sessionId>`.
- `eventMapper.ts` translates each stdout JSON line to `AgentEvent`, **validated, non-silent** (fixing C2):
  - `agent_message` / `task_complete.last_agent_message` / assistant `response_item` → `text{delta:false}` and final `result` (`codexRunner.ts:161-198`).
  - `item.started`/`item.completed` classified ops → `progress{label,detail}` (`codexRunner.ts:323-435`).
  - Unrecognized `type` → `progress{label:'working…'}` **plus** a counted `logger.debug('unrecognized codex event', type)` — never a silent drop.
- **No `permission_request` ever** — Codex approves its own actions locally (C4). Instead of hardcoding `--full-auto`, the resolved `ctx.permMode` is mapped to **Codex CLI's own approval-policy + sandbox flags** at spawn time (see the `PermMode` mapping in §5; **flag names to be verified against the installed `codex` CLI in Phase 2**). CommandPolicy tiers still run a pre-flight check in core (§6) as a safety net.
- `listResumable()` = `discovery.ts` over `~/.codex` (`parser.ts:96`): index (`session_index.jsonl`), meta (`sessions/*.jsonl` → id/cwd), thread state via the **bundled JS/WASM SQLite reader** over `state_*.sqlite` (**if the read fails → index-only + fail-safe exclude**) (fixing C3).
- **Usage: unsupported.** Codex mode does **not** emit `context_usage` or any limit figures; `usagePanel:false`. The `codex exec --json` stream returns `rate_limits: null` (openai/codex#14728), and although raw token counts are emitted, no context maximum is available — so we deliberately do **not** approximate. Codex session status shows a single line: "usage/limits unavailable (Codex CLI limitation)" (§7.4).
- **Capabilities:** `{ streaming:false, thinking:false, toolThreads:false, permissionPrompts:false, progress:true, transcript:true, sessionResume:true, fileAttach:false, fileDiff:false, usagePanel:false, permissionModes:['default','acceptEdits','bypassPermissions','plan'] (mapped to Codex approval/sandbox; Phase-2-verified) }`.

### 5c. Events Codex simply cannot produce → capability=false
| AgentEvent kind | Claude | Codex | If capability false, Discord does… |
|---|---|---|---|
| `text` streaming delta | yes | no (final only) | Codex: post final text as normal message(s), no live embed |
| `thinking` | yes | no | Codex: nothing |
| `tool_use` / `tool_result` (threads) | yes | no (only coarse `progress`) | Codex: no per-tool threads; show `progress` line in transcript |
| `permission_request` (buttons) | yes (in `default` mode) | no (approves locally) | Codex: no buttons; permission MODE (mapped to Codex sandbox/approval) + core CommandPolicy pre-flight cover dangerous commands |
| `progress` | (has finer stream) | yes | Claude uses tool threads instead |
| `result` cost/tokens | yes | partial (token counts may appear; no cost) | render only fields present |
| `context_usage` / usage panel | yes | **no** (unsupported, Codex CLI limit) | Codex: show "usage/limits unavailable" line, no panel |

---

## 6. The Discord Rendering Layer — per-mode UX via capabilities

`discord/renderers/index.ts` subscribes to the channel's `AgentEvent` stream and, for each event, invokes the matching renderer **only if the mode's capability flag is set**. Renderers are pure consumers of `AgentEvent` — they never touch a backend.

### Claude-mode UX (full-fidelity, preserves A4D)
- **Live streaming embeds** for `text`/`thinking` deltas: debounced editing then finalize to plain chunked text (behavior of `StreamHandler`, `streamHandler.ts`). Cap: `streaming`,`thinking`.
- **Per-tool threads**: each `tool_use` opens a thread named from tool+input; matching `tool_result` posts back (behavior of `eventHandler.ts:239-321`, `toolFormatter.ts`). Cap: `toolThreads`.
- **Permission buttons** (in `default` mode): `permission_request` → Allow / Always-Allow / Deny / Details buttons; the button interaction resolves the pending `PermissionDecision` (behavior of `permissionHandler.ts`, custom_id scheme e.g. `perm:<reqId>:<action>`). Cap: `permissionPrompts`. In non-`default` modes the SDK auto-resolves and no buttons appear.
- **Result line + file-change diff view**: cost/tokens/duration line and auto diff thread on file edits (behavior of `eventHandler.ts:340-462`). Cap: `fileDiff`.
- **Usage/limits panel** (`usageEmbed.ts`): session cost/tokens, `context_usage`, and 5-hour + weekly limits (§7.4). Cap: `usagePanel`.
- **MCP file attach**, **directory browser**, **read-only file download** — path-confined (fixing A5).

### Codex-mode UX (degraded gracefully, honest)
- **No** streaming embeds, **no** thinking, **no** per-tool threads, **no** permission buttons, **no** usage panel (those capabilities are false → renderers skipped).
- **Transcript feed** (`transcriptFeed.ts`): `progress` events become a compact live status line/embed ("editing file X", "running command"); the final `result.text` posts as normal message(s). This is CDC's realtime/on-chat transcript idea (`codexTranscriptSync.ts`), re-implemented against `AgentEvent`.
- **Status embed** (shared) shows mode=Codex, cwd, session id, resumable, **the active permission mode**, and a single line **"usage/limits unavailable (Codex CLI limitation)"**.
- **Permission for Codex — the decision (C4):** we **do not** fake per-action buttons. Control is exercised two ways, both operator-owned:
  1. **Permission mode → Codex approval/sandbox flags.** The resolved permission mode (§7A) maps to the Codex CLI's own approval-policy + sandbox flags at spawn time (replacing hardcoded `--full-auto`), so the operator picks how autonomous Codex is per channel. **Flag mapping verified in Phase 2.**
  2. **CommandPolicy pre-flight safety net.** When a Codex turn is a `!`-prefixed shell command (or a chat turn the policy flags), core classifies it (§6); `dangerous-mutate` requires a coarse confirm gated to an authorized role before spawning.
  3. **In-Codex actions the sandbox still permits are auto-approved** and are **documented as a limitation** in setup + status embed ("Codex mode runs tools within the selected sandbox; use a trusted workspace"). Honest about C4 rather than pretending parity.

### One channel, one mode at a time
A channel is bound to exactly one mode. The status embed always states the active mode **and permission mode** so users are never confused about which UX (or how autonomous a backend) they'll get.

---

## 7. Role-Tiered Auth + Permission Modes + Command Policy

### 7.1 Auth — role tiers + per-project ACL (core/auth.ts)
- **Config-based, no DB.** Roles resolve through the 3-level hierarchy (§8): global default → server override → project override. Three **tiers**:
  - **admin** — setup/admin commands, config edits, stop-all, audit access.
  - **execute** — may start sessions and run turns/commands (the "driver" tier).
  - **read-only** — may view status/transcripts/usage but cannot start sessions or run mutating turns.
- Per-server auth lives in `servers/<guildId>.json`; a project may further narrow access (`allowedRoleIds`/`allowedUserIds`) in the channel binding (§8). Empty allowlist = **deny all (fail-secure)**.
  ```jsonc
  // resolved shape (global defaults, overridable per server / per project)
  "auth": {
    "adminRoleIds":    ["<discordRoleId>", …],   // tier: admin
    "executeRoleIds":  ["<discordRoleId>", …],   // tier: execute
    "readOnlyRoleIds": ["<discordRoleId>", …],   // tier: read-only
    "dmPolicy": "deny"                            // no DM driving by default
  }
  ```
- Evolved from CDC's `authorizeCommand` (`policy.ts:517-525`) and CDC's existing `discord.allowedRoleIds` (`connectConfig.ts:10`). One function `authorize(member, action, {guildId, channelId})` → `{allowed, tier, reason}`.
- **Enforcement point (fixes A1):** `messageRouter` and `interactionRouter` call `authorize()` **before** routing to any turn/command/mode, passing guild+channel so per-server and per-project rules apply. A denied user gets an ephemeral notice; nothing reaches a mode. Uniform across messages and slash commands.
- **Per-project access control:** a channel's project binding may list allowed roles/users; the resolver intersects server-tier grants with the project ACL. This limits which projects a given role can drive — essential given the multi-server security posture (§1).

### 7A. Permission Modes & Profiles (core/permissionResolver.ts) — the primary dangerous-action control
This replaces any single pre-flight "confirm button" as the primary control. Dangerous-action handling is governed by a **permission mode**, adopting **A4D's existing permission-mode picker** in the session-start UI: A4D offers `default / acceptEdits / bypassPermissions / plan / dontAsk`, selected via `handlePermModeSelect` and persisted in the embed footer `perm:` field (`A4D/src/interactions/directoryBrowser.ts:403-405,438,515-546`; wired into `query()` at `:612,627`).

- **Claude mode.** The mode is passed straight to the SDK `permissionMode`. In `default` (interactive) mode, `canUseTool` still surfaces **Allow/Deny buttons** — that *is* the per-action confirm. Other modes behave per the SDK (`acceptEdits` auto-approves edits, `plan` is read-only, `bypassPermissions`/`dontAsk` auto-approve — flagged ⚠ in the picker as A4D does).
- **Codex mode.** Instead of hardcoding `--full-auto` (CDC C4), the mode maps to **Codex CLI's own approval-policy + sandbox flags** — e.g. sandbox `read-only` / `workspace-write` / `danger-full-access`, approval `untrusted` / `on-request` / `on-failure` / `never`. This is a concrete improvement over CDC. **The exact flag names and mode→flag mapping MUST be verified against the installed `codex` CLI during Phase 2** before implementation is trusted.
- **Layered setting + mid-session switch.** Permission mode is a layered default (global → server → project, §8) **and** switchable mid-session via `/mode`. Changing it re-resolves the running session's behavior (Claude: applied on next turn's `query`; Codex: applied on next spawn).
- **Permission profiles** — named presets that bundle *permission mode + allowed tools + policy tier*, defined per project (or inherited). Examples: `읽기전용` (plan / no mutating tools / policy read-only), `수정허용` (acceptEdits / edit+bash allowed / normal), `자동` (bypass/danger sandbox / all tools / relaxed). Selecting a profile sets all three at once; the channel wizard offers profiles as the quick path and raw mode as the advanced path.
- **CommandPolicy tiers remain an additional safety net** (§7.2), independent of the chosen mode.

### 7.2 Command Policy (core/commandPolicy.ts)
- Port CDC's classifier: quote-aware tokenizer + shell scanner + tiers `safe-read | normal-mutate | dangerous-mutate` (`policy.ts:78-466`). Keep the good parts (control-syntax detection, git-push/hard-reset/find-exec/interpreter-eval detection, path-escape detection).
- **Fix C6 (fail-open):** the unknown-command default flips from `normal-mutate` (`policy.ts:446`) to **`dangerous-mutate` requiresConfirmation** — or gate behind an explicit operator-configured allowlist in `config.json.policy.allowExtraCommands`.
- **Composition with modes:** policy is mode-agnostic and runs in core, as a **safety net beneath the permission mode (§7A)**. For Codex it runs a pre-flight classification before spawn (§6); for Claude, `Bash`/`Edit`/`Write` also flow through the SDK `canUseTool` buttons in `default` mode. Policy tiering can additionally auto-deny `dangerous-mutate` in a "read-only" permission profile.

### 7.3 Codex session DB (bundled reader) & secrets
- **C3 fully resolved (not merely mitigated):** we do **not** shell out to an external `sqlite3` CLI binary. Instead we **bundle a JS/WASM SQLite reader as an npm dependency** (`modes/codex/sqliteReader.ts`) and read Codex's session DB (`~/.codex/state_*.sqlite`) directly, so **no separate `sqlite3` install is required**. This turns CDC's fragile "shell out to `sqlite3`, empty map on failure" (`parser.ts:336`) into a first-class, in-process read.
  - **Recommendation:** a pure JS/WASM reader (e.g. `sql.js`) — no native compilation, keeps `npx` install light and cross-platform.
  - **Trade-offs (one-liner each):** built-in `node:sqlite` avoids a dependency but requires a sufficiently recent Node (confirm against our Node target if we set ≥20/≥22); `better-sqlite3` is fastest but is a native module, so install can be heavier/less portable.
  - **Fallback retained as a safety net:** if the reader fails to open the DB, degrade to **index-only** discovery with a visible warning and treat unknown thread state as **exclude** (fail-safe), never include.
- Redacting logger; never log raw event payloads at info level (fixes A7). Config file stays 0600 (`config.ts:68-70`).

### 7.4 Usage & Limits panel (core/usageService.ts) — Claude-only, verified
A dedicated feature. **Feasibility is verified per backend and stated honestly.**

**Claude backend — all three feasible (A4D already implements them):**
- **5-hour remaining and weekly remaining** via the **undocumented Anthropic OAuth usage endpoint** `GET https://api.anthropic.com/api/oauth/usage` (fields `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, each `{utilization: 0-100, resets_at}`). Reference `A4D/src/sessions/usageTracker.ts` (endpoint at `:52`; fields at `:39-42`; 429 backoff at `:175-179`). **Requires OAuth subscription login** (`~/.claude/.credentials.json`), **not** an API key — if only an API key is present, **degrade gracefully and hide the panel**. Values are **utilization %, not raw token remainders** (present as % + reset time). Hardening we add: send a `User-Agent: claude-code/<ver>` header and keep a ~180s cache + 429 backoff to avoid throttling the undocumented endpoint.
- **Context usage (used/max/%)** via SDK `query.getContextUsage()` → `{totalTokens, maxTokens, percentage}` (A4D uses it at `eventHandler.ts:416-419`), surfaced as the `context_usage` AgentEvent.
- **Live refresh signal (bonus):** the SDK also emits `rate_limit_event` (`SDKRateLimitInfo`: status, resetsAt, `rateLimitType` = five_hour|seven_day|…, utilization) — currently **UNWIRED in A4D**. We can wire it to trigger a panel refresh (also fixes A3's dead event).

**Codex backend — usage/limits UNSUPPORTED:**
- 5-hour and weekly: **cannot** be shown — `codex exec --json` returns `rate_limits: null` (verified via openai/codex#14728). Panel states "unavailable for Codex."
- Context usage: **not provided** either. Token counts do appear in the stream (`token_count` / `turn.completed` → `total_token_usage`), but there is no context maximum, so we **deliberately do not approximate** and do not promise a figure. Codex session status shows one line: "usage/limits unavailable (Codex CLI limitation)."
- `usagePanel` capability is therefore `false` for Codex; the `usageEmbed.ts` renderer is skipped.

### 7.5 Kill switch, audit log, workspace confinement
- **Kill switch (core/sessionOrchestrator.ts):** `/stop` aborts the current channel's session (`session.stop()` → Claude `abortController`, Codex kill the spawned process and drain the queue). `/stop-all` (admin tier) stops every active session across all guilds. Both are authorized before acting and audited.
- **Audit log (core/auditLog.ts):** append-only **who / when / what** — actor (userId, roleTier), guild+channel, action (command, tool, turn), permission mode, project (cwd), and outcome — written to `~/.<name>/audit/*.jsonl` (no DB) and **optionally mirrored to a configured Discord channel**. This is CDC's `AuditEvent` idea realized without a database.
- **Workspace folder confinement (baseline, kept from A5/§6):** every file path (attach, download, TurnInput files, diff) is realpath-confined to the session's workspace root. This remains the baseline regardless of permission mode.

### 7.6 Hooks → Discord notifications (core/hookBridge.ts)
Agent hooks (e.g. Claude Code hooks, or Codex equivalents) can post events to Discord. Mechanism: the bot exposes a **small local endpoint** (loopback only, token-guarded) and/or writes a project hook config that forwards events to it; the bridge maps a received event (e.g. "tests failed", "build finished") to a Discord message in the originating channel. This reuses the normalized notification path (it emits into the channel's renderer stream), so no mode changes are needed. Loopback-only binding keeps it off the network (consistent with dropping CDC's Hub, C1).

---

## 8. Config & State Model (JSON, no DB) — 3-level hierarchy

Location: `~/.<name>/` (final name in §11). All files are **versioned** and written atomically (tmp + rename, as `guild.ts:49-51`).

### 8.1 The 3-level hierarchy (global → server → project)
Every layerable setting resolves through `core/configResolver.ts`: **global default** (config.json) → **server (guild) override** (servers/`<guildId>`.json) → **project override** (per-channel binding in state.json). The most specific present value wins; absent levels fall through.

**Layerable settings:** default backend (mode) · permission mode · permission profile · model · allowed roles (auth tiers) · auto-allow tools · limits (sessions/timeouts). Auth allowlists at a narrower level *narrow* access (intersect), they do not widen it.

**`config.json`** — GLOBAL defaults + secrets; 0600:
```jsonc
{
  "version": 2,
  "discord": { "token": "…", "clientId": "…" },        // ONE bot token for all guilds
  "auth": { "adminRoleIds": [], "executeRoleIds": [], "readOnlyRoleIds": [], "dmPolicy": "deny" },
  "defaults": {
    "mode": "claude", "claudeModel": "opus",
    "permissionMode": "default",                        // §7A, layerable
    "permissionProfile": null,                          // named preset, layerable
    "codexHome": "~/.codex", "codexCliCommand": "codex", "codexCliVersion": "x.y.z"
  },
  "limits": { "maxSessionsPerUser": 0, "permissionTimeoutSec": 60, "codexTimeoutMs": 1800000 },
  "policy": { "unknownCommand": "confirm", "allowExtraCommands": [] },
  "autoAllowClaudeTools": ["Read","Glob","Grep"],       // was hardcoded (A8)
  "profiles": {                                         // named permission profiles (§7A)
    "읽기전용": { "permissionMode": "plan",       "allowedTools": ["Read","Glob","Grep"], "policyTier": "read-only" },
    "수정허용": { "permissionMode": "acceptEdits", "allowedTools": ["Read","Edit","Write","Bash"], "policyTier": "normal" },
    "자동":    { "permissionMode": "bypassPermissions", "allowedTools": ["*"], "policyTier": "relaxed" }
  },
  "usage": { "userAgent": "claude-code/<ver>", "cacheSec": 180 },  // §7.4 Claude usage endpoint
  "audit": { "channelId": null },                       // optional Discord mirror (§7.5)
  "locale": "ko",                                       // default Korean, localizable (§11 item 14)
  "favorites": []                                       // global project bookmarks (may also be per-server)
}
```

**`servers/<guildId>.json`** — per-server OVERRIDES (created when the bot joins / is configured for a guild):
```jsonc
{
  "version": 1,
  "guildId": "<discordGuildId>",
  "auth": { "adminRoleIds": [...], "executeRoleIds": [...], "readOnlyRoleIds": [...] },  // server-scoped
  "defaults": { "mode": "codex", "permissionMode": "plan", "permissionProfile": "읽기전용" }, // overrides global
  "limits": { "maxSessionsPerUser": 3 },
  "auditChannelId": null,
  "favorites": []
}
```

**`state.json`** — runtime bindings keyed by guild+channel; enables resume-on-boot (fixes A2):
```jsonc
{
  "version": 2,
  "channels": {
    "<guildId>:<channelId>": {
      "guildId": "<discordGuildId>",
      "mode": "claude" | "codex",
      "sessionId": "…|null",           // Claude SDK id, or Codex ~/.codex thread id
      "cwd": "/abs/workspace",
      "ownerId": "<discordUserId>",
      "permissionMode": "default",      // project-level override (§7A)
      "permissionProfile": null,        // project-level override
      "projectAuth": { "allowedRoleIds": [], "allowedUserIds": [] }, // per-project ACL (§7.1), narrows
      "createdAt": "ISO", "updatedAt": "ISO",
      "archived": false
    }
  },
  "scheduledCommands": []               // optional feature (CDC idea), Phase 4
}
```
- **Migration-friendly:** `store.ts` reads `version`, runs ordered migrations (incl. the v1→v2 rekey `<channelId>` → `<guildId>:<channelId>`), zod-validates (`schema.ts`). Unknown fields tolerated on read, normalized on write (as CDC's `normalizeDirectSyncState`, `directState.ts:91`).
- No Codex session *content* is stored — that lives in Codex's own `~/.codex` and is read on demand by the bundled reader (§7.3). We store only the binding.

---

## 9. Session / Channel Lifecycle

1. **Start (channel-creation wizard).** An authorized (execute-tier) user runs `/agent start` → the **channel wizard** walks one flow: **folder browser (or a saved favorite) → backend (Claude/Codex) → model → permission mode/profile**. Defaults are pre-filled from the resolved hierarchy (global→server). `SessionOrchestrator.start(guildId, channelId, mode, cwd, owner, permMode, profile)` → `modeRegistry.get(mode).start(ctx)`. Binding written to `state.json` under `<guildId>:<channelId>`.
2. **Turn.** A message (after `authorize()` with guild+channel), or `!cmd`, becomes a `TurnInput`. Orchestrator **enqueues** it per channel (fixes A4). Files are path-confined before entering `TurnInput`. Mode `send()` runs; `AgentEvent`s stream to renderers. On turn completion, an optional **@mention** notifies the turn owner. Every turn is audited (§7.5).
   - Claude: one persistent `query()`; the turn feeds the async prompt stream.
   - Codex: one `codex exec` process per turn (approval/sandbox flags per resolved permission mode); `resume <sessionId>` for turns after the first.
3. **Mode / permission switch — at start; switchable mid-session.** `/mode <backend>` switches the backend; `/mode perm <mode|profile>` switches the permission mode/profile. Switching the **backend** rebinds the channel to a fresh backend session (Claude/Codex session ids are not interchangeable), so **context does not carry across a backend switch — DECIDED: allow the switch, show a clear "fresh context" warning** (was an open question, now closed):
   > ⚠️ Codex로 바꾸면 이 채널은 새 대화로 시작돼요. 이전 맥락은 안 넘어갑니다.

   (localized; §11 item 14). Switching only the permission mode/profile keeps the session and applies on the next turn/spawn.
4. **Resume.**
   - **On boot (new):** `app.ts` → `SessionOrchestrator.resumeAll()` reads `state.json`; for each non-archived channel, `mode.resume(ctx, sessionId)`. Claude re-attaches via SDK `resume` (`sessionManager.ts:169`); Codex rebinds (stateless per turn; next turn uses `exec resume`). Fixes A2.
   - **On demand:** `/agent resume` → `mode.listResumable()`; Claude via SDK session list, Codex via `~/.codex` discovery (bundled reader, §7.3).
5. **Stop / archive / delete.** `/stop` → `session.stop()` (kill switch, §7.5), mark archived in `state.json`, optionally archive the Discord channel (A4D auto-archive idea; CDC archive/delete flows). `/stop-all` (admin) stops all sessions across guilds.

---

## 10. Extensibility Playbook (proves both seams)

### Add a new **mode** (e.g. Gemini CLI)
1. Create `src/modes/gemini/` with `index.ts` implementing `AgentMode`: declare `capabilities`, implement `start`/`resume`/`send`.
2. Implement the backend connection (spawn `gemini` CLI or call its SDK) and an `eventMapper` that emits normalized `AgentEvent`s.
3. Register in `core/modeRegistry.ts` (one line).
4. **Done.** No changes to `discord/`, `auth`, `policy`, `state`, or the other modes. Renderers already dispatch by capability; Gemini gets whatever UX its capabilities declare, degrading gracefully for the rest. Add unit tests for its event mapper.

### Add a new **feature/command** (e.g. `/agent stats`)
1. Add the command definition + handler wiring in `core/commandRouter.ts`.
2. If it renders something new, add a renderer in `discord/renderers/` keyed to an existing or new `AgentEvent`/interaction.
3. Auth is automatic (router calls `authorize()` first). No mode edits unless the feature needs a new backend capability — in which case add an optional `Capabilities` flag and have modes opt in.
4. Add tests. Blast radius = the command file + one renderer.

### Add a new **external event source** (e.g. agent hooks → Discord)
1. The hook bridge (`core/hookBridge.ts`, §7.6) receives an event on its loopback endpoint and emits it into the target channel's renderer stream — no mode or Discord-layer change needed for the common case.
2. A new event shape only needs an `AgentEvent` kind + a small renderer. Auth/audit apply automatically.

Both seams are clean because `core/` is the only shared dependency and it depends on **neither** the modes nor Discord specifics.

---

## 11. Feature Catalog (confirmed, mapped to delivery)

Grouped by theme. "Delivered as" notes whether a feature is a former weakness-fix now shipping as a first-class feature. Roadmap phase in brackets.

### Safety
1. **Permission-mode selection** — A4D-style picker (`default/acceptEdits/bypassPermissions/plan/dontAsk`); Claude → SDK `permissionMode`, Codex → mapped approval/sandbox flags. Layered + `/mode` switch. (§7A) [P1 Claude · P2 Codex mapping]
2. **Permission profiles** — named presets bundling permission mode + allowed tools + policy tier (읽기전용 / 수정허용 / 자동), per project. (§7A) [P3]
3. **Kill switch** — `/stop` (session) and `/stop-all` (admin, all guilds). (§7.5) [P1]
4. **Audit log** — who/when/what (command, tool, mode, project) → `audit/*.jsonl`, optional Discord channel; CDC's `AuditEvent` idea, no DB. (§7.5) [P3]
5. **Workspace folder confinement** — realpath-confined file paths, baseline regardless of mode (from A5). (§6/§7.5) [P1]

### Reliability (delivered as features, not just weakness-fixes)
6. **Resume-on-boot** — sessions survive restart (was A2). (§9) [P1]
7. **Per-channel turn queue** — no mid-turn message loss (was A4). (§9) [P1]
8. **Rate-limit notify + backoff/retry** — visible throttle notice, orchestrator backoff (was A3). (§4/§7.4) [P1]

### Usability
9. **Channel-creation wizard** — folder browser → backend → model → permission mode/profile, one flow. (§9, `discord/wizard/channelWizard.ts`) [P1 base · P2 backend step]
10. **Project favorites / bookmarks** — saved frequent project paths, global or per-server. (§8, `discord/favorites.ts`) [P4]
11. **Cost & token usage display** — session cost/tokens on the result line and usage panel (Claude). (§7.4) [P2]
12. **File-change diff view** — Claude edit diffs (`diffView.ts`, cap `fileDiff`). (§6) [P1]
13. **@mention on completion** — ping the turn owner when a turn finishes. (§9, `mentionOnComplete.ts`) [P2]
14. **Korean-localizable bot messages** — default Korean, localizable via a message catalog (`discord/i18n.ts`, `config.locale`). [P1]

### Multi-user
15. **Role-tiered permissions** — execute / read-only / admin. (§7.1) [P1 gate · P3 full]
16. **Per-project access control** — allowed roles/users per project, intersected with server tiers. (§7.1/§8) [P3]

### Extensibility
17. **New backend via the mode interface** — additive `modes/<name>/`, one registry line. (§10) [ongoing]
18. **Hooks → Discord notifications** — loopback bridge forwards agent-hook events (e.g. "tests failed") to a channel. (§7.6) [P4]

### Usage/limits feasibility (honest, verified)
- **Claude:** 5-hour + weekly limits (OAuth usage endpoint, subscription login only), context usage (`getContextUsage()`), optional live refresh via `rate_limit_event`. Fully feasible. (§7.4)
- **Codex:** usage/limits **unsupported** — `rate_limits: null`, no context max; we do not approximate. Session shows "usage/limits unavailable (Codex CLI limitation)." (§7.4)

---

## 12. Phased Roadmap

| Phase | Scope | Deliverable | Rough effort |
|---|---|---|---|
| **1 — Core + Claude (A4D parity+), multi-server** | `core/contracts`, `modeRegistry`, `sessionOrchestrator` (with **turn queue** + **resume-on-boot** + `/stop`), `eventBus`, `configResolver` (3-level), `channelRegistry` (guild+channel keyed), `auth` (tier gate), `state`, `config`, `logger`, `auditLog`; **Claude mode** wrapping `query()` with **permission-mode selection**; **usageService** (Claude OAuth usage + `getContextUsage`); Discord renderers: stream embeds, tool threads, permission buttons, diff view, usage panel, status/result, channel wizard, path-confined file attach/download, i18n (Korean default). Vitest scaffold + core/claude-mapper/usage tests. | Multi-server Claude bot with role tiers, permission modes, resume, usage panel, tests. Fixes A1,A2,A3,A4,A5,A6,A7,A8. | **~3–4 wks** |
| **2 — Codex mode** | `modes/codex/runner` (approval/sandbox flags — **VERIFY codex CLI flags first**, not `--full-auto`), `eventMapper` (validated, non-silent), bundled JS/WASM **sqliteReader** + `discovery` (index-only fallback, fail-safe); transcript-feed renderer; backend step in the wizard; `/mode` backend switch (+ fresh-context warning); resume via `~/.codex`; @mention-on-complete. Tests for mapper + reader + discovery fail-safe. | Per-channel choice of Claude or Codex; graceful degraded UX; Codex usage stated as unavailable. Fixes C2,C3(fully),C4(honest+modes),C5. | **~2–2.5 wks** |
| **3 — Auth hardening + policy + profiles** | Full `commandPolicy` port with **fail-secure default** (C6); permission **profiles**; per-project ACL; per-server auth (`servers/<guildId>.json`); admin/execute/read-only tiers; setup wizard writes global + per-server auth. (Tier gate + audit land in P1; P3 completes policy, profiles, ACL.) | Enforced tiers + profiles + per-project ACL; dangerous ops gated. | **~1.5 wks** |
| **4 — Extras** | Favorites/bookmarks, scheduled commands (CDC idea), hooks→Discord bridge, auto-archive, `/agent stats`, richer resume pickers, docs & README, `npx` publish. | Polished release. | **~1–2 wks** |

Phases 1–3 are the MVP of the *merged* value; Phase 1 alone is already "A4D but safer, multi-server, testable."

---

## 13. Risks & Open Questions

1. **Multi-server blast radius (security).** One bot in many guilds means any allowed role in any guild can run code on the operator's PC (§1). *Mitigation:* deny-by-default role tiers, per-server auth, per-project ACL, workspace confinement, conservative default permission mode, audit log. *Residual:* operator misconfiguration (adding the bot to an untrusted server, granting execute too broadly) — documented as the top setup warning.
2. **Capability mismatch is fundamental, not cosmetic.** Claude = persistent streaming session with surfaced permissions; Codex = one-shot `codex exec` per turn with only post-hoc transcript. The mode model embraces this instead of flattening it. *Risk:* users expecting Claude-grade live/permission/usage UX in Codex mode. *Mitigation:* status embed and setup docs state each mode's UX and limitations explicitly.
3. **Codex permission model (C4) + flag verification.** We map permission modes onto Codex CLI approval/sandbox flags instead of hardcoding `--full-auto`, but we **cannot surface per-action approval**. *Risk:* the assumed flag names/mapping may not match the installed `codex` CLI. *Mitigation:* **verify against the actual CLI in Phase 2** before trusting the mapping; CommandPolicy pre-flight + honest docs ("in-sandbox tool use is autonomous; use a trusted workspace") remain the safety net.
4. **Dependency on an undocumented Anthropic OAuth usage endpoint.** The Claude 5-hour/weekly panel relies on `GET /api/oauth/usage`, which is undocumented and may change or throttle. *Mitigation:* subscription-login-only (hide panel on API-key-only), `User-Agent: claude-code/<ver>` header, ~180s cache + 429 backoff (per A4D `usageTracker.ts:175-179`), graceful degradation if the shape changes. *Residual:* endpoint removal would disable the limit panel (context usage via SDK is unaffected).
5. **Codex limit blindness.** Codex exposes no rate limits (`rate_limits: null`, openai/codex#14728) and no context max, so its usage/limits panel is **unsupported** — we intentionally do not approximate. *Risk:* users may hit Codex limits with no in-Discord warning. *Mitigation:* explicit "usage/limits unavailable (Codex CLI limitation)" line; revisit if the CLI later exposes limits.
6. **Codex CLI / JSON event-schema stability (C2).** The mapper depends on undocumented event shapes (`thread.started`, `item.completed`, `event_msg`, `response_item`). *Mitigation:* isolated validated mapper, `codexCliVersion` recorded in config with a startup mismatch warning, non-silent "unrecognized event" telemetry, mapper unit tests as the change-detector.
7. **Streaming granularity.** Codex yields coarse operation-progress, not token deltas; Claude yields fine deltas. Renderers must not assume deltas exist. Handled by the `streaming`/`progress` capability split.
8. **Codex session DB reader (C3 — resolved).** Now a bundled JS/WASM reader over `~/.codex/state_*.sqlite`, no external `sqlite3` install. *Residual:* the reader dependency adds install weight (mitigated by choosing a pure JS/WASM lib), and Codex's DB layout could change. *Mitigation:* index-only fallback + fail-safe exclusion retained.
9. **Config-hierarchy complexity.** Three layers (global/server/project) plus profiles could confuse operators. *Mitigation:* the wizard shows the *resolved* effective value; `/agent stats`/status embed surfaces where a setting came from.

### Resolved (previously open)
- **Mode-switch context:** DECIDED = **allow switching + clear "fresh context" warning** (see §9, step 3) — no longer open.
- **sqlite3 (C3):** DECIDED = **bundle a JS/WASM reader** (§7.3) — no longer a runtime dependency question.

### Still open (operator decisions)
- **npm name.** `agent4discord` is **taken** (v0.3.0), `codex-discord-connector` taken (v0.1.0). Verified **available** candidates: `discord-agent-bridge`, `agenthub-discord`, `agentbridge-discord`, `discodex`, `polybot-discord`, `agentlink-discord`, `omni-agent-discord`. Recommendation: **`discord-agent-bridge`** — final name is the operator's call.
- **Turn concurrency policy.** Enqueue vs reject mid-turn messages — recommend enqueue with a visible "queued" reaction; confirm desired behavior.
