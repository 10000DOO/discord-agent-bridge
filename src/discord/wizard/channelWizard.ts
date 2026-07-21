import type { ModelChoice, ModeSession, SessionPermMode } from '../../core/contracts.js';
import type { ButtonSpec, ComponentRow, EmbedSpec, SelectSpec } from '../ports.js';
import { DirectoryBrowser } from '../directoryBrowser.js';
import { t } from '../i18n.js';

// The `/agent start` channel-creation flow as a state machine (§9 step 1):
//   folder browser → backend → model → reasoning effort → permission → start.
// Each CHOICE step (backend/model/effort/perm) is a dropdown PLUS a confirm button —
// the button advances, not the select's change event. Discord does NOT fire an
// interaction when a user re-picks the already-selected option, so a user who keeps the
// pre-selected default would be stuck if we advanced on change (the reported bug). The
// select's onChange only updates a PENDING value + re-renders (showing it selected); the
// button then advances using the pending value, defaulting to the step's current value
// if the dropdown was never touched. The folder step keeps its own "✅ 이 폴더로 시작"
// button. Every step AFTER the folder also carries a "⬅ 이전" back button
// ('wizard.back') that returns to the previous step with the committed selections
// intact — so a wrong backend pick no longer forces a cancel + full restart. Going
// back discards only the CURRENT step's un-confirmed pending pick; re-advancing shows
// the previously committed values pre-selected. Model/effort/permission OPTIONS are
// BACKEND-SPECIFIC (Claude vs Codex): the wizard reads them from injected per-backend
// suppliers once the backend is chosen. Transitions are driven by injected
// select/button inputs (no discord.js here) so 7b can wire real interactions and tests
// can drive it directly.

export type WizardStep = 'folder' | 'backend' | 'model' | 'effort' | 'perm' | 'confirm' | 'done' | 'cancelled';

// The subset of SessionOrchestrator.start the wizard depends on. Injected so tests
// mock it; 7b passes the real orchestrator's bound start.
export interface StartParams {
  guildId: string;
  channelId: string;
  mode: string;
  cwd: string;
  ownerId: string;
  permMode?: SessionPermMode;
  profile?: string | null;
  effort?: string;
  model?: string;
}
// The wizard's start callback returns the session AND the channel id the session was
// actually bound to. A4D-style, the router CREATES a fresh session channel from the
// picked folder and binds there — so the effective channel id differs from the one the
// wizard was opened in. The wizard surfaces it (createdChannelId) so the router can
// reply with a link to the new channel.
export interface StartResult {
  session: ModeSession;
  channelId: string;
}
export type StartFn = (params: StartParams) => Promise<StartResult>;

// Prefill + option sources, resolved from the config hierarchy by 7b/8.
export interface WizardDefaults {
  backend: string; // resolved default mode
  model: string; // resolved default model
  permMode: SessionPermMode; // resolved default permission mode
  profile: string | null; // resolved default profile (null = raw mode)
}

export interface ChannelWizardOptions {
  guildId: string;
  channelId: string;
  ownerId: string;
  start: StartFn;
  defaults: WizardDefaults;
  // Backends offered in the backend step (from modeRegistry.list()).
  backends: string[];
  // Overrides the 'custom' backend's displayed label (mirrors /mode backend's
  // choice — see client.ts buildSlashCommands): names the ANTHROPIC_MODEL the
  // operator's shell dotfile actually resolves to (e.g. "Custom (kimi-k2.7-code)"),
  // computed fresh when the wizard opens. Absent → falls back to the i18n
  // 'backend.custom' key (plain "Custom").
  customBackendLabel?: string;
  // Models offered for a backend, as English {value,label} pairs from the provider
  // catalog (Claude = dynamic/cached; Codex = documented list). Read once the backend
  // is chosen so the model step reflects the right catalog.
  modelsFor: (backend: string) => ModelChoice[];
  // Named permission profiles offered as the quick path (§7A). Empty = raw only.
  profiles: string[];
  // Permission OPTIONS for a backend (Claude PermMode list vs Codex sandbox terms), as
  // English {value,label} pairs from the provider catalog.
  permsFor: (backend: string) => ModelChoice[];
  // Reasoning-effort OPTIONS for a backend + chosen model, as English {value,label}
  // pairs (Claude effort levels — narrowed to the model when the SDK reports it — vs
  // Codex model_reasoning_effort values).
  effortsFor: (backend: string, model: string) => ModelChoice[];
  // The pre-selected reasoning effort for a backend when the driver has not chosen one.
  defaultEffortFor: (backend: string) => string;
  // Folder browser (allowed roots / start path already configured by 7b).
  browser: DirectoryBrowser;
}

