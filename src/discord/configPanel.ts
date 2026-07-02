import type { PermMode } from '../core/contracts.js';
import type { ConfigStore } from '../core/config.js';
import { CONFIG_VERSION, type ServerConfig } from '../core/configSchema.js';
import type { ButtonSpec, ComponentRow, EmbedSpec, RoleSelectSpec, SelectSpec } from './ports.js';
import { t } from './i18n.js';

// The `/config` panel (§7.1/§8): configure a guild's role tiers and defaults by
// CLICKING role names (Discord Role Select menus) instead of pasting role IDs.
// Everything the panel needs is plain data — no discord.js here — so the router
// and tests drive it directly; the client.ts adapter maps RoleSelectSpec onto a
// discord.js RoleSelectMenuBuilder and multi-select values onto ComponentInteraction.
//
// Persistence target: per-server servers/<guildId>.json (roles are per-guild, §7.1).
// On Save the panel merges its pending picks into that guild's ServerConfig auth +
// defaults, leaving any UNTOUCHED tier/select at its prior value.

// The panel component ids. `config.` prefix lets the router recognize + route them.
export const CONFIG_PANEL_PREFIX = 'config.';

const IDS = {
  roleAdmin: 'config.role.admin',
  roleExecute: 'config.role.execute',
  roleReadOnly: 'config.role.readOnly',
  backend: 'config.default.backend',
  model: 'config.default.model',
  permMode: 'config.default.permMode',
  save: 'config.save',
} as const;

// True when a component id belongs to a /config panel (router routing predicate).
export function isConfigPanelId(customId: string): boolean {
  return customId.startsWith(CONFIG_PANEL_PREFIX);
}

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

// The pending selections. A field stays `undefined` until its menu is touched, so
// Save only writes tiers/defaults the operator actually changed (untouched = kept).
interface Pending {
  adminRoleIds?: string[];
  executeRoleIds?: string[];
  readOnlyRoleIds?: string[];
  backend?: string;
  model?: string;
  permMode?: PermMode;
}

// The outcome of a panel input. 'pending' → a menu selection was recorded (defer
// update, keep the panel open). 'saved' → the Save button persisted the config;
// `summary` is the confirmation to reply with. 'ignored' → an unknown input.
export type ConfigPanelResult =
  | { kind: 'pending' }
  | { kind: 'saved'; summary: string }
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

  // Advance the panel by one input. Role/string selects record a pending pick; the
  // Save button merges pending picks into servers/<guildId>.json and returns the
  // confirmation summary. An unknown id is ignored (the panel is unchanged).
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
        if (input.value) this.pending.backend = input.value;
        return { kind: 'pending' };
      case IDS.model:
        if (input.value) this.pending.model = input.value;
        return { kind: 'pending' };
      case IDS.permMode:
        if (input.value) this.pending.permMode = input.value as PermMode;
        return { kind: 'pending' };
      case IDS.save:
        return { kind: 'saved', summary: this.save() };
      default:
        return { kind: 'ignored' };
    }
  }

  private setTier(tier: Tier, roleIds: string[]): void {
    // De-duplicate defensively; Discord already de-dupes, but a fake test input may not.
    const unique = [...new Set(roleIds)];
    if (tier === 'admin') this.pending.adminRoleIds = unique;
    else if (tier === 'execute') this.pending.executeRoleIds = unique;
    else this.pending.readOnlyRoleIds = unique;
  }

  // Merge pending picks over the guild's current server config and persist it.
  // Untouched tiers/defaults fall through to the current effective value (defaults),
  // then to whatever the existing server file held — so Save never blanks a field
  // the operator didn't touch.
  private save(): string {
    const existing = this.opts.configStore.loadServerConfig(this.opts.guildId);
    const d = this.opts.defaults;

    const adminRoleIds = this.pending.adminRoleIds ?? existing?.auth?.adminRoleIds ?? d.adminRoleIds;
    const executeRoleIds = this.pending.executeRoleIds ?? existing?.auth?.executeRoleIds ?? d.executeRoleIds;
    const readOnlyRoleIds = this.pending.readOnlyRoleIds ?? existing?.auth?.readOnlyRoleIds ?? d.readOnlyRoleIds;

    const mode = this.pending.backend ?? existing?.defaults?.mode ?? d.backend;
    const claudeModel = this.pending.model ?? existing?.defaults?.claudeModel ?? d.model;
    const permissionMode = this.pending.permMode ?? existing?.defaults?.permissionMode ?? d.permMode;

    // Preserve any server fields the panel doesn't manage (limits, favorites, etc.).
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
      defaults: {
        ...(existing?.defaults ?? {}),
        // `mode` is constrained to the backend enum; a backend id outside it (a
        // future backend) is stored on defaults only when it is a known enum member.
        ...(mode === 'claude' || mode === 'codex' ? { mode } : {}),
        claudeModel,
        permissionMode,
      },
    };

    this.opts.configStore.saveServerConfig(next);

    return t('config.saved', {
      admin: formatRoleList(adminRoleIds),
      execute: formatRoleList(executeRoleIds),
      readOnly: formatRoleList(readOnlyRoleIds),
      backend: mode,
      model: claudeModel,
      perm: t(`perm.${permissionMode}`),
    });
  }

  // Render the panel as plain component specs (embed + rows). The 7b adapter maps
  // it onto a discord.js reply; tests assert on it directly. Each role-select is
  // prefilled with the tier's current effective role IDs.
  render(): { embed: EmbedSpec; rows: ComponentRow[] } {
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
        default: b === (this.pending.backend ?? d.backend),
      })),
    };
    const modelSelect: SelectSpec = {
      type: 'select',
      customId: IDS.model,
      placeholder: t('config.default.model.placeholder'),
      options: this.opts.models.map((m) => ({
        label: m,
        value: m,
        default: m === (this.pending.model ?? d.model),
      })),
    };
    const permSelect: SelectSpec = {
      type: 'select',
      customId: IDS.permMode,
      placeholder: t('config.default.permMode.placeholder'),
      options: this.opts.permModes.map((m) => ({
        label: t(`perm.${m}`),
        value: m,
        default: m === (this.pending.permMode ?? d.permMode),
      })),
    };
    const save: ButtonSpec = { type: 'button', customId: IDS.save, label: t('config.save'), style: 'success' };

    return {
      embed: { title: t('config.title'), description: t('config.intro') },
      rows: [
        { components: [adminSelect] },
        { components: [execSelect] },
        { components: [readSelect] },
        { components: [backendSelect] },
        { components: [modelSelect] },
        { components: [permSelect] },
        { components: [save] },
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
