import type { ButtonSpec, ComponentRow } from '../ports.js';
import { t } from '../i18n.js';

// The Chromium install prompt shown at /setup when image rendering is enabled but no
// browser is present yet (design §9.1). custom_id scheme `render-setup:<action>` with
// action ∈ install|decline (no ids needed — the decision is host-wide/global). Mirrors
// the interrupt/permission button conventions (prefix + ':' split).

const CUSTOM_ID_PREFIX = 'render-setup';

export function parseRenderSetupId(customId: string): { action: 'install' | 'decline' } | null {
  const parts = customId.split(':');
  if (parts.length !== 2 || parts[0] !== CUSTOM_ID_PREFIX) return null;
  const action = parts[1];
  if (action !== 'install' && action !== 'decline') return null;
  return { action };
}

export function buildRenderSetupButtons(): ComponentRow {
  const install: ButtonSpec = {
    type: 'button',
    customId: `${CUSTOM_ID_PREFIX}:install`,
    label: t('render.setup.install'),
    style: 'primary',
  };
  const decline: ButtonSpec = {
    type: 'button',
    customId: `${CUSTOM_ID_PREFIX}:decline`,
    label: t('render.setup.decline'),
    style: 'secondary',
  };
  return { components: [install, decline] };
}