// A wizard select/button input. `id` is the component id ('backend', 'model',
// 'effort', 'perm.mode', 'perm.profile', 'dir:into', 'dir:up', 'dir:here', the
// confirm buttons 'backend.next', 'model.next', 'effort.next', 'perm.start', plus
// 'wizard.back' and 'cancel'); `value` is the selected option value (for selects) or
// empty (for buttons).
export interface WizardInput {
  id: string;
  value?: string;
}

// The wizard's collected selections; the final start reads these.
interface Selection {
  cwd: string | null;
  backend: string;
  model: string;
  effort: string;
  permMode: SessionPermMode;
  // A Codex sandbox mode (read-only / workspace-write / danger-full-access) is stored
  // here on the permMode channel too — the runner tells the vocabularies apart.
  profile: string | null;
}

export class ChannelWizard {
  private readonly opts: ChannelWizardOptions;
  private readonly browser: DirectoryBrowser;
  private step: WizardStep = 'folder';
  private readonly selection: Selection;
  // Pending (not-yet-confirmed) select values for the current step. A select onChange
  // writes here + re-renders; the step's confirm button reads it (falling back to the
  // committed selection when the dropdown was never touched) and advances.
  private pending: { backend?: string; model?: string; effort?: string; perm?: string } = {};
  // The Discord user who opened this wizard (the driver). Only they advance it, so a
  // bystander's stray select/button cannot corrupt another driver's flow (§7.1).
  readonly ownerId: string;
  // The channel id the confirmed session was bound to (the freshly created session
  // channel, A4D-style). Null until start succeeds; the router reads it to link the
  // new channel back to the driver.
  private createdChannelId: string | null = null;

  constructor(options: ChannelWizardOptions) {
    this.opts = options;
    this.browser = options.browser;
    this.ownerId = options.ownerId;
    this.selection = {
      cwd: null,
      backend: options.defaults.backend,
      model: options.defaults.model,
      effort: options.defaultEffortFor(options.defaults.backend),
      permMode: options.defaults.permMode,
      profile: options.defaults.profile,
    };
  }

  currentStep(): WizardStep {
    return this.step;
  }

  // The folder currently in view in the wizard's browser. Used by the router's
  // 📁 Create flow to mkdir a subfolder in the CURRENT browsed directory, and by the
  // Resume Session flow to scope listResumable to it. Read-only.
  browserCwd(): string {
    return this.browser.cwd();
  }

  // Jump the wizard's browser to an absolute path typed via the 📝 manual-path modal.
  // Returns false when the path is invalid / out of bounds (same rule as browse nav),
  // so the router can report it without changing the view.
  browserGoTo(absPath: string): boolean {
    return this.browser.goTo(absPath);
  }

  // The collected selection so far (read-only view for tests / status).
  current(): Readonly<Selection> {
    return { ...this.selection };
  }

