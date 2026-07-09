import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { AutoUpdater, type AutoUpdaterDeps, type DecisionCtx, type UpdateMeta } from './autoUpdater.js';
import type { InstallResult } from './installer.js';
import type { Logger } from '../core/contracts.js';

const silentLogger: Logger = { debug() {}, info() {}, warn() {}, error() {} };

const MESSAGES = {
  busy: 'busy',
  installed: 'installed',
  installFailed: 'install-failed',
  dismissed: 'dismissed',
};

interface Harness {
  updater: AutoUpdater;
  meta: UpdateMeta;
  posts: string[];
  announces: string[];
  installCalls: number;
  restartCalls: number;
  setInstall: (fn: () => Promise<InstallResult>) => void;
  now: { value: number };
}

function makeUpdater(over: Partial<AutoUpdaterDeps> = {}): Harness {
  const meta: UpdateMeta = { lastCheckAt: 0, dismissedVersion: null };
  const posts: string[] = [];
  const announces: string[] = [];
  const now = { value: 1_000_000 };
  const state = { installCalls: 0, restartCalls: 0, install: async (): Promise<InstallResult> => ({ ok: true, code: 0, stderr: '' }) };

  const deps: AutoUpdaterDeps = {
    currentVersion: '1.0.0',
    enabled: () => true,
    now: () => now.value,
    fetchLatest: async () => '1.1.0',
    readMeta: () => meta,
    writeMeta: (patch) => Object.assign(meta, patch),
    postPrompt: async (v) => void posts.push(v),
    announce: async (t) => void announces.push(t),
    install: () => {
      state.installCalls += 1;
      return state.install();
    },
    restart: () => {
      state.restartCalls += 1;
    },
    messages: MESSAGES,
    logger: silentLogger,
    ...over,
  };

  const updater = new AutoUpdater(deps);
  return {
    updater,
    meta,
    posts,
    announces,
    get installCalls() {
      return state.installCalls;
    },
    get restartCalls() {
      return state.restartCalls;
    },
    setInstall: (fn) => {
      state.install = fn;
    },
    now,
  };
}

function makeCtx(): DecisionCtx & { acks: string[]; disabled: number } {
  const acks: string[] = [];
  let disabled = 0;
  return {
    actorId: 'admin-1',
    guildId: 'g1',
    channelId: 'c1',
    ack: async (t) => void acks.push(t),
    disableButtons: async () => {
      disabled += 1;
    },
    acks,
    get disabled() {
      return disabled;
    },
  };
}

describe('AutoUpdater.checkNow', () => {
  it('skips entirely when disabled', async () => {
    const h = makeUpdater({ enabled: () => false });
    await h.updater.checkNow();
    expect(h.posts).toEqual([]);
    // lastCheckAt is NOT advanced when the whole feature is off.
    expect(h.meta.lastCheckAt).toBe(0);
  });

  it('posts the prompt for a newer stable version', async () => {
    const h = makeUpdater();
    await h.updater.checkNow();
    expect(h.posts).toEqual(['1.1.0']);
    expect(h.meta.lastCheckAt).toBe(1_000_000);
  });

  it('re-posts on EVERY check until dismissed (no one-shot gate)', async () => {
    const h = makeUpdater();
    await h.updater.checkNow();
    await h.updater.checkNow();
    await h.updater.checkNow();
    expect(h.posts).toEqual(['1.1.0', '1.1.0', '1.1.0']);
  });

  it('does not prompt when latest is not newer', async () => {
    const h = makeUpdater({ fetchLatest: async () => '1.0.0' });
    await h.updater.checkNow();
    expect(h.posts).toEqual([]);
    // lastCheckAt still advances (a successful check happened).
    expect(h.meta.lastCheckAt).toBe(1_000_000);
  });

  it('stays silent for a dismissed version', async () => {
    const h = makeUpdater();
    h.meta.dismissedVersion = '1.1.0';
    await h.updater.checkNow();
    expect(h.posts).toEqual([]);
  });

  it('advances lastCheckAt and skips on a null fetch (offline)', async () => {
    const h = makeUpdater({ fetchLatest: async () => null });
    await h.updater.checkNow();
    expect(h.posts).toEqual([]);
    expect(h.meta.lastCheckAt).toBe(1_000_000);
  });
});

