import type { ComponentRow, EditableMessage, MessageChannel, OutgoingMessage } from '../ports.js';
import type { ImageRenderer } from '../render/segment.js';
import { splitAnswerSegments } from '../render/blockParser.js';
import { chunkMessage } from '../format.js';

// Common answer-delivery helper shared by the three final-text paths (streaming
// finalize, Codex plainText, Claude result-only fallback). Sends the answer in ORDER;
// when an ImageRenderer is injected, GFM tables and ```mermaid``` fences become inline
// PNG attachments in place (text → image → text), otherwise it is byte-for-byte the old
// `chunkMessage` behavior (so existing tests are unaffected).
//
// `firstSink` lets the streaming path reuse its live "Responding…" embed message as the
// FIRST output (edited in place, interrupt button disabled); later outputs are fresh
// sends. Without a sink, everything is a plain send.

export interface DeliverOptions {
  channel: MessageChannel;
  // Absent → text-only (the render branch is off / Chrome unavailable). Present → render.
  renderImage?: ImageRenderer;
  // Streaming live embed to reuse for the first output (edit in place). null/undefined
  // → all outputs are fresh sends.
  firstSink?: EditableMessage | null;
  // Components (the disabled interrupt button) to leave on the finalized first message.
  disabledComponents?: ComponentRow[];
}

function rawTextForBlock(seg: { kind: 'table' | 'mermaid'; source?: string; code?: string }): string {
  return seg.kind === 'mermaid' ? '```mermaid\n' + (seg.code ?? '') + '\n```' : seg.source ?? '';
}

export async function deliverAnswer(text: string, opts: DeliverOptions): Promise<void> {
  const { channel, renderImage, disabledComponents } = opts;
  let sink = opts.firstSink ?? null;

  // Send one payload; the FIRST call reuses the live embed (edit in place, clearing the
  // embed and disabling the interrupt button), the rest are fresh sends. discord.js edit
  // accepts new `files`, so an image can replace the embed without deleting the message.
  const emit = async (payload: OutgoingMessage): Promise<void> => {
    if (sink) {
      const m = sink;
      sink = null;
      await m.edit({
        content: payload.content ?? '',
        embeds: [],
        ...(payload.files ? { files: payload.files } : {}),
        ...(disabledComponents ? { components: disabledComponents } : {}),
      });
      return;
    }
    await channel.send(payload);
  };

  // No renderer → preserve the exact legacy behavior: chunk the whole text, first chunk
  // into the sink (with the disabled button), the rest as follow-up sends.
  if (!renderImage) {
    for (const chunk of chunkMessage(text)) await emit({ content: chunk });
    // Nothing to send (empty answer) but a live embed lingers → clear it.
    if (sink) await sink.edit({ content: '​', embeds: [], components: [] }).catch(() => {});
    return;
  }

  const segs = splitAnswerSegments(text);
  for (const seg of segs) {
    if (seg.kind === 'text') {
      for (const chunk of chunkMessage(seg.text)) await emit({ content: chunk });
      continue;
    }
    const img = await renderImage.render(seg);
    if (img) {
      await emit({ files: [{ path: img.data, name: img.name }] });
    } else {
      // Render skipped/failed → keep the block's original markdown (answer never breaks).
      for (const chunk of chunkMessage(rawTextForBlock(seg))) await emit({ content: chunk });
    }
  }
  if (sink) await sink.edit({ content: '​', embeds: [], components: [] }).catch(() => {});
}