  // Advance the state machine by one input. Returns the new step. Unknown inputs for
  // the current step are ignored (the step is unchanged) so a stray interaction does
  // not corrupt the flow. The perm step's start button calls orchestrator.start.
  async handle(input: WizardInput): Promise<WizardStep> {
    if (input.id === 'cancel') {
      this.step = 'cancelled';
      return this.step;
    }
    if (input.id === 'wizard.back') {
      this.stepBack();
      return this.step;
    }
    switch (this.step) {
      case 'folder':
        await this.handleFolder(input);
        break;
      case 'backend':
        this.handleBackend(input);
        break;
      case 'model':
        this.handleModel(input);
        break;
      case 'effort':
        this.handleEffort(input);
        break;
      case 'perm':
        await this.handlePerm(input);
        break;
      default:
        break; // done / cancelled: no further transitions
    }
    return this.step;
  }

  // Step back one step ('wizard.back'). Committed selections are kept — only the
  // CURRENT step's un-confirmed pending pick is discarded — so re-advancing shows the
  // previous choices pre-selected instead of resetting the flow. The perm step returns
  // to effort only when the chosen backend actually has that step (mirrors the forward
  // skip, §6). The folder step is the first — back is not rendered there and a stray
  // input is a no-op, like every other unknown id.
  private stepBack(): void {
    this.pending = {};
    switch (this.step) {
      case 'backend':
        this.step = 'folder';
        break;
      case 'model':
        this.step = 'backend';
        break;
      case 'effort':
        this.step = 'model';
        break;
      case 'perm':
        this.step = this.hasEffortStep() ? 'effort' : 'model';
        break;
      default:
        break; // folder / done / cancelled: nothing to go back to
    }
  }

  private async handleFolder(input: WizardInput): Promise<void> {
    if (input.id === 'dir:into' && input.value) {
      this.browser.into(input.value);
    } else if (input.id === 'dir:up') {
      this.browser.up();
    } else if (input.id === 'dir:here') {
      this.selection.cwd = this.browser.select();
      this.step = 'backend';
    }
  }

  // Backend step: the select stores a pending backend + re-renders; 'backend.next'
  // commits it (or the current default) and advances to the model step. Committing a
  // NEW backend resets model/effort/perm to that backend's defaults so the later steps
  // never show another backend's catalog.
  private handleBackend(input: WizardInput): void {
    if (input.id === 'backend' && input.value) {
      this.pending.backend = input.value;
    } else if (input.id === 'backend.next') {
      const chosen = this.pending.backend ?? this.selection.backend;
      if (chosen !== this.selection.backend) this.applyBackend(chosen);
      this.pending.backend = undefined;
      this.step = 'model';
    }
  }

  // Model step: the select stores a pending model; 'model.next' commits it (or the
  // current default) and advances to the reasoning-effort step — unless the backend has
  // no effort options (effortsFor returns []), in which case that step is skipped and we
  // go straight to permissions (a backend without an effort concept, §6).
  private handleModel(input: WizardInput): void {
    if (input.id === 'model' && input.value) {
      this.pending.model = input.value;
    } else if (input.id === 'model.next') {
      this.selection.model = this.pending.model ?? this.selection.model;
      this.pending.model = undefined;
      this.step = this.hasEffortStep() ? 'effort' : 'perm';
    }
  }

  // Whether the chosen backend/model offers any reasoning-effort options. When empty the
  // wizard omits the effort step entirely (grok-style backends with no effort concept).
  private hasEffortStep(): boolean {
    return this.opts.effortsFor(this.selection.backend, this.selection.model).length > 0;
  }

  // Reasoning-effort step: the select stores a pending effort; 'effort.next' commits it
  // (or the current default) and advances to the permission step.
  private handleEffort(input: WizardInput): void {
    if (input.id === 'effort' && input.value) {
      this.pending.effort = input.value;
    } else if (input.id === 'effort.next') {
      this.selection.effort = this.pending.effort ?? this.selection.effort;
      this.pending.effort = undefined;
      this.step = 'perm';
    }
  }

