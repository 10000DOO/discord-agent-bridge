import type { ButtonSpec, ComponentRow, EmbedSpec } from '../ports.js';
import { COLORS } from '../format.js';
import { t } from '../i18n.js';

// The update prompt UI (§7): an embed announcing a new version with [Yes]/[No] buttons,
// plus the custom_id codec. custom_id scheme: `dab-update:<action>:<version>` where
// action ∈ approve|dismiss. Versions are semver (dots, no colons) and the prefix/action
// have no colons, so splitting on ':' is unambiguous (mirrors interruptButton /
// permissionButtons). Pure: ports + i18n only, no discord.js, no gateway I/O.

const CUSTOM_ID_PREFIX = 'dab-update';

export type UpdateAction = 'approve' | 'dismiss';

export function buildUpdateId(action: UpdateAction, version: string): string {
  return `${CUSTOM_ID_PREFIX}:${action}:${version}`;
}

// Parse a `dab-update:<action>:<version>` custom_id. Returns null for a foreign prefix,
// an unknown action, or a missing version so a non-update / tampered interaction is
// safely ignored by the caller.
export function parseUpdateId(customId: string): { action: UpdateAction; version: string } | null {
  const parts = customId.split(':');
  if (parts.length !== 3 || parts[0] !== CUSTOM_ID_PREFIX) return null;
  const [, action, version] = parts;
  if (action !== 'approve' && action !== 'dismiss') return null;
  if (!version) return null;
  return { action, version };
}

// The prompt embed + [Yes]/[No] button row for a newly available `version` (the running
// build is `currentVersion`, shown for context).
export function buildUpdatePrompt(
  version: string,
  currentVersion: string,
): { embed: EmbedSpec; rows: ComponentRow[] } {
  const embed: EmbedSpec = {
    title: t('update.title'),
    description: t('update.body', { current: currentVersion, latest: version }),
    color: COLORS.permission,
  };
  const buttons: ButtonSpec[] = [
    { type: 'button', customId: buildUpdateId('approve', version), label: t('update.button.yes'), style: 'success' },
    { type: 'button', customId: buildUpdateId('dismiss', version), label: t('update.button.no'), style: 'secondary' },
  ];
  return { embed, rows: [{ components: buttons }] };
}

// A single DISABLED button row shown after a decision, so the clicked prompt cannot be
// re-clicked. Editing the message with this (a non-empty row) reliably replaces the live
// buttons; an empty component array is dropped by the client's payload builder, which
// would leave the original buttons intact — hence a disabled placeholder instead.
export function buildUpdateDecidedRow(action: UpdateAction): ComponentRow {
  return {
    components: [
      {
        type: 'button',
        customId: `${CUSTOM_ID_PREFIX}:decided`,
        label: action === 'approve' ? t('update.decided.approved') : t('update.decided.dismissed'),
        style: 'secondary',
        disabled: true,
      },
    ],
  };
}
