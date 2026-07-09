import { describe, it, expect } from 'vitest';
import { deliverAnswer } from './answerDelivery.js';
import type { EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';
import type { ImageRenderer } from '../render/segment.js';

// A fake channel recording every send; each send returns an editable message that
// records its edits.
function fakeChannel() {
  const sends: OutgoingMessage[] = [];
  const edits: OutgoingMessage[] = [];
  let seq = 0;
  const channel: MessageChannel = {
    async send(m) {
      sends.push(m);
      return { id: `m${++seq}`, async edit(e) { edits.push(e); } } as EditableMessage;
    },
    async startThread() {
      throw new Error('not used');
    },
  };
  return { channel, sends, edits };
}

// A fake live-embed sink recording the edit that reuses it.
function fakeSink() {
  const edits: OutgoingMessage[] = [];
  const sink: EditableMessage = { id: 'live', async edit(e) { edits.push(e); } };
  return { sink, edits };
}

// A deterministic renderer: renders tables/mermaid to a labeled buffer, or returns null
// for a code that starts with 'FAIL' (to exercise the raw-text fallback).
const fakeRenderer: ImageRenderer = {
  async render(seg) {
    const src = seg.kind === 'table' ? seg.source : seg.code;
    if (src.includes('FAIL')) return null;
    return { data: Buffer.from(`png:${seg.kind}`), name: `${seg.kind}.png` };
  },
};

describe('deliverAnswer', () => {
  it('no renderer → plain chunked text (legacy behavior), first into the sink', async () => {
    const { channel, sends } = fakeChannel();
    const { sink, edits } = fakeSink();
    await deliverAnswer('just text', { channel, firstSink: sink });
    expect(edits).toHaveLength(1);
    expect(edits[0]).toMatchObject({ content: 'just text', embeds: [] });
    expect(sends).toHaveLength(0);
  });

  it('renders a table between prose, preserving order (text → image → text)', async () => {
    const { channel, sends } = fakeChannel();
    const md = 'before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter';
    await deliverAnswer(md, { channel, renderImage: fakeRenderer });
    expect(sends.map((s) => (s.files ? 'IMG' : s.content))).toEqual(['before', 'IMG', 'after']);
    expect(sends[1].files?.[0]).toMatchObject({ name: 'table.png' });
  });

  it('reuses the live embed sink for the FIRST output, sends the rest', async () => {
    const { channel, sends } = fakeChannel();
    const { sink, edits } = fakeSink();
    const md = 'intro\n\n| a |\n|---|\n| 1 |';
    await deliverAnswer(md, { channel, renderImage: fakeRenderer, firstSink: sink });
    // First text goes to the sink (edit); the image is a fresh send.
    expect(edits[0]).toMatchObject({ content: 'intro' });
    expect(sends.map((s) => (s.files ? 'IMG' : s.content))).toEqual(['IMG']);
  });

  it('falls back to raw block text when the renderer returns null', async () => {
    const { channel, sends } = fakeChannel();
    const md = '```mermaid\nFAIL bad diagram\n```';
    await deliverAnswer(md, { channel, renderImage: fakeRenderer });
    expect(sends).toHaveLength(1);
    expect(sends[0].content).toBe('```mermaid\nFAIL bad diagram\n```');
    expect(sends[0].files).toBeUndefined();
  });

  it('carries disabledComponents onto the finalized first (sink) message', async () => {
    const { channel } = fakeChannel();
    const { sink, edits } = fakeSink();
    const disabled = [{ components: [{ type: 'button' as const, customId: 'x', label: 'y', style: 'danger' as const, disabled: true }] }];
    await deliverAnswer('answer', { channel, firstSink: sink, disabledComponents: disabled });
    expect(edits[0].components).toEqual(disabled);
  });
});
