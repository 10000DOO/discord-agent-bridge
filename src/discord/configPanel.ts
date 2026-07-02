import type { PermMode } from '../core/contracts.js';
import type { ConfigStore } from '../core/config.js';
import { CONFIG_VERSION, type ServerConfig } from '../core/configSchema.js';
import type { Locale } from './i18n.js';
import type { ButtonSpec, ComponentRow, EmbedSpec, RoleSelectSpec, SelectSpec } from './ports.js';
import { t } from './i18n.js';

// The `/config` panel (§7.1/§8): configure a guild's role tiers and defaults by
// CLICKING role names (Discord Role Select menus) instead of pasting role IDs.
// Everything the panel needs is plain data — no discord.js here — so the router
// and tests drive it directly; the client.ts adapter maps RoleSelectSpec onto a
// discord.js RoleSelectMenuBuilder and multi-select values onto ComponentInteraction.
//
// Persistence target: per-server servers/<guildId>.json (roles are per-guild, §7.1).
//
// Two persistence styles coexist so the panel stays within Discord's 5-action-row
// limit per message (the primary reply and a follow-up):
//   - Role tiers (3 role-selects) batch into a pending set and persist together on
//     the Save button — they share the primary message (3 selects + Save = 4 rows).
//   - Defaults (backend / model / permMode / locale selects) AUTO-SAVE on each
//     change: one changed field is written immediately. This lets the defaults
//     follow-up hold 4 selects = 4 rows with no Save button — respecting the budget.
//
// Codex home is NOT configured here: it resolves automatically to `~/.codex` (like
// Claude's `~/.claude`) via the config default / resolveCodexHome. The actual PROJECT
// folder is chosen per-session in the `/agent start` wizard, not in /config.

// The panel component ids. `config.` prefix lets the router recognize + route them.
export const CONFIG_PANEL_PREFIX = 'config.';

const IDS = {
  roleAdmin: 'config.role.admin',
  roleExecute: 'config.role.execute',
  roleReadOnly: 'config.role.readOnly',
  backend: 'config.default.backend',
  model: 'config.default.model',
  permMode: 'config.default.permMode',
  locale: 'config.default.locale',
  save: 'config.save',
} as const;

// True when a component id belongs to a /config panel (router routing predicate).
export function isConfigPanelId(customId: string): boolean {
  return customId.startsWith(CONFIG_PANEL_PREFIX);
}

// The offered locales (a closed set — the i18n catalog only ships ko/en).
const LOCALES: Locale[] = ['ko', 'en'];

// The three role tiers the panel edits. admin ⊇ execute ⊇ read-only (§7.1).
type Tier = 'admin' | 'execute' | 'readOnly';

// The effective values used to prefill the panel — the guild's current server-layer
// auth allowlists + defaults (resolved global→server by the caller).
export interface ConfigPanelDefaults {
  adminRoleIds: string[];
  executeRoleIds: string[];
  readOnlyRoleIds: string[];
  backend: string; // resolved default mode
  model: string; // resolved default model
  permMode: PermMode; // resolved default permission mode
  locale: string; // resolved UI language (server override, else global)
}

// Option sources for the string-select menus.
export interface ConfigPanelOptions {
  guildId: string;
  ownerId: string; // the Discord user who opened the panel (only they may edit it)
  configStore: ConfigStore;
  defaults: ConfigPanelDefaults;
  // Backends offered (from modeRegistry.list()).
  backends: string[];
  // Models offered for the default-model select.
  models: string[];
  // Permission modes offered for the default-permMode select.
  permModes: PermMode[];
}

// A component input routed to the panel. For a role-select, `values` are role IDs;
// for a string-select, `value` is the picked value; for the Save button, neither.
export interface ConfigPanelInput {
  id: string;
  value?: string;
  values?: string[];
}

// The pending selections — ONLY the role tiers, which batch until Save. Defaults are
// auto-saved on change (not pending), so they are not tracked here. A field stays
// `undefined` until its menu is touched, so Save only writes tiers the operator
// actually changed (untouched = kept).
interface Pending {
  adminRoleIds?: string[];
  executeRoleIds?: string[];
  readOnlyRoleIds?: string[];
}

// The outcome of a panel input:
//   'pending'   → a role-tier selection was recorded (defer update, keep panel open).
//   'saved'     → the Save button persisted the role tiers; `summary` confirms them.
//   'autosaved' → a defaults select/modal wrote ONE field immediately; `notice` is a
//                 short ephemeral confirmation of just that field.
//   'ignored'   → an unknown input.
export type ConfigPanelResult =
  | { kind: 'pending' }
  | { kind: 'saved'; summary: string }
  | { kind: 'autosaved'; notice: string }
  | { kind: 'ignored' };

const TIER_BY_ID: Record<string, Tier> = {
  [IDS.roleAdmin]: 'admin',
  [IDS.roleExecute]: 'execute',
  [IDS.roleReadOnly]: 'readOnly',
};