  // Permission step (final): a profile pick (Claude quick path) OR a raw mode / Codex
  // sandbox pick, plus the '✅ 시작' button. The selects store a pending value; the
  // start button commits it and runs orchestrator.start. A profile pick uses the
  // 'perm.profile' channel; a mode/sandbox pick uses 'perm.mode'.
  private async handlePerm(input: WizardInput): Promise<void> {
    if (input.id === 'perm.profile' && input.value) {
      this.pending.perm = `profile:${input.value}`;
    } else if (input.id === 'perm.mode' && input.value) {
      this.pending.perm = `mode:${input.value}`;
    } else if (input.id === 'perm.start') {
      this.commitPending();
      await this.start();
    }
  }

  // Commit the pending permission pick (if any) onto the selection. Falls back to the
  // committed default when the dropdown was never touched, so pressing 시작 without
  // changing anything still starts with the resolved defaults.
  private commitPending(): void {
    const pending = this.pending.perm;
    if (!pending) return;
    if (pending.startsWith('profile:')) {
      const value = pending.slice('profile:'.length);
      this.selection.profile = value === '__raw__' ? null : value;
    } else if (pending.startsWith('mode:')) {
      // A raw mode (Claude PermMode) or a Codex sandbox value; either way it clears any
      // profile and rides the permMode channel to the runner.
      this.selection.permMode = pending.slice('mode:'.length) as SessionPermMode;
      this.selection.profile = null;
    }
    this.pending.perm = undefined;
  }

  // Reset model/effort/permission to a newly chosen backend's defaults so the
  // downstream steps never carry a stale value from the previous backend.
  private applyBackend(backend: string): void {
    this.selection.backend = backend;
    const models = this.opts.modelsFor(backend);
    this.selection.model = models[0]?.value ?? this.selection.model;
    this.selection.effort = this.opts.defaultEffortFor(backend);
    const perms = this.opts.permsFor(backend);
    this.selection.permMode = (perms[0]?.value ?? this.selection.permMode) as SessionPermMode;
    this.selection.profile = null;
    this.pending = {};
  }

  private async start(): Promise<void> {
    if (this.selection.cwd === null) {
      // Should not happen (folder is step 1) — guard rather than start with no cwd.
      this.step = 'folder';
      return;
    }
    const result = await this.opts.start({
      guildId: this.opts.guildId,
      channelId: this.opts.channelId,
      mode: this.selection.backend,
      cwd: this.selection.cwd,
      ownerId: this.opts.ownerId,
      permMode: this.selection.permMode,
      profile: this.selection.profile,
      effort: this.selection.effort,
      model: this.selection.model,
    });
    this.createdChannelId = result.channelId;
    this.step = 'done';
  }

  // The channel id the confirmed session was bound to (the created session channel),
  // or null before a successful start. The router links it back to the driver.
  sessionChannelId(): string | null {
    return this.createdChannelId;
  }

  // Render the current step as a plain component spec (embed + rows). 7b maps it onto
  // a discord.js reply/update. Pure data — the tests assert on it directly.
  render(): { embed: EmbedSpec; rows: ComponentRow[] } {
    switch (this.step) {
      case 'folder':
        return this.browser.render();
      case 'backend':
        return this.choiceStep(
          'wizard.step.backend',
          'backend',
          this.opts.backends.map((b) => ({
            label:
              b === 'custom' && this.opts.customBackendLabel
                ? this.opts.customBackendLabel
                : t(`backend.${b}`) === `backend.${b}`
                  ? b
                  : t(`backend.${b}`),
            value: b,
            default: b === (this.pending.backend ?? this.selection.backend),
          })),
          nextButton('backend.next'),
        );
      case 'model':
        // English labels from the catalog (model id / SDK displayName), not localized.
        return this.choiceStep(
          'wizard.step.model',
          'model',
          this.opts.modelsFor(this.selection.backend).map((m) => ({
            label: m.label,
            value: m.value,
            default: m.value === (this.pending.model ?? this.selection.model),
          })),
          nextButton('model.next'),
        );
      case 'effort':
        return this.choiceStep(
          'wizard.step.effort',
          'effort',
          this.opts.effortsFor(this.selection.backend, this.selection.model).map((e) => ({
            label: e.label,
            value: e.value,
            default: e.value === (this.pending.effort ?? this.selection.effort),
          })),
          nextButton('effort.next'),
        );
      case 'perm':
        return this.permStep();
      case 'confirm':
        // The perm step is the final choice; confirm has no dedicated render (start
        // transitions straight to 'done'). Kept only for state completeness.
        return this.permStep();
      case 'done':
        return {
          embed: {
            title: t('wizard.title'),
            description: t('wizard.started', {
              backend: this.selection.backend,
              cwd: this.selection.cwd ?? '',
            }),
          },
          rows: [],
        };
      case 'cancelled':
        return { embed: { title: t('wizard.title'), description: t('wizard.cancelled') }, rows: [] };
    }
  }

