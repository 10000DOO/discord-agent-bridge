import type { ModelChoice, PermMode } from '../core/contracts.js';
import type { ConfigStore } from '../core/config.js';
import { CONFIG_VERSION, type ServerConfig } from '../core/configSchema.js';
import { resolveNotifications } from './notifier.js';
import type { Locale } from './i18n.js';
import type { ButtonSpec, ChannelSelectSpec, ComponentRow, EmbedSpec, RoleSelectSpec, SelectSpec } from './ports.js';
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
//   - Defaults (backend / model / effort / permMode / locale selects) AUTO-SAVE on
//     each change: one changed field is written immediately. The defaults follow-up
//     holds 5 selects with no Save button — exactly at Discord's 5-row budget.
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
  effort: 'config.default.effort',
  permMode: 'config.default.permMode',
  locale: 'config.default.locale',
  save: 'config.save',
  // Notifications sub-panel: a button on the primary panel opens an ephemeral
  // sub-panel carrying the enable/disable toggle + the status-channel picker.
  notifOpen: 'config.notif.open',
  notifToggle: 'config.notif.toggle',
  notifChannel: 'config.notif.channel',
  // Image-render sub-panel: a button opens an ephemeral sub-panel with an on/off toggle
  // and an install button (download Chromium). Mirrors the notifications sub-panel.
  renderOpen: 'config.render.open',
  renderToggle: 'config.render.toggle',
  renderInstall: 'config.render.install',
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
  // Resolved default reasoning effort for the current backend (server override else
  // global). The panel pre-selects this in the effort dropdown; auto-save writes to
  // either claudeEffort or codexEffort depending on the panel's saved backend.
  effort: string;
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
  // Whether a backend id is registered (the router wires it to modeRegistry.has). The
  // autosave-backend guard delegates to this instead of a hardcoded id list, so a newly
  // registered mode persists on defaults.mode without editing this panel (§5.4).
  isKnownBackend: (backend: string) => boolean;
  // Models offered for the default-model select, as English {value,label} pairs from
  // the provider catalog (Claude = dynamic; Codex = documented default).
  models: ModelChoice[];
  // Reasoning-effort levels offered for the default-effort select, per current
  // backend, from the provider catalog. Claude values may be narrowed by the SDK's
  // supportedEffortLevels when reported for the selected model.
  efforts: ModelChoice[];
  // Permission modes offered for the default-permMode select, as English {value,label}
  // pairs from the provider catalog (per-backend: Codex excludes dontAsk/auto).
  permModes: ModelChoice[];
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
  // The 🔔 button opened the notifications sub-panel (a fresh ephemeral message).
  | { kind: 'notifPanel'; embed: EmbedSpec; rows: ComponentRow[] }
  // A notifications toggle/channel change persisted and re-rendered the sub-panel in
  // place (edited on its own message).
  | { kind: 'notifUpdated'; embed: EmbedSpec; rows: ComponentRow[] }
  // The 🖼 button opened the image-render sub-panel (fresh ephemeral message).
  | { kind: 'renderPanel'; embed: EmbedSpec; rows: ComponentRow[] }
  // The render on/off toggle persisted and re-rendered the sub-panel in place.
  | { kind: 'renderUpdated'; embed: EmbedSpec; rows: ComponentRow[] }
  // The install button was pressed — the router runs the Chromium provisioner.
  | { kind: 'renderInstall' }
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
      case IDS.effort:
        if (!input.value) return { kind: 'pending' };
        return this.autosaveEffort(input.value);
      case IDS.permMode:
        if (!input.value) return { kind: 'pending' };
        return this.autosavePermMode(input.value as PermMode);
      case IDS.locale:
        if (!input.value) return { kind: 'pending' };
        return this.autosaveLocale(input.value);
      case IDS.notifOpen:
        return { kind: 'notifPanel', ...this.renderNotifications() };
      case IDS.renderOpen:
        return { kind: 'renderPanel', ...this.renderRenderPanel() };
      case IDS.renderToggle:
        return this.toggleRender();
      case IDS.renderInstall:
        return { kind: 'renderInstall' };
      case IDS.notifToggle:
        return this.toggleNotifications();
      case IDS.notifChannel:
        // A channel-select delivers the picked channel id(s) in `values`. An empty
        // pick clears the override (falls back to the /setup status channel).
        return this.setNotificationChannel(input.values?.[0] ?? null);
      case IDS.save:
        return { kind: 'saved', summary: this.saveRoles() };
      default:
        return { kind: 'ignored' };
    }
  }

  private autosaveBackend(backend: string): ConfigPanelResult {
    // Only a REGISTERED backend id is stored on defaults.mode; an unknown id is ignored
    // (the ModeRegistry is the single validity gate — §5.4).
    if (this.opts.isKnownBackend(backend)) {
      this.patchDefaults({ mode: backend });
    }
    return { kind: 'autosaved', notice: t('config.autosaved.backend', { backend }) };
  }

  private autosaveModel(model: string): ConfigPanelResult {
    this.patchDefaults({ claudeModel: model });
    return { kind: 'autosaved', notice: t('config.autosaved.model', { model }) };
  }

  // Reasoning-effort auto-save. The persisted backend at write time picks the key:
  // Codex → codexEffort, anything else → claudeEffort. Reads the SERVER override
  // (may have been auto-saved earlier in this same panel session by the backend
  // select); falls back to the panel-open default, which was already resolved
  // global→server by the caller.
  private autosaveEffort(effort: string): ConfigPanelResult {
    const server = this.opts.configStore.loadServerConfig(this.opts.guildId);
    const backend = server?.defaults?.mode ?? this.opts.defaults.backend;
    const patch = backend === 'codex' ? { codexEffort: effort } : { claudeEffort: effort };
    this.patchDefaults(patch);
    return { kind: 'autosaved', notice: t('config.autosaved.effort', { effort }) };
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

  // ---- Notifications sub-panel ----

  // Flip the enabled flag, persist it, and re-render the sub-panel so the toggle label
  // reflects the new state.
  private toggleNotifications(): ConfigPanelResult {
    const current = this.currentNotifications();
    this.patchNotifications({ enabled: !current.enabled });
    return { kind: 'notifUpdated', ...this.renderNotifications() };
  }

  // Set (or clear, with null) the status-channel override, persist it, and re-render.
  private setNotificationChannel(channelId: string | null): ConfigPanelResult {
    this.patchNotifications({ channelId });
    return { kind: 'notifUpdated', ...this.renderNotifications() };
  }

  // ---- Image-render sub-panel (GLOBAL config; host-wide) ----

  private renderEnabled(): boolean {
    return this.opts.configStore.load().render?.enabled ?? true;
  }

  // Flip the GLOBAL render.enabled flag, persist it, and re-render the sub-panel.
  private toggleRender(): ConfigPanelResult {
    this.opts.configStore.setRenderEnabled(!this.renderEnabled());
    return { kind: 'renderUpdated', ...this.renderRenderPanel() };
  }

  private renderRenderPanel(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const enabled = this.renderEnabled();
    const toggle: ButtonSpec = {
      type: 'button',
      customId: IDS.renderToggle,
      label: enabled ? t('config.render.disable') : t('config.render.enable'),
      style: enabled ? 'danger' : 'success',
    };
    const install: ButtonSpec = {
      type: 'button',
      customId: IDS.renderInstall,
      label: t('config.render.install'),
      style: 'primary',
    };
    return {
      embed: {
        title: t('config.render.title'),
        description: t('config.render.intro', { state: enabled ? t('config.render.on') : t('config.render.off') }),
      },
      rows: [{ components: [toggle, install] }],
    };
  }

  // Merge ONE notifications field over the guild's current server config and persist,
  // preserving every other field (auth, defaults, channels, locale).
  private patchNotifications(patch: Partial<NonNullable<ServerConfig['notifications']>>): void {
    const existing = this.opts.configStore.loadServerConfig(this.opts.guildId);
    const next: ServerConfig = {
      ...(existing ?? {}),
      version: existing?.version ?? CONFIG_VERSION,
      guildId: this.opts.guildId,
      notifications: { ...(existing?.notifications ?? {}), ...patch },
    };
    this.opts.configStore.saveServerConfig(next);
  }

  // The guild's resolved notifications config (defaults applied), read fresh from disk
  // so the sub-panel always reflects persisted state after each toggle/pick.
  private currentNotifications() {
    return resolveNotifications(this.opts.configStore.loadServerConfig(this.opts.guildId));
  }

  // Render the notifications sub-panel: an enable/disable toggle button + a GuildText
  // channel picker for the status channel. Two rows, within Discord's 5-row limit.
  private renderNotifications(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const n = this.currentNotifications();
    const toggle: ButtonSpec = {
      type: 'button',
      customId: IDS.notifToggle,
      label: n.enabled ? t('config.notif.disable') : t('config.notif.enable'),
      style: n.enabled ? 'danger' : 'success',
    };
    const channelSelect: ChannelSelectSpec = {
      type: 'channelSelect',
      customId: IDS.notifChannel,
      placeholder: t('config.notif.channel.placeholder'),
      minValues: 0,
      maxValues: 1,
      ...(n.channelId ? { defaultChannelIds: [n.channelId] } : {}),
    };
    return {
      embed: {
        title: t('config.notif.title'),
        description: t('config.notif.intro', { state: n.enabled ? t('config.notif.on') : t('config.notif.off') }),
      },
      rows: [{ components: [channelSelect] }, { components: [toggle] }],
    };
  }

  // Render the panel as plain component specs. `roleRows` (3 role tiers + Save = 4
  // rows) go on the primary reply; `defaultRows` (backend/model/effort/permMode/
  // locale selects = 5 rows) go on a follow-up — both within Discord's 5-action-row-
  // per-message limit. Each defaults select marks its currently-saved option with
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
      // English labels from the catalog (model id / SDK displayName), not localized.
      options: this.opts.models.map((m) => ({
        label: m.label,
        value: m.value,
        default: m.value === d.model,
      })),
    };
    const effortSelect: SelectSpec = {
      type: 'select',
      customId: IDS.effort,
      placeholder: t('config.default.effort.placeholder'),
      // English identifiers from the catalog, not localized. Options reflect the CURRENT
      // backend at panel-open time; a backend change in this same panel session persists
      // but does not re-render the effort options (matches the model dropdown's snapshot
      // behavior — reopen /config to refresh).
      options: this.opts.efforts.map((e) => ({
        label: e.label,
        value: e.value,
        default: e.value === d.effort,
      })),
    };
    const permSelect: SelectSpec = {
      type: 'select',
      customId: IDS.permMode,
      placeholder: t('config.default.permMode.placeholder'),
      // English identifiers + a short English hint from the catalog, not localized.
      options: this.opts.permModes.map((m) => ({
        label: m.label,
        value: m.value,
        default: m.value === d.permMode,
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
    // The 🔔 notifications button opens an ephemeral sub-panel (toggle + channel picker),
    // so the primary message stays within Discord's 5-action-row limit (it shares the
    // Save row: a single action row can hold up to 5 buttons).
    const notif: ButtonSpec = { type: 'button', customId: IDS.notifOpen, label: t('config.notif.button'), style: 'secondary' };
    // 🖼 opens the image-render sub-panel (on/off + install). Shares the Save row (a
    // single action row holds up to 5 buttons), so no extra row is used.
    const render: ButtonSpec = { type: 'button', customId: IDS.renderOpen, label: t('config.render.button'), style: 'secondary' };

    return {
      embed: { title: t('config.title'), description: t('config.intro') },
      roleRows: [
        { components: [adminSelect] },
        { components: [execSelect] },
        { components: [readSelect] },
        { components: [save, notif, render] },
      ],
      defaultRows: [
        { components: [backendSelect] },
        { components: [modelSelect] },
        { components: [effortSelect] },
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
