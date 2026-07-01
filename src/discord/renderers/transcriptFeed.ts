import type { AgentEvent } from '../../core/contracts.js';
import type { EditableMessage, MessageChannel } from '../ports.js';
import { chunkMessage } from '../format.js';
import { t } from '../i18n.js';

// Codex progress/result feed (§6, Codex UX — caps transcript/progress). Codex has
// no live token stream or tool threads; instead a compact status line reflects the
// latest `progress` event (editing a single message in place), and the final
// `result.text` posts as normal message(s). For Claude this renderer is skipped
// (its caps route text/thinking to the streamEmbed instead). No discord.js: the
// sink is the MessageChannel port.

export interface TranscriptFeedDeps {
  channel: MessageChannel;
}

export class TranscriptFeedHandler {
  private readonly channel: MessageChannel;
  // The single status message edited in place as progress advances.
  private statusMessage: EditableMessage | null = null;

  constructor(deps: TranscriptFeedDeps) {
    this.channel = deps.channel;
  }

  async handle(ev: Extract<AgentEvent, { kind: 'progress' | 'result' }>): Promise<void> {
    if (ev.kind === 'progress') return this.onProgress(ev);
    return this.onResult(ev);
  }

  private async onProgress(ev: Extract<AgentEvent, { kind: 'progress' }>): Promise<void> {
    const label = ev.label || t('transcript.working');
    const line = ev.detail ? `${label} — ${ev.detail}` : label;
    if (this.statusMessage) {
      await this.statusMessage.edit({ content: line });
    } else {
      this.statusMessage = await this.channel.send({ content: line });
    }
  }

  private async onResult(ev: Extract<AgentEvent, { kind: 'result' }>): Promise<void> {
    if (!ev.text) return;
    for (const chunk of chunkMessage(ev.text)) {
      await this.channel.send({ content: chunk });
    }
  }
}
