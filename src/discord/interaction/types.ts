import type { Logger, ModelChoice } from '../../core/contracts.js';
import type { Authorizer } from '../../core/auth.js';
import type { ChannelRegistry } from '../../core/channelRegistry.js';
import type { ConfigStore } from '../../core/config.js';
import type { StateStore } from '../../core/state/store.js';
import type { ConfigResolver } from '../../core/configResolver.js';
import type { PermissionResolver } from '../../core/permissionResolver.js';
import type { ModeRegistry } from '../../core/modeRegistry.js';
import type { SessionOrchestrator } from '../../core/sessionOrchestrator.js';
import type { UsageService } from '../../core/usageService.js';
import type { SessionWiring } from '../wiring.js';
import type { ShareResult } from '../documentShare.js';
import type { FolderPanelOpener } from '../folderPanel.js';
import type { AutoUpdater } from '../../update/autoUpdater.js';
import type { ChromiumProvisioner } from '../render/chromiumProvisioner.js';
import type { ComponentRow, EmbedSpec, MessageChannel, ModalSpec } from '../ports.js';
import type { GuildChannelProvisioner } from '../guildChannels.js';
import type { ChannelWizard } from '../wizard/channelWizard.js';
import type { ResumeWizard } from '../wizard/resumeWizard.js';
import type { ConfigPanel } from '../configPanel.js';
import type { AuthAction } from '../../core/auth.js';

// ---- Narrow interaction shapes (real discord.js interactions satisfy these) ----

// The shape of a reply/edit/follow-up payload. `content` is optional so an
// interactive panel (embed + component rows) can be sent without a text body;
// `embeds`/`components` carry the /config panel UI.
export interface AckPayload {
  content?: string;
  ephemeral?: boolean;
  embeds?: EmbedSpec[];
  components?: ComponentRow[];
}

interface Replier {
  reply: (options: AckPayload) => Promise<unknown>;
  // Acknowledge the interaction WITHOUT a visible message yet, buying the full
  // 15-minute follow-up window (Discord's 3s ack rule). `editReply` then fills in
  // the deferred reply; `followUp` posts an additional message (e.g. a second row
  // batch that would overflow the 5-action-row-per-message limit).
  deferReply: (options?: { ephemeral?: boolean }) => Promise<unknown>;
  editReply: (options: AckPayload) => Promise<unknown>;
  followUp: (options: AckPayload) => Promise<unknown>;
  // True once this interaction has been acknowledged (replied or deferred). The
  // adapter reads discord.js's own `replied`/`deferred` flags; a fake test double
  // tracks it so the guaranteed-error-ack path picks reply vs editReply correctly.
  readonly acknowledged: boolean;
}

// Common actor/context fields present on every interaction we handle.
interface BaseInteraction extends Replier {
  guildId: string | null;
  channelId: string;
  user: { id: string };
  member: { roles: { cache: { map: (fn: (r: { id: string }) => string) => string[] } } } | null;
  // True when the acting member has the Discord Administrator permission. Populated
  // by the client.ts adapter from member.permissions. Used ONLY as the /config
  // bootstrap gate (server admins can open /config even before the role allowlist
  // is set). Absent/false in DMs and for non-admins.
  hasAdminPermission?: boolean;
}

export interface SlashInteraction extends BaseInteraction {
  kind: 'slash';
  commandName: string; // 'agent' | 'mode' | 'stop' | 'clear' | 'stop-all'
  subcommand: string | null; // e.g. 'start' | 'resume' | 'close' | 'backend' | 'perm'
  getString: (name: string) => string | null;
}

export interface ComponentInteraction extends BaseInteraction {
  kind: 'component';
  customId: string;
  // Selected value for a string-select; empty for a button.
  value?: string;
  // Selected values for a multi-select (string- or role-select). For a role-select
  // these are the picked role IDs. Absent for a button.
  values?: string[];
  // Acknowledge a component interaction without a new reply (defer update).
  deferUpdate: () => Promise<unknown>;
  // Open a modal dialog IN RESPONSE to this component. showModal IS the ack for the
  // interaction, so the caller must NOT deferUpdate/deferReply before calling it (a
  // deferred interaction can no longer show a modal — discord.js throws). Present on
  // button interactions; the client.ts adapter maps ModalSpec onto discord.js.
  showModal: (modal: ModalSpec) => Promise<unknown>;
}

// A submitted modal (discord.js ModalSubmitInteraction). Carries the field values
// keyed by field custom id. It is its OWN interaction (a fresh 3s window): reply /
// deferReply as usual. The client.ts adapter reads the fields off the submission.
export interface ModalSubmitInteraction extends BaseInteraction {
  kind: 'modalSubmit';
  customId: string;
  // Read a submitted text-field value by its custom id (empty string when absent).
  getField: (fieldId: string) => string;
}

export type RouterInteraction = SlashInteraction | ComponentInteraction | ModalSubmitInteraction;

