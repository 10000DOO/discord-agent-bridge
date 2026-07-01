import type { AgentEvent, PermissionDecision } from '../../core/contracts.js';
import type { ButtonSpec, EditableMessage, MessageChannel } from '../ports.js';
import { COLORS, truncate } from '../format.js';
import { t } from '../i18n.js';

// Permission buttons (§6, §5a): a permission_request posts Allow / Always-Allow /
// Deny buttons; the button interaction resolves the pending PermissionDecision.
// custom_id scheme: `perm:<reqId>:<action>` where action ∈ allow|always|deny.
//
// This handler owns the pending map keyed by reqId. 7b wires two directions:
//   - orchestrator.requestPermission → request(reqId, toolName, input) posts the
//     buttons and returns a Promise<PermissionDecision> that resolves when the user
//     clicks; the awaiting orchestrator turn is unblocked by that resolution.
//   - a button interaction → resolve(customId) settles the matching pending promise.
// No discord.js here: the sink is the MessageChannel port; interactions are parsed
// by 7b and handed to resolve() as the raw custom_id string.

const CUSTOM_ID_PREFIX = 'perm';

export type PermAction = 'allow' | 'always' | 'deny';

export function buildCustomId(reqId: string, action: PermAction): string {
  return `${CUSTOM_ID_PREFIX}:${reqId}:${action}`;
}

// Parse a `perm:<reqId>:<action>` custom_id. Returns null for a non-permission id
// or an unknown action, so a foreign interaction is safely ignored by the caller.
export function parseCustomId(customId: string): { reqId: string; action: PermAction } | null {
  const parts = customId.split(':');
  if (parts.length !== 3 || parts[0] !== CUSTOM_ID_PREFIX) return null;
  const [, reqId, action] = parts;
  if (action !== 'allow' && action !== 'always' && action !== 'deny') return null;
  if (!reqId) return null;
  return { reqId, action };
}

interface Pending {
  resolve: (decision: PermissionDecision) => void;
  // The posted buttons message, set once channel.send resolves. Until then a
  // resolve() still settles the decision; only the button-disabling edit is skipped.
  message: EditableMessage | null;
  toolName: string;
}

export interface PermissionButtonsDeps {
  channel: MessageChannel;
}

export class PermissionButtonsHandler {
  private readonly channel: MessageChannel;
  private readonly pending = new Map<string, Pending>();

  constructor(deps: PermissionButtonsDeps) {
    this.channel = deps.channel;
  }

  // Post the buttons for a permission_request and return a promise that settles when
  // the user decides. The pending resolver is registered SYNCHRONOUSLY (before the
  // send completes) so a decision that races the post still resolves; the message
  // handle used to disable the buttons is filled in once send resolves. `ev.id` is
  // the AgentEvent id (stable across the round-trip).
  request(ev: Extract<AgentEvent, { kind: 'permission_request' }>): Promise<PermissionDecision> {
    const entry: Pending = { resolve: () => {}, message: null, toolName: ev.toolName };
    const decision = new Promise<PermissionDecision>((resolve) => {
      entry.resolve = resolve;
    });
    this.pending.set(ev.id, entry);

    const embed = {
      title: t('perm.request.title'),
      description: t('perm.request.body', {
        tool: ev.toolName,
        input: truncate(formatInput(ev.input), 3000),
      }),
      color: COLORS.permission,
    };
    const buttons: ButtonSpec[] = [
      { type: 'button', customId: buildCustomId(ev.id, 'allow'), label: t('perm.button.allow'), style: 'success' },
      { type: 'button', customId: buildCustomId(ev.id, 'always'), label: t('perm.button.always'), style: 'primary' },
      { type: 'button', customId: buildCustomId(ev.id, 'deny'), label: t('perm.button.deny'), style: 'danger' },
    ];
    void this.channel
      .send({ embeds: [embed], components: [{ components: buttons }] })
      .then((message) => {
        // If the user already decided (entry removed), leave the message as-is.
        if (this.pending.get(ev.id) === entry) entry.message = message;
      })
      .catch(() => {});
    return decision;
  }

  // Settle a pending request from a button custom_id. Returns the decision applied,
  // or null if the id is unknown/foreign/already-resolved (idempotent, safe to call
  // on any interaction). Disables the buttons and marks the outcome on resolve.
  async resolve(customId: string): Promise<PermissionDecision | null> {
    const parsed = parseCustomId(customId);
    if (!parsed) return null;
    const entry = this.pending.get(parsed.reqId);
    if (!entry) return null;
    this.pending.delete(parsed.reqId);

    const decision: PermissionDecision =
      parsed.action === 'deny'
        ? { behavior: 'deny', message: 'User denied via Discord' }
        : { behavior: 'allow' };
    const decidedKey =
      parsed.action === 'deny'
        ? 'perm.decided.deny'
        : parsed.action === 'always'
          ? 'perm.decided.always'
          : 'perm.decided.allow';

    // Collapse the prompt: disable buttons and note the outcome so the record is
    // clear and the buttons cannot be re-clicked. If the buttons message has not
    // finished posting yet (a decision that raced the send), skip the edit — the
    // decision still resolves below.
    if (entry.message) {
      await entry.message.edit({
        embeds: [
          {
            title: `${t('perm.request.title')} — ${t(decidedKey)}`,
            description: t('perm.request.body', {
              tool: entry.toolName,
              input: t(decidedKey),
            }),
            color: parsed.action === 'deny' ? COLORS.stopped : COLORS.idle,
          },
        ],
        components: [],
      });
    }

    entry.resolve(decision);
    // `always` is surfaced as allow here; 7b/8 persists the always-allow set into
    // the resolved tool allowlist (config-driven auto-allow, §7A) — not this layer's job.
    return decision;
  }
}

function formatInput(input: unknown): string {
  if (typeof input === 'string') return input;
  try {
    return '```json\n' + JSON.stringify(input, null, 2) + '\n```';
  } catch {
    return String(input);
  }
}
