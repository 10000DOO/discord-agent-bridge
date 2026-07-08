import type { ButtonSpec } from '../ports.js';
import { t } from '../i18n.js';

// The "stop" button rendered on a streaming "Responding…" embed (§ interrupt trigger,
// option B). Clicking it cancels the CURRENT turn only — the session/binding/context
// stay alive (terminal-`claude` ESC), distinct from /stop. custom_id scheme:
// `interrupt:<guildId>:<channelId>` so the router can identify the channel to interrupt
// (mirrors permissionButtons' `perm:<reqId>:<action>` convention). guildId/channelId are
// Discord snowflakes (no colons), so splitting on ':' is unambiguous.

const CUSTOM_ID_PREFIX = 'interrupt';

export function buildInterruptId(guildId: string, channelId: string): string {
  return `${CUSTOM_ID_PREFIX}:${guildId}:${channelId}`;
}

// Parse an `interrupt:<guildId>:<channelId>` custom_id. Returns null for a foreign or
// malformed id so a non-interrupt interaction is safely ignored by the caller.
export function parseInterruptId(customId: string): { guildId: string; channelId: string } | null {
  const parts = customId.split(':');
  if (parts.length !== 3 || parts[0] !== CUSTOM_ID_PREFIX) return null;
  const [, guildId, channelId] = parts;
  if (!guildId || !channelId) return null;
  return { guildId, channelId };
}

// The button spec for a channel's interrupt control. `disabled` renders it greyed out
// (used on turn finalize so a stale click cannot fire against an already-finished turn).
export function buildInterruptButton(
  guildId: string,
  channelId: string,
  opts: { disabled?: boolean } = {},
): ButtonSpec {
  return {
    type: 'button',
    customId: buildInterruptId(guildId, channelId),
    label: t('cmd.interrupt.button'),
    style: 'secondary',
    ...(opts.disabled ? { disabled: true } : {}),
  };
}
