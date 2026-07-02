import type { SessionPermMode } from '../../core/contracts.js';
import type { EmbedSpec } from '../ports.js';
import { COLORS } from '../format.js';
import { t } from '../i18n.js';

// Pinned session status (§6, §7.4): mode, cwd, sessionId, active permission mode.
// For Codex — a backend with usagePanel:false — include the single line
// "usage/limits unavailable (Codex CLI limitation)". A pure builder: it returns an
// EmbedSpec; 7b pins the resulting message to the channel.

export interface SessionStatus {
  mode: string; // 'claude' | 'codex' | …
  cwd: string;
  sessionId: string | null;
  permMode: SessionPermMode; // Claude PermMode or a Codex sandbox mode
  // Whether the backend supports the usage/limits panel (Capabilities.usagePanel).
  // When false (Codex), the status shows the "unavailable" line.
  usagePanel: boolean;
}

export function buildStatusEmbed(status: SessionStatus): EmbedSpec {
  const fields: { name: string; value: string; inline?: boolean }[] = [
    { name: t('status.mode'), value: status.mode, inline: true },
    { name: t('status.permMode'), value: t(`perm.${status.permMode}`), inline: true },
    { name: t('status.cwd'), value: '`' + status.cwd + '`' },
    { name: t('status.session'), value: '`' + (status.sessionId ?? '—') + '`' },
  ];
  const embed: EmbedSpec = {
    title: t('status.title'),
    color: COLORS.idle,
    fields,
  };
  if (!status.usagePanel) {
    embed.footer = t('status.usage.codex');
  }
  return embed;
}
