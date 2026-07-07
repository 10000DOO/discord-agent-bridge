import { describe, it, expect } from 'vitest';
import { SessionNotifier, formatNotification, resolveNotifications } from './notifier.js';
import { EventBus } from '../core/eventBus.js';
import type { ServerConfig } from '../core/configSchema.js';
import type { AgentEvent } from '../core/contracts.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from './ports.js';

// A fake status-channel sink that records every posted message.
function fakeChannel(): { channel: MessageChannel; sent: OutgoingMessage[] } {
  const sent: OutgoingMessage[] = [];
  const channel: MessageChannel = {
    send: async (message: OutgoingMessage): Promise<EditableMessage> => {
      sent.push(message);
      return { id: `m${sent.length}`, async edit() {} };
    },
    startThread: async () => {
      throw new Error('not used');
    },
  };
  return { channel, sent };
}

const ALL_ON = { result: true, error: true, toolUse: true };

describe('resolveNotifications', () => {
  it('applies defaults for an absent notifications block', () => {
    const server = { version: 1, guildId: 'g1' } as ServerConfig;
    expect(resolveNotifications(server)).toEqual({
      enabled: true,
      channelId: null,
      events: { result: true, error: true, toolUse: false },
    });
  });

  it('falls back channelId to channels.statusChannelId when not set', () => {
    const server = {
      version: 1,
      guildId: 'g1',
      channels: { categoryId: 'a', controlChannelId: 'b', sessionsCategoryId: 'c', statusChannelId: 'status-1' },
    } as ServerConfig;
    expect(resolveNotifications(server).channelId).toBe('status-1');
  });

  it('an explicit channelId override wins over the status channel fallback', () => {
    const server = {
      version: 1,
      guildId: 'g1',
      channels: { categoryId: 'a', controlChannelId: 'b', sessionsCategoryId: 'c', statusChannelId: 'status-1' },
      notifications: { channelId: 'override-2' },
    } as ServerConfig;
    expect(resolveNotifications(server).channelId).toBe('override-2');
  });

  it('honors explicit enabled=false and event flags', () => {
    const server = {
      version: 1,
      guildId: 'g1',
      notifications: { enabled: false, events: { toolUse: true, error: false } },
    } as ServerConfig;
    const r = resolveNotifications(server);
    expect(r.enabled).toBe(false);
    expect(r.events).toEqual({ result: true, error: false, toolUse: true });
  });

  it('resolves a null server to the defaults', () => {
    expect(resolveNotifications(null)).toEqual({
      enabled: true,
      channelId: null,
      events: { result: true, error: true, toolUse: false },
    });
  });
});

