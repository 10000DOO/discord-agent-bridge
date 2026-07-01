import type { ModeSession, PermMode } from '../../core/contracts.js';
import type { ComponentRow, EmbedSpec, SelectSpec } from '../ports.js';
import { DirectoryBrowser } from '../directoryBrowser.js';
import { t } from '../i18n.js';

// The `/agent start` channel-creation flow as a state machine (§9 step 1):
//   folder browser → backend → model → permission mode/profile → confirm.
// Defaults are prefilled from the resolved hierarchy (global→server) and permission
// PROFILES are offered as the quick path with raw mode as advanced (§7A). On confirm
// the wizard calls orchestrator.start(...) with the collected values and lets the
// caller write the binding. Transitions are driven by injected select/button inputs
// (no discord.js here) so 7b can wire real interactions and tests can drive it directly.

export type WizardStep = 'folder' | 'backend' | 'model' | 'perm' | 'confirm' | 'done' | 'cancelled';

// The subset of SessionOrchestrator.start the wizard depends on. Injected so tests
// mock it; 7b passes the real orchestrator's bound start.
export interface StartParams {
  guildId: string;
  channelId: string;
  mode: string;
  cwd: string;
  ownerId: string;
  permMode?: PermMode;
  profile?: string | null;
}
export type StartFn = (params: StartParams) => Promise<ModeSession>;

// Prefill + option sources, resolved from the config hierarchy by 7b/8.
export interface WizardDefaults {
  backend: string; // resolved default mode
  model: string; // resolved default model
  permMode: PermMode; // resolved default permission mode
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
  // Models offered in the model step (backend-specific list; 7b supplies it).
  models: string[];
  // Named permission profiles offered as the quick path (§7A). Empty = raw only.
  profiles: string[];
  // Permission modes offered on the advanced path.
  permModes: PermMode[];
  // Folder browser (allowed roots / start path already configured by 7b).
  browser: DirectoryBrowser;
}

// A wizard select/button input. `id` is the component id ('backend', 'model',
// 'perm.mode', 'perm.profile', 'dir:into', 'dir:up', 'dir:here', 'confirm', 'cancel');
// `value` is the selected option value (for selects) or empty (for buttons).
export interface WizardInput {
  id: string;
  value?: string;
}

// The wizard's collected selections; the final confirm reads these.
interface Selection {
  cwd: string | null;
  backend: string;
  model: string;
  permMode: PermMode;
  profile: string | null;
}

export class ChannelWizard {
  private readonly opts: ChannelWizardOptions;
  private readonly browser: DirectoryBrowser;
  private step: WizardStep = 'folder';
  private readonly selection: Selection;
  // The Discord user who opened this wizard (the driver). Only they advance it, so a
  // bystander's stray select/button cannot corrupt another driver's flow (§7.1).
  readonly ownerId: string;

  constructor(options: ChannelWizardOptions) {
    this.opts = options;
    this.browser = options.browser;
    this.ownerId = options.ownerId;
    this.selection = {
      cwd: null,
      backend: options.defaults.backend,
      model: options.defaults.model,
      permMode: options.defaults.permMode,
      profile: options.defaults.profile,
    };
  }

  currentStep(): WizardStep {
    return this.step;
  }

  // The collected selection so far (read-only view for tests / status).
  current(): Readonly<Selection> {
    return { ...this.selection };
  }