export class ConfigPanel {
  private readonly opts: ConfigPanelOptions;
  private readonly pending: Pending = {};
  // The Discord user who opened this panel. Only they may edit/save it, so a
  // bystander's stray select cannot corrupt another admin's configuration (§7.1).
  readonly ownerId: string;

  constructor(options: ConfigPanelOptions) {
    this.opts = options;
    this.ownerId = options.ownerId;
  }

  // Advance the panel by one input. A role-select records a pending pick (batched
  // until Save). A defaults select auto-saves that one field immediately. The Save
  // button persists the batched role tiers. An unknown id is ignored.
  handle(input: ConfigPanelInput): ConfigPanelResult {
    const tier = TIER_BY_ID[input.id];
    if (tier) {
      // A role-select delivers role IDs in `values` (possibly empty when the operator
      // cleared the tier). Absent `values` (a malformed input) is ignored, not stored
      // as an empty allowlist, so a glitch never silently locks a tier down.
      if (input.values === undefined) return { kind: 'ignored' };
      this.setTier(tier, input.values);
      return { kind: 'pending' };
    }
    switch (input.id) {
      case IDS.backend:
        if (!input.value) return { kind: 'pending' };
        return this.autosaveBackend(input.value);
      case IDS.model:
        if (!input.value) return { kind: 'pending' };
        return this.autosaveModel(input.value);
      case IDS.permMode:
        if (!input.value) return { kind: 'pending' };
        return this.autosavePermMode(input.value as PermMode);
      case IDS.locale:
        if (!input.value) return { kind: 'pending' };
        return this.autosaveLocale(input.value);
      case IDS.save:
        return { kind: 'saved', summary: this.saveRoles() };
      default:
        return { kind: 'ignored' };
    }
  }

  private autosaveBackend(backend: string): ConfigPanelResult {
    // Only known enum backends are stored on defaults.mode; a future backend id is
    // ignored (same guard as the original Save path).
    if (backend === 'claude' || backend === 'codex') {
      this.patchDefaults({ mode: backend });
    }
    return { kind: 'autosaved', notice: t('config.autosaved.backend', { backend }) };
  }

  private autosaveModel(model: string): ConfigPanelResult {
    this.patchDefaults({ claudeModel: model });
    return { kind: 'autosaved', notice: t('config.autosaved.model', { model }) };
  }

  private autosavePermMode(permMode: PermMode): ConfigPanelResult {
    this.patchDefaults({ permissionMode: permMode });
    return { kind: 'autosaved', notice: t('config.autosaved.permMode', { perm: t(`perm.${permMode}`) }) };
  }

  private autosaveLocale(locale: string): ConfigPanelResult {
    this.patchLocale(locale);
    return { kind: 'autosaved', notice: t('config.autosaved.locale', { locale: this.localeLabel(locale) }) };
  }

  private setTier(tier: Tier, roleIds: string[]): void {
    // De-duplicate defensively; Discord already de-dupes, but a fake test input may not.
    const unique = [...new Set(roleIds)];
    if (tier === 'admin') this.pending.adminRoleIds = unique;
    else if (tier === 'execute') this.pending.executeRoleIds = unique;
    else this.pending.readOnlyRoleIds = unique;
  }

  // Merge the batched role picks over the guild's current server config and persist.
  // Untouched tiers fall through to the current effective value (defaults), then to
  // whatever the existing server file held — so Save never blanks a tier the operator
  // didn't touch. Defaults are NOT written here (they auto-save on change).
  private saveRoles(): string {
    const existing = this.opts.configStore.loadServerConfig(this.opts.guildId);
    const d = this.opts.defaults;

    const adminRoleIds = this.pending.adminRoleIds ?? existing?.auth?.adminRoleIds ?? d.adminRoleIds;
    const executeRoleIds = this.pending.executeRoleIds ?? existing?.auth?.executeRoleIds ?? d.executeRoleIds;
    const readOnlyRoleIds = this.pending.readOnlyRoleIds ?? existing?.auth?.readOnlyRoleIds ?? d.readOnlyRoleIds;

    // Preserve any server fields the panel doesn't manage (defaults, limits, etc.).
    const next: ServerConfig = {
      ...(existing ?? {}),
      version: existing?.version ?? CONFIG_VERSION,
      guildId: this.opts.guildId,
      auth: {
        ...(existing?.auth ?? {}),
        adminRoleIds,
        executeRoleIds,
        readOnlyRoleIds,
      },
    };

    this.opts.configStore.saveServerConfig(next);

    return t('config.saved', {
      admin: formatRoleList(adminRoleIds),
      execute: formatRoleList(executeRoleIds),
      readOnly: formatRoleList(readOnlyRoleIds),
      backend: d.backend,
      model: d.model,
      perm: t(`perm.${d.permMode}`),
    });
  }