  // A choice step: a single-select (pending-aware `default`) + a confirm button that
  // advances, a back button, and a cancel button. The buttons — not the select — drive
  // the transitions.
  private choiceStep(
    titleKey: string,
    id: string,
    options: SelectSpec['options'],
    confirm: ButtonSpec,
  ): { embed: EmbedSpec; rows: ComponentRow[] } {
    const select: SelectSpec = { type: 'select', customId: id, placeholder: t(titleKey), options };
    return {
      embed: { title: t('wizard.title'), description: t(titleKey) },
      rows: [{ components: [select] }, { components: [confirm, backButton(), cancelButton()] }],
    };
  }

  // Permission step (final): a profiles select (Claude quick path, when profiles exist)
  // plus the backend's permission select (Claude PermMode list or Codex sandbox terms),
  // and a '✅ 시작' start button. All selects update pending state; only the button
  // starts the session.
  private permStep(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const rows: ComponentRow[] = [];
    const pendingProfile = this.pending.perm?.startsWith('profile:')
      ? this.pending.perm.slice('profile:'.length)
      : null;
    const pendingMode = this.pending.perm?.startsWith('mode:')
      ? this.pending.perm.slice('mode:'.length)
      : null;
    if (this.opts.profiles.length > 0) {
      const selectedProfile = pendingProfile ?? this.selection.profile;
      const profileSelect: SelectSpec = {
        type: 'select',
        customId: 'perm.profile',
        placeholder: t('wizard.step.perm'),
        options: [
          ...this.opts.profiles.map((p) => ({ label: p, value: p, default: p === selectedProfile })),
          { label: t('wizard.profile.advanced'), value: '__raw__' },
        ],
      };
      rows.push({ components: [profileSelect] });
    }
    const selectedMode = pendingMode ?? this.selection.permMode;
    const modeSelect: SelectSpec = {
      type: 'select',
      customId: 'perm.mode',
      placeholder: t('wizard.profile.advanced'),
      // English identifiers + a short English hint from the catalog, per backend.
      options: this.opts.permsFor(this.selection.backend).map((m) => ({
        label: m.label,
        value: m.value,
        default: m.value === selectedMode,
      })),
    };
    rows.push({ components: [modeSelect] });
    rows.push({
      components: [
        { type: 'button', customId: 'perm.start', label: t('wizard.start'), style: 'success' },
        backButton(),
        cancelButton(),
      ],
    });
    return { embed: { title: t('wizard.title'), description: t('wizard.step.perm') }, rows };
  }
}

// The "다음" (Next) confirm button for a choice step, with the step-specific custom id.
function nextButton(customId: string): ButtonSpec {
  return { type: 'button', customId, label: t('wizard.next'), style: 'primary' };
}

// The "⬅ 이전" (Back) button, shared by every step after the folder. One id — the
// state machine knows which step it is leaving.
function backButton(): ButtonSpec {
  return { type: 'button', customId: 'wizard.back', label: t('wizard.back'), style: 'secondary' };
}

function cancelButton(): ButtonSpec {
  return { type: 'button', customId: 'cancel', label: t('wizard.cancel'), style: 'secondary' };
}
