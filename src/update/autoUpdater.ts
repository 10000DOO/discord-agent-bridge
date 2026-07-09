import type { Logger } from '../core/contracts.js';
import type { InstallResult } from './installer.js';
import { isNewerStable } from './version.js';

// The auto-update orchestrator (§7). It owns scheduling (24h), the check→compare→notify
// flow, the single-flight install+restart, and dismissal — all over injected ports so it
// stays free of Discord, guilds, HTTP, child_process, and disk. app.ts wires the ports;
// interactionRouter drives approve/dismiss from button clicks.

// Default check cadence. Not exposed in config (§14) — intervalMs is a DI seam for tests.
export const DEFAULT_INTERVAL_MS = 24 * 60 * 60 * 1000;

// The persisted update bookkeeping (state.json autoUpdate block).
export interface UpdateMeta {
  lastCheckAt: number;
  dismissedVersion: string | null;
}

// The user-facing strings the orchestrator broadcasts/acknowledges. Resolved once by
// app.ts via i18n (locale is process-global, §14) and injected, so update/ never imports
// the Discord i18n catalog.
export interface UpdateMessages {
  // An approve click while an update is already running.
  busy: string;
  // Install succeeded — about to restart into the new version.
  installed: string;
  // Install failed — points at the manual upgrade path.
  installFailed: string;
  // A dismiss click — this version stays silent until a newer one appears.
  dismissed: string;
}

// The per-click context the router hands to approve/dismiss. Kept discord-free: `ack`
// posts an ephemeral notice to the actor, `disableButtons` collapses the clicked
// prompt's buttons. The router supplies both over the live interaction.
export interface DecisionCtx {
  actorId: string;
  guildId: string;
  channelId: string;
  ack: (text: string) => Promise<void>;
  disableButtons: () => Promise<void>;
}

export interface AutoUpdaterDeps {
  currentVersion: string;
  // Latest value of config.autoUpdate.enabled (read fresh each call).
  enabled: () => boolean;
  intervalMs?: number;
  now?: () => number;
  // Registry probe (null on any failure) — app.ts binds it to fetchLatestVersion.
  fetchLatest: () => Promise<string | null>;
  readMeta: () => UpdateMeta;
  writeMeta: (patch: Partial<UpdateMeta>) => void;
  // Post the prompt (embed + Yes/No buttons) to every guild's status channel.
  postPrompt: (version: string) => Promise<void>;
  // Broadcast a plain status line (install progress / result) to the status channels.
  announce: (text: string) => Promise<void>;
  // Run `npm i -g …@latest`.
  install: () => Promise<InstallResult>;
  // Detect the restart strategy and perform it (exits the process in production).
  restart: () => void;
  messages: UpdateMessages;
  logger: Logger;
}

export class AutoUpdater {
  private readonly deps: AutoUpdaterDeps;
  private readonly intervalMs: number;
  private readonly now: () => number;
  private timer: ReturnType<typeof setInterval> | null = null;
  // Single-flight guard: only the first valid approve runs; the rest get "busy".
  private updating = false;

  constructor(deps: AutoUpdaterDeps) {
    this.deps = deps;
    this.intervalMs = deps.intervalMs ?? DEFAULT_INTERVAL_MS;
    this.now = deps.now ?? Date.now;
  }

  // Start scheduling (§4). No-op when disabled or already started. Runs an immediate
  // check when one is due (survives frequent restarts via lastCheckAt), then repeats on
  // an unref'd interval so it never keeps the process alive on its own.
  start(): void {
    if (this.timer) return;
    if (!this.deps.enabled()) return;
    const due = this.now() - this.deps.readMeta().lastCheckAt >= this.intervalMs;
    if (due) void this.checkNow();
    this.timer = setInterval(() => void this.checkNow(), this.intervalMs);
    this.timer.unref?.();
  }

  // Stop scheduling (App.destroy / tests). Idempotent.
  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  // One check cycle (§4). Never throws: fetch failures are already null, and the notify
  // step is guarded by the caller's port. Re-posts the prompt on EVERY check for a newer
  // stable version until it is dismissed (§14 re-notify policy).
  async checkNow(): Promise<void> {
    if (!this.deps.enabled()) return;
    const latest = await this.deps.fetchLatest();
    // Always advance lastCheckAt (even on a null fetch) so we honor the cadence and do
    // not retry a flaky network before the next interval (§10).
    this.deps.writeMeta({ lastCheckAt: this.now() });
    if (!latest) return;
    if (!isNewerStable(this.deps.currentVersion, latest)) return;
    if (latest === this.deps.readMeta().dismissedVersion) return; // dismissed → silent
    try {
      await this.deps.postPrompt(latest);
    } catch (err) {
      this.deps.logger.warn('auto-update: failed to post prompt', { error: String(err) });
    }
  }

  // Handle a [Yes] click (§4). Single-flight: a second concurrent click is told it is
  // busy. Installs, then — on success — announces and restarts IMMEDIATELY (no drain,
  // §14): the process exits and resumeAll rebinds sessions after the new version boots.
  // On install failure the process is kept on the old version and the guard is released.
  async approve(_version: string, ctx: DecisionCtx): Promise<void> {
    if (this.updating) {
      await ctx.ack(this.deps.messages.busy);
      return;
    }
    this.updating = true;
    await ctx.disableButtons();

    let result: InstallResult;
    try {
      result = await this.deps.install();
    } catch (err) {
      this.deps.logger.error('auto-update: install threw', { error: String(err) });
      await this.deps.announce(this.deps.messages.installFailed);
      this.updating = false;
      return;
    }

    if (!result.ok) {
      this.deps.logger.error('auto-update: install failed', {
        code: result.code,
        stderr: result.stderr.slice(0, 500),
      });
      await this.deps.announce(this.deps.messages.installFailed);
      this.updating = false;
      return;
    }

    await this.deps.announce(this.deps.messages.installed);
    // Immediate restart (§14). In production this exits the process and never returns;
    // the single-flight guard stays set so any racing click is a no-op until exit.
    this.deps.restart();
  }

  // Handle a [No] click (§4): record the dismissed version so it stays silent, collapse
  // the buttons, and acknowledge. A strictly newer version later re-enables notifications
  // automatically (checkNow's dismissedVersion compare).
  async dismiss(version: string, ctx: DecisionCtx): Promise<void> {
    this.deps.writeMeta({ dismissedVersion: version });
    await ctx.disableButtons();
    await ctx.ack(this.deps.messages.dismissed);
  }
}