describe('AutoUpdater.approve', () => {
  it('installs then announces + restarts on success (no drain)', async () => {
    const h = makeUpdater();
    const ctx = makeCtx();
    await h.updater.approve('1.1.0', ctx);
    expect(ctx.disabled).toBe(1);
    expect(h.installCalls).toBe(1);
    expect(h.announces).toEqual([MESSAGES.installed]);
    expect(h.restartCalls).toBe(1);
  });

  it('single-flight: a concurrent second approve is told busy and does not re-install', async () => {
    const h = makeUpdater();
    // Hold the first install open so the second approve races it.
    let release!: () => void;
    h.setInstall(() => new Promise<InstallResult>((r) => (release = () => r({ ok: true, code: 0, stderr: '' }))));

    const ctx1 = makeCtx();
    const ctx2 = makeCtx();
    const first = h.updater.approve('1.1.0', ctx1);
    await h.updater.approve('1.1.0', ctx2); // sees updating=true → busy

    expect(ctx2.acks).toEqual([MESSAGES.busy]);
    expect(h.installCalls).toBe(1);

    release();
    await first;
    expect(h.restartCalls).toBe(1);
  });

  it('install failure: announces failure, releases the guard, does NOT restart', async () => {
    const h = makeUpdater();
    h.setInstall(async () => ({ ok: false, code: 1, stderr: 'EACCES' }));
    const ctx = makeCtx();
    await h.updater.approve('1.1.0', ctx);
    expect(h.announces).toEqual([MESSAGES.installFailed]);
    expect(h.restartCalls).toBe(0);

    // Guard released → a later approve can retry (install called again).
    h.setInstall(async () => ({ ok: true, code: 0, stderr: '' }));
    await h.updater.approve('1.1.0', makeCtx());
    expect(h.installCalls).toBe(2);
    expect(h.restartCalls).toBe(1);
  });

  it('a thrown install is caught: failure announced, guard released, no restart', async () => {
    const h = makeUpdater();
    h.setInstall(async () => {
      throw new Error('boom');
    });
    const ctx = makeCtx();
    await h.updater.approve('1.1.0', ctx);
    expect(h.announces).toEqual([MESSAGES.installFailed]);
    expect(h.restartCalls).toBe(0);
  });
});

describe('AutoUpdater.dismiss', () => {
  it('records the dismissed version, disables buttons, acks, and does not restart', async () => {
    const h = makeUpdater();
    const ctx = makeCtx();
    await h.updater.dismiss('1.1.0', ctx);
    expect(h.meta.dismissedVersion).toBe('1.1.0');
    expect(ctx.disabled).toBe(1);
    expect(ctx.acks).toEqual([MESSAGES.dismissed]);
    expect(h.restartCalls).toBe(0);
  });

  it('a later check for the dismissed version stays silent', async () => {
    const h = makeUpdater();
    await h.updater.dismiss('1.1.0', makeCtx());
    await h.updater.checkNow();
    expect(h.posts).toEqual([]);
  });
});

describe('AutoUpdater.start / stop', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('runs an immediate check when due, then schedules the interval', async () => {
    const h = makeUpdater({ intervalMs: 1000 });
    h.now.value = 10_000; // now - lastCheckAt(0) >= interval → due
    h.updater.start();
    await vi.advanceTimersByTimeAsync(0); // flush the immediate checkNow microtasks
    expect(h.posts).toEqual(['1.1.0']);

    await vi.advanceTimersByTimeAsync(1000); // one interval tick → another check
    expect(h.posts).toEqual(['1.1.0', '1.1.0']);

    h.updater.stop();
    await vi.advanceTimersByTimeAsync(5000);
    expect(h.posts).toEqual(['1.1.0', '1.1.0']); // no more ticks after stop
  });

  it('does not run an immediate check when not due', async () => {
    const h = makeUpdater({ intervalMs: 1000 });
    h.meta.lastCheckAt = 10_000;
    h.now.value = 10_500; // within the interval → not due
    h.updater.start();
    await vi.advanceTimersByTimeAsync(0);
    expect(h.posts).toEqual([]);
    h.updater.stop();
  });

  it('does not schedule when disabled', async () => {
    const h = makeUpdater({ enabled: () => false, intervalMs: 1000 });
    h.now.value = 10_000;
    h.updater.start();
    await vi.advanceTimersByTimeAsync(5000);
    expect(h.posts).toEqual([]);
  });
});