export interface InteractionRouterDeps {
  authorizer: Authorizer;
  orchestrator: SessionOrchestrator;
  channelRegistry: ChannelRegistry;
  configStore: ConfigStore;
  // Versioned state store (state.json). Used to back up / restore per-channel preset drafts
  // so a "💾 save as preset" button survives a restart (the in-memory presetDrafts Map is
  // otherwise lost). Same instance app boot passes to ChannelRegistry.
  stateStore: StateStore;
  configResolver: ConfigResolver;
  permissionResolver: PermissionResolver;
  modeRegistry: ModeRegistry;
  wiring: SessionWiring;
  // Per-channel document-share factory (mirrors the mode's sendFileFor closure): given a
  // session's guild+channel it returns the callback /doc uses to post a markdown file
  // into a document thread. Sourced from SessionWiring.shareDocumentFor at app boot;
  // optional so tests that never exercise /doc need not wire it.
  shareDocumentFor?: (guildId: string, channelId: string) => (path: string) => Promise<ShareResult>;
  // Chromium provisioner (image render). When present, /setup offers a background-install
  // prompt if no browser is present yet, and /config can install/toggle later. Absent →
  // no install UX (rendering still works when a system Chrome exists).
  imageProvisioner?: ChromiumProvisioner;
  // Claude usage/limits service (§7.4). Read by /agent stats for the usage summary
  // (Claude-global; unavailable line when OAuth is not logged in).
  usageService: UsageService;
  logger: Logger;
  // Allowed roots for the wizard's folder browser (config-driven; app boot supplies).
  browseRoots?: string[];
  // Models offered per backend, as English {value,label} pairs from the provider
  // catalog. Async so every /config or /agent start open re-probes the SDK's live
  // model list (Codex still resolves synchronously from its documented default).
  modelsFor?: (backend: string) => Promise<ModelChoice[]>;
  // Names the 'custom' backend's actual configured provider (e.g. "Custom
  // (kimi-k2.7-code)"), mirroring /mode backend's choice label (client.ts
  // buildSlashCommands) — see modes/custom/shellEnv.ts customBackendLabel().
  // Optional so tests/deploys without the custom backend need not wire it; the
  // wizard then falls back to the plain i18n 'backend.custom' label.
  customBackendLabel?: () => string;
  // Resolve a guildId to a channel provisioner over the live gateway (A4D-style /setup
  // + auto-created session channels). Returns null when the guild is unknown or the
  // client is not connected yet (tests inject a fake). Optional so the pre-gateway
  // graph builds without it; when absent, /setup and session-channel creation report a
  // graceful notice instead of throwing.
  resolveGuildProvisioner?: (guildId: string) => Promise<GuildChannelProvisioner | null>;
  // Resolve a channelId to a message sink (to post the status embed + intro into a
  // freshly created session channel). Defaults to the wiring's resolver; app boot
  // binds it to the live gateway. Optional for the same reason as above.
  resolveChannel?: (channelId: string) => Promise<MessageChannel | null>;
  // The auto-update orchestrator (§7). Optional so the pre-gateway graph and most tests
  // build without it; app boot injects it via setAutoUpdater once the client exists.
  // Update-prompt button clicks (approve/dismiss) route here after the admin gate.
  autoUpdater?: AutoUpdater;
  // Native host-side folder picker for the wizard's folder step (dir:panel). Wired by
  // app boot only where a GUI picker exists (macOS — see folderPanel.ts); when absent
  // the button is not rendered and dir:panel clicks are ignored, so non-GUI hosts see
  // no dead button.
  pickFolder?: FolderPanelOpener;
}

// A session-config draft captured when a NORMAL wizard reaches done, so the done reply's
// "💾 save as preset" button + name modal can persist exactly what was just launched.
// No cwd — presets are folder-independent (§D1), the folder is picked fresh every start.
// Mirrors the Preset schema's optional fields; consumed by savePresetFromModal.
export interface PresetDraft {
  backend: string;
  model?: string;
  effort?: string;
  permMode?: string;
  profile?: string | null;
}

/**
 * Shared host surface for free-function handlers extracted from InteractionRouter.
 * The class implements this; handlers only depend on this shape (no class import).
 */
export interface InteractionRouterHost {
  readonly deps: InteractionRouterDeps;
  readonly wizards: Map<string, ChannelWizard>;
  readonly resumeFlows: Map<string, ResumeWizard>;
  readonly configPanels: Map<string, ConfigPanel>;
  readonly presetDrafts: Map<string, PresetDraft>;
  readonly folderPanels: Set<string>;
  readonly wizardQueues: Map<string, Promise<void>>;
  modelAutocompleteCache: { choices: ModelChoice[]; fetchedAt: number } | null;
  readonly modelAutocompleteCacheMs: number;
  readonly folderPanelTimeoutMs: number;

  logError(message: string, err: unknown): void;
  authorize(i: RouterInteraction, action: AuthAction): boolean;
  authorizeConfig(i: RouterInteraction): boolean;
  ackDefer(i: RouterInteraction, options?: { ephemeral?: boolean }): Promise<boolean>;
  ackDeferUpdate(i: ComponentInteraction): Promise<boolean>;
  guarded(i: RouterInteraction, fn: () => Promise<void>): Promise<void>;
  enqueueWizard(key: string, job: () => Promise<void>): Promise<void>;
  editWizardReply(i: ComponentInteraction, payload: AckPayload): Promise<void>;
  maybePromptRenderSetup(channelId: string): Promise<void>;
}