  // Advance the state machine by one input. Returns the new step. Unknown inputs for
  // the current step are ignored (the step is unchanged) so a stray interaction does
  // not corrupt the flow. Confirm calls orchestrator.start.
  async handle(input: WizardInput): Promise<WizardStep> {
    if (input.id === 'cancel') {
      this.step = 'cancelled';
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
      case 'perm':
        this.handlePerm(input);
        break;
      case 'confirm':
        await this.handleConfirm(input);
        break;
      default:
        break; // done / cancelled: no further transitions
    }
    return this.step;
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

  private handleBackend(input: WizardInput): void {
    if (input.id === 'backend' && input.value) {
      this.selection.backend = input.value;
      this.step = 'model';
    }
  }

  private handleModel(input: WizardInput): void {
    if (input.id === 'model' && input.value) {
      this.selection.model = input.value;
      this.step = 'perm';
    }
  }

  // Permission step: a profile pick (quick path) OR a raw mode pick (advanced).
  private handlePerm(input: WizardInput): void {
    if (input.id === 'perm.profile' && input.value) {
      this.selection.profile = input.value === '__raw__' ? null : input.value;
      this.step = 'confirm';
    } else if (input.id === 'perm.mode' && input.value) {
      this.selection.permMode = input.value as PermMode;
      this.selection.profile = null; // raw mode clears any profile
      this.step = 'confirm';
    }
  }

  private async handleConfirm(input: WizardInput): Promise<void> {
    if (input.id !== 'confirm') return;
    if (this.selection.cwd === null) {
      // Should not happen (folder is step 1) — guard rather than start with no cwd.
      this.step = 'folder';
      return;
    }
    await this.opts.start({
      guildId: this.opts.guildId,
      channelId: this.opts.channelId,
      mode: this.selection.backend,
      cwd: this.selection.cwd,
      ownerId: this.opts.ownerId,
      permMode: this.selection.permMode,
      profile: this.selection.profile,
    });
    this.step = 'done';
  }

  // Render the current step as a plain component spec (embed + rows). 7b maps it onto
  // a discord.js reply/update. Pure data — the tests assert on it directly.
  render(): { embed: EmbedSpec; rows: ComponentRow[] } {
    switch (this.step) {
      case 'folder':
        return this.browser.render();
      case 'backend':
        return this.selectStep('wizard.step.backend', 'backend', this.opts.backends.map((b) => ({
          label: t(`backend.${b}`) === `backend.${b}` ? b : t(`backend.${b}`),
          value: b,
          default: b === this.selection.backend,
        })));
      case 'model':
        return this.selectStep('wizard.step.model', 'model', this.opts.models.map((m) => ({
          label: m,
          value: m,
          default: m === this.selection.model,
        })));
      case 'perm':
        return this.permStep();
      case 'confirm':
        return this.confirmStep();
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

  private selectStep(
    titleKey: string,
    id: string,
    options: SelectSpec['options'],
  ): { embed: EmbedSpec; rows: ComponentRow[] } {
    const select: SelectSpec = { type: 'select', customId: id, placeholder: t(titleKey), options };
    return {
      embed: { title: t('wizard.title'), description: t(titleKey) },
      rows: [{ components: [select] }, { components: [cancelButton()] }],
    };
  }

  // Quick path: profiles select (plus a "raw mode" option). Advanced: raw mode select.
  private permStep(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const rows: ComponentRow[] = [];
    if (this.opts.profiles.length > 0) {
      const profileSelect: SelectSpec = {
        type: 'select',
        customId: 'perm.profile',
        placeholder: t('wizard.step.perm'),
        options: [
          ...this.opts.profiles.map((p) => ({
            label: p,
            value: p,
            default: p === this.selection.profile,
          })),
          { label: t('wizard.profile.advanced'), value: '__raw__' },
        ],
      };
      rows.push({ components: [profileSelect] });
    }
    const modeSelect: SelectSpec = {
      type: 'select',
      customId: 'perm.mode',
      placeholder: t('wizard.profile.advanced'),
      options: this.opts.permModes.map((m) => ({
        label: t(`perm.${m}`),
        value: m,
        default: m === this.selection.permMode,
      })),
    };
    rows.push({ components: [modeSelect] });
    rows.push({ components: [cancelButton()] });
    return { embed: { title: t('wizard.title'), description: t('wizard.step.perm') }, rows };
  }

  private confirmStep(): { embed: EmbedSpec; rows: ComponentRow[] } {
    const permLabel = this.selection.profile ?? t(`perm.${this.selection.permMode}`);
    return {
      embed: {
        title: t('wizard.title'),
        description: t('wizard.confirm', {
          backend: this.selection.backend,
          cwd: this.selection.cwd ?? '',
          perm: permLabel,
        }),
      },
      rows: [
        {
          components: [
            { type: 'button', customId: 'confirm', label: t('dir.here'), style: 'success' },
            cancelButton(),
          ],
        },
      ],
    };
  }
}

function cancelButton() {
  return { type: 'button' as const, customId: 'cancel', label: t('wizard.cancelled'), style: 'secondary' as const };
}
