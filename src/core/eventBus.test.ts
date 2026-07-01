import { describe, it, expect } from 'vitest';
import { EventBus } from './eventBus.js';
import type { AgentEvent } from './contracts.js';

const textEvent = (t: string): AgentEvent => ({ kind: 'text', text: t, delta: false });

describe('EventBus', () => {
  it('delivers an event to a channel listener', () => {
    const bus = new EventBus();
    const got: AgentEvent[] = [];
    bus.on('g1', 'c1', (ev) => got.push(ev));
    bus.emit('g1', 'c1', textEvent('hi'));
    expect(got).toEqual([textEvent('hi')]);
  });

  it('does not leak across channels or guilds', () => {
    const bus = new EventBus();
    const c1: AgentEvent[] = [];
    const c2: AgentEvent[] = [];
    const otherGuild: AgentEvent[] = [];
    bus.on('g1', 'c1', (ev) => c1.push(ev));
    bus.on('g1', 'c2', (ev) => c2.push(ev));
    bus.on('g2', 'c1', (ev) => otherGuild.push(ev));

    bus.emit('g1', 'c1', textEvent('for-c1'));

    expect(c1).toEqual([textEvent('for-c1')]);
    expect(c2).toEqual([]);
    expect(otherGuild).toEqual([]);
  });

  it('fans out to multiple listeners on the same channel', () => {
    const bus = new EventBus();
    const a: AgentEvent[] = [];
    const b: AgentEvent[] = [];
    bus.on('g1', 'c1', (ev) => a.push(ev));
    bus.on('g1', 'c1', (ev) => b.push(ev));
    bus.emit('g1', 'c1', textEvent('x'));
    expect(a).toEqual([textEvent('x')]);
    expect(b).toEqual([textEvent('x')]);
  });

  it('off() stops delivery to that listener only', () => {
    const bus = new EventBus();
    const a: AgentEvent[] = [];
    const b: AgentEvent[] = [];
    const listenerA = (ev: AgentEvent) => a.push(ev);
    bus.on('g1', 'c1', listenerA);
    bus.on('g1', 'c1', (ev) => b.push(ev));

    bus.off('g1', 'c1', listenerA);
    bus.emit('g1', 'c1', textEvent('after-off'));

    expect(a).toEqual([]);
    expect(b).toEqual([textEvent('after-off')]);
  });

  it('the on() return value unsubscribes', () => {
    const bus = new EventBus();
    const got: AgentEvent[] = [];
    const unsub = bus.on('g1', 'c1', (ev) => got.push(ev));
    unsub();
    bus.emit('g1', 'c1', textEvent('nope'));
    expect(got).toEqual([]);
  });

  it('emit to a channel with no listeners is a no-op', () => {
    const bus = new EventBus();
    expect(() => bus.emit('g1', 'c1', textEvent('void'))).not.toThrow();
  });

  it('a listener may unsubscribe itself during dispatch', () => {
    const bus = new EventBus();
    const got: AgentEvent[] = [];
    let unsub = () => {};
    unsub = bus.on('g1', 'c1', (ev) => {
      got.push(ev);
      unsub();
    });
    bus.emit('g1', 'c1', textEvent('first'));
    bus.emit('g1', 'c1', textEvent('second'));
    expect(got).toEqual([textEvent('first')]);
  });
});
