// Turn-scoped idle watchdog: arm on turn accept, reset on any AgentEvent activity,
// stop on result/error/dispose. After IDLE_MS without activity, post t('watchdog.idle') once.

import type { MessageChannel } from './ports.js';
import { t } from './i18n.js';

export const IDLE_WATCHDOG_MS = 3 * 60 * 1000; // 3 minutes

export interface IdleWatchdogDeps {
  channel: MessageChannel;
  // default IDLE_WATCHDOG_MS; injectable for tests
  timeoutMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  logger?: {
    debug?: (message: string, ...meta: unknown[]) => void;
    warn?: (message: string, ...meta: unknown[]) => void;
  };
}

export class IdleWatchdog {
  private readonly channel: MessageChannel;
  private readonly timeoutMs: number;
  private readonly setTimer: (fn: () => void, ms: number) => unknown;
  private readonly clearTimer: (handle: unknown) => void;
  private readonly logger?: IdleWatchdogDeps['logger'];

  private armed = false;
  private fired = false;
  private timer: unknown = null;

  constructor(deps: IdleWatchdogDeps) {
    this.channel = deps.channel;
    this.timeoutMs = deps.timeoutMs ?? IDLE_WATCHDOG_MS;
    this.setTimer = deps.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearTimer = deps.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
    this.logger = deps.logger;
  }

  // Start/restart watch for a new turn; clears the fired flag so a prior notice
  // does not block a fresh idle period.
  arm(): void {
    this.armed = true;
    this.fired = false;
    this.resetTimer();
  }

  // Reset the idle timer when any non-terminal AgentEvent arrives. No-op if not
  // armed or if the notice has already fired for this arm.
  noteActivity(): void {
    if (!this.armed || this.fired) return;
    this.resetTimer();
  }

  // Cancel the timer and leave idle (call on result/error/detach).
  stop(): void {
    this.armed = false;
    this.clear();
  }

  // Alias of stop for dispose-style call sites.
  dispose(): void {
    this.stop();
  }

  private clear(): void {
    if (this.timer != null) {
      this.clearTimer(this.timer);
      this.timer = null;
    }
  }

  private resetTimer(): void {
    this.clear();
    this.timer = this.setTimer(() => {
      this.onFire();
    }, this.timeoutMs);
  }

  // Fire at most once per arm. Best-effort channel send; never throws from the
  // timer callback so a bad sink cannot crash the process.
  private onFire(): void {
    try {
      if (this.fired || !this.armed) return;
      this.fired = true;
      this.clear();
      void this.channel.send({ content: t('watchdog.idle') }).catch((err: unknown) => {
        this.logger?.warn?.('idle watchdog send failed', { err: String(err) });
      });
    } catch (err) {
      this.logger?.warn?.('idle watchdog fire failed', { err: String(err) });
    }
  }
}