describe('formatNotification', () => {
  it('formats a bare result line', () => {
    const ev: AgentEvent = { kind: 'result' };
    expect(formatNotification(ev, 'sess-1', ALL_ON)).toBe('✅ <#sess-1> 완료');
  });

  it('appends tokens / duration / cost only when present', () => {
    const ev: AgentEvent = { kind: 'result', tokensIn: 10, tokensOut: 20, durationMs: 1500, costUsd: 0.03 };
    expect(formatNotification(ev, 'sess-1', ALL_ON)).toBe('✅ <#sess-1> 완료 · 10/20 tok · 1500ms · $0.03');
  });

  it('omits the token segment when only one of in/out is present', () => {
    const ev: AgentEvent = { kind: 'result', tokensIn: 10, durationMs: 500 };
    expect(formatNotification(ev, 'sess-1', ALL_ON)).toBe('✅ <#sess-1> 완료 · 500ms');
  });

  it('formats an error line', () => {
    expect(formatNotification({ kind: 'error', message: 'boom', retryable: true }, 'sess-1', ALL_ON)).toBe(
      '❌ <#sess-1> 에러: boom',
    );
  });

  it('caps a long error message so the line stays under Discord’s 2000-char limit', () => {
    const line = formatNotification(
      { kind: 'error', message: 'x'.repeat(3000), retryable: true },
      'sess-1',
      ALL_ON,
    )!;
    expect(line.length).toBeLessThan(2000);
    // The message segment is capped at 500 chars.
    expect(line).toMatch(/^❌ <#sess-1> 에러: x{500}$/);
  });

  it('formats a rate_limit line with utilization and reset time', () => {
    // Fixed epoch → deterministic HH:mm in ko-KR locale (24h).
    const resetAt = new Date(1000 * 1000).toISOString();
    const expectedHHmm = new Date(1000 * 1000).toLocaleTimeString('ko-KR', {
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    });
    const line = formatNotification(
      { kind: 'rate_limit', utilization: 87, resetAt, rateLimitType: 'five_hour' },
      'sess-1',
      ALL_ON,
    );
    expect(line).toBe(`📊 <#sess-1> 사용량 한도 · 5시간 한도 · 사용량 87% · 리셋 ${expectedHHmm}`);
  });

  it('rate_limit falls back to the bare line when utilization/resetAt are absent', () => {
    expect(formatNotification({ kind: 'rate_limit' }, 'sess-1', ALL_ON)).toBe('📊 <#sess-1> 사용량 한도');
  });

  it('rate_limit shows all snapshot windows (multi-window, no reset → deterministic)', () => {
    const line = formatNotification(
      { kind: 'rate_limit', rateLimitType: 'five_hour' },
      'sess-1',
      ALL_ON,
      { fetchedAt: 0, fiveHour: { utilization: 26 }, sevenDay: { utilization: 41 } },
    );
    expect(line).toBe('📊 <#sess-1> 사용량 한도 · 5시간 26% · 주간 41%');
  });

  it('rate_limit omits % when no usage snapshot is available (label still shown, no crash)', () => {
    expect(formatNotification({ kind: 'rate_limit', rateLimitType: 'five_hour' }, 'sess-1', ALL_ON, null)).toBe(
      '📊 <#sess-1> 사용량 한도 · 5시간 한도',
    );
    expect(
      formatNotification({ kind: 'rate_limit', rateLimitType: 'seven_day' }, 'sess-1', ALL_ON, {
        available: false,
        reason: 'no-credentials',
      }),
    ).toBe('📊 <#sess-1> 사용량 한도 · 주간 한도');
  });

  it('rate_limit shows the snapshot window over the event util when a snapshot exists', () => {
    // Snapshot present → full-window view; the event's own util (50) is not used.
    const line = formatNotification(
      { kind: 'rate_limit', rateLimitType: 'five_hour', utilization: 50 },
      'sess-1',
      ALL_ON,
      { fetchedAt: 0, fiveHour: { utilization: 99 } },
    );
    expect(line).toBe('📊 <#sess-1> 사용량 한도 · 5시간 99%');
  });

  it('rate_limit is gated by the events.error filter (per minimal-change decision)', () => {
    expect(
      formatNotification({ kind: 'rate_limit', utilization: 50 }, 'sess-1', {
        result: true,
        error: false,
        toolUse: true,
      }),
    ).toBeNull();
  });

  it('formats a tool_use line only when toolUse is enabled', () => {
    const ev: AgentEvent = { kind: 'tool_use', id: 't1', name: 'Bash', input: {} };
    expect(formatNotification(ev, 'sess-1', ALL_ON)).toBe('🔧 <#sess-1> Bash');
    expect(formatNotification(ev, 'sess-1', { result: true, error: true, toolUse: false })).toBeNull();
  });

  it('returns null for a filtered-off result/error and for un-summarized kinds', () => {
    expect(formatNotification({ kind: 'result' }, 'sess-1', { result: false, error: true, toolUse: true })).toBeNull();
    expect(
      formatNotification({ kind: 'error', message: 'x', retryable: false }, 'sess-1', {
        result: true,
        error: false,
        toolUse: true,
      }),
    ).toBeNull();
    expect(formatNotification({ kind: 'text', text: 'hi', delta: false }, 'sess-1', ALL_ON)).toBeNull();
    expect(formatNotification({ kind: 'thinking', text: 'hmm', delta: true }, 'sess-1', ALL_ON)).toBeNull();
  });
});

describe('SessionNotifier', () => {
  it('posts result + error summaries to the status channel; ignores text', async () => {
    const { channel, sent } = fakeChannel();
    const bus = new EventBus();
    const notifier = new SessionNotifier({
      statusChannel: channel,
      sessionChannelId: 'sess-1',
      events: { result: true, error: true, toolUse: false },
    });
    notifier.subscribe(bus, 'g1', 'sess-1');

    bus.emit('g1', 'sess-1', { kind: 'text', text: 'streaming…', delta: true });
    bus.emit('g1', 'sess-1', { kind: 'result', tokensIn: 5, tokensOut: 6 });
    bus.emit('g1', 'sess-1', { kind: 'error', message: 'nope', retryable: false });
    await Promise.resolve();

    expect(sent.map((m) => m.content)).toEqual([
      '✅ <#sess-1> 완료 · 5/6 tok',
      '❌ <#sess-1> 에러: nope',
    ]);
  });

  it('skips tool_use unless toolUse is enabled', async () => {
    const { channel, sent } = fakeChannel();
    const bus = new EventBus();
    const notifier = new SessionNotifier({
      statusChannel: channel,
      sessionChannelId: 'sess-1',
      events: { result: false, error: false, toolUse: true },
    });
    notifier.subscribe(bus, 'g1', 'sess-1');

    bus.emit('g1', 'sess-1', { kind: 'tool_use', id: 't1', name: 'Edit', input: {} });
    bus.emit('g1', 'sess-1', { kind: 'result' }); // result off → not forwarded
    await Promise.resolve();

    expect(sent.map((m) => m.content)).toEqual(['🔧 <#sess-1> Edit']);
  });

  it('stops posting after unsubscribe', async () => {
    const { channel, sent } = fakeChannel();
    const bus = new EventBus();
    const notifier = new SessionNotifier({
      statusChannel: channel,
      sessionChannelId: 'sess-1',
      events: { result: true, error: true, toolUse: false },
    });
    const unsub = notifier.subscribe(bus, 'g1', 'sess-1');

    bus.emit('g1', 'sess-1', { kind: 'result' });
    await Promise.resolve();
    const before = sent.length;
    unsub();
    bus.emit('g1', 'sess-1', { kind: 'result' });
    await Promise.resolve();
    expect(sent.length).toBe(before);
  });

  it('backfills the rate_limit % from getUsage when posting', async () => {
    const { channel, sent } = fakeChannel();
    const bus = new EventBus();
    const notifier = new SessionNotifier({
      statusChannel: channel,
      sessionChannelId: 'sess-1',
      events: { result: true, error: true, toolUse: false },
      getUsage: () => ({ fetchedAt: 0, fiveHour: { utilization: 73 } }),
    });
    notifier.subscribe(bus, 'g1', 'sess-1');

    bus.emit('g1', 'sess-1', { kind: 'rate_limit', rateLimitType: 'five_hour' });
    await Promise.resolve();

    expect(sent.map((m) => m.content)).toEqual(['📊 <#sess-1> 사용량 한도 · 5시간 73%']);
  });
});