  // Merge ONE changed defaults field over the guild's current server config and
  // persist it, preserving every other field (auth, other defaults, limits, locale).
  private patchDefaults(patch: Partial<NonNullable<ServerConfig['defaults']>>): void {
    const existing = this.opts.configStore.loadServerConfig(this.opts.guildId);
    const next: ServerConfig = {
      ...(existing ?? {}),
      version: existing?.version ?? CONFIG_VERSION,
      guildId: this.opts.guildId,
      defaults: { ...(existing?.defaults ?? {}), ...patch },
    };
    this.opts.configStore.saveServerConfig(next);
  }

  // Persist the per-guild locale (top-level on the server config, mirroring the
  // schema), preserving every other field.
  private patchLocale(locale: string): void {
    const existing = this.opts.configStore.loadServerConfig(this.opts.guildId);
    const next: ServerConfig = {
      ...(existing ?? {}),
      version: existing?.version ?? CONFIG_VERSION,
      guildId: this.opts.guildId,
      locale,
    };
    this.opts.configStore.saveServerConfig(next);
  }

  private localeLabel(locale: string): string {
    return locale === 'ko' || locale === 'en' ? t(`config.locale.${locale}`) : locale;
  }

  // Render the panel as plain component specs. `roleRows` (3 role tiers + Save = 4
  // rows) go on the primary reply; `defaultRows` (backend/model/permMode/locale
  // selects = 4 rows) go on a follow-up — both within Discord's 5-action-row-per-
  // message limit. Each defaults select marks its currently-saved option with
  // `default: true` so the dropdown shows the REAL current value (not the last
  // option), and role-selects pre-select the tier's current roles. The adapter maps
  // these onto discord.js; tests assert on them directly.
  render(): { embed: EmbedSpec; roleRows: ComponentRow[]; defaultRows: ComponentRow[] } {
    const d = this.opts.defaults;
    const adminSelect: RoleSelectSpec = this.roleSelect(IDS.roleAdmin, 'config.role.admin.placeholder', this.pending.adminRoleIds ?? d.adminRoleIds);
    const execSelect: RoleSelectSpec = this.roleSelect(IDS.roleExecute, 'config.role.execute.placeholder', this.pending.executeRoleIds ?? d.executeRoleIds);
    const readSelect: RoleSelectSpec = this.roleSelect(IDS.roleReadOnly, 'config.role.readOnly.placeholder', this.pending.readOnlyRoleIds ?? d.readOnlyRoleIds);

    const backendSelect: SelectSpec = {
      type: 'select',
      customId: IDS.backend,
      placeholder: t('config.default.backend.placeholder'),
      options: this.opts.backends.map((b) => ({
        label: t(`backend.${b}`) === `backend.${b}` ? b : t(`backend.${b}`),
        value: b,
        default: b === d.backend,
      })),
    };
    const modelSelect: SelectSpec = {
      type: 'select',
      customId: IDS.model,
      placeholder: t('config.default.model.placeholder'),
      options: this.opts.models.map((m) => ({
        label: m,
        value: m,
        default: m === d.model,
      })),
    };
    const permSelect: SelectSpec = {
      type: 'select',
      customId: IDS.permMode,
      placeholder: t('config.default.permMode.placeholder'),
      options: this.opts.permModes.map((m) => ({
        label: t(`perm.${m}`),
        value: m,
        default: m === d.permMode,
      })),
    };
    const localeSelect: SelectSpec = {
      type: 'select',
      customId: IDS.locale,
      placeholder: t('config.default.locale.placeholder'),
      options: LOCALES.map((l) => ({
        label: this.localeLabel(l),
        value: l,
        default: l === d.locale,
      })),
    };
    const save: ButtonSpec = { type: 'button', customId: IDS.save, label: t('config.save'), style: 'success' };

    return {
      embed: { title: t('config.title'), description: t('config.intro') },
      roleRows: [
        { components: [adminSelect] },
        { components: [execSelect] },
        { components: [readSelect] },
        { components: [save] },
      ],
      defaultRows: [
        { components: [backendSelect] },
        { components: [modelSelect] },
        { components: [permSelect] },
        { components: [localeSelect] },
      ],
    };
  }

  private roleSelect(customId: string, placeholderKey: string, defaultRoleIds: string[]): RoleSelectSpec {
    return {
      type: 'roleSelect',
      customId,
      placeholder: t(placeholderKey),
      minValues: 0,
      maxValues: 25,
      defaultRoleIds,
    };
  }
}

// Format a role-id list for the confirmation summary as Discord role mentions
// (<@&id>), so the operator sees role NAMES, not raw ids. Empty → an em dash.
function formatRoleList(roleIds: string[]): string {
  if (roleIds.length === 0) return '—';
  return roleIds.map((id) => `<@&${id}>`).join(', ');
}
