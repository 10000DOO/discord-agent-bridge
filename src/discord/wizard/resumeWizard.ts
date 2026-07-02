import type { ModeSession, ResumableSession } from '../../core/contracts.js';
import type { ButtonSpec, ComponentRow, EmbedSpec, SelectSpec } from '../ports.js';
import { t } from '../i18n.js';

// The "Resume Session" flow started from the /agent start folder step (§9 on-demand
// resume). A small two-step state machine mirroring ChannelWizard's choice-step
// pattern (a select stores a pending value + re-renders; a confirm button advances):
//   backend  → pick the backend (dropdown + 다음)
//   pick     → pick a resumable session (dropdown; picking one RESUMES immediately)
// Works for BOTH backends: the backend step chooses which mode's listResumable runs
// (Claude via listSessions, Codex via CodexDiscovery). The cwd is the folder that was
// in view on the folder step, so resumable sessions are scoped to the picked project.
// Pure state + plain component specs — no discord.js — so 7b wires real interactions
// and tests drive it directly.

export type ResumeStep = 'backend' | 'pick' | 'done' | 'cancelled' | 'empty';

// The router-supplied resume callback: create/bind a session channel and resume the
// chosen session on it, returning the ModeSession + the channel id it bound to (the
// freshly created proj-<folder> channel, A4D-style). Mirrors ChannelWizard.StartFn.
export interface ResumeParams {
  guildId: string;
  channelId: string;
  ownerId: string;
  backend: string;
  cwd: string;
  sessionId: string;
}
export interface ResumeResult {
  session: ModeSession;
  channelId: string;
}
export type ResumeFn = (params: ResumeParams) => Promise<ResumeResult>;

export interface ResumeWizardOptions {
  guildId: string;
  channelId: string;
  ownerId: string;
  // The folder in view on the folder step; resumable sessions are scoped to it.
  cwd: string;
  // Backends offered in the backend step (modeRegistry.list()).
  backends: string[];
  // The default backend to pre-select (resolved config default).
  defaultBackend: string;
  // List resumable sessions for a backend + cwd (router wires mode.listResumable).
  listResumableFor: (backend: string, cwd: string) => Promise<ResumableSession[]>;
  // Resume the chosen session onto a fresh/bound session channel.
  resume: ResumeFn;
  // Rendered relative time for an updatedAt ISO string (router supplies the formatter).
  relativeTime: (updatedAt: string | undefined) => string;
}

interface ResumeSelection {
  backend: string;
}

export class ResumeWizard {
  private readonly opts: ResumeWizardOptions;
  private step: ResumeStep = 'backend';
  private readonly selection: ResumeSelection;
  private pendingBackend: string | undefined;
  // The sessions listed for the picked backend (rendered in the pick step).
  private sessions: ResumableSession[] = [];
  // The channel id the resumed session was bound to (null until resume succeeds).
  private resumedChannelId: string | null = null;
  readonly ownerId: string;

  constructor(options: ResumeWizardOptions) {
    this.opts = options;
    this.ownerId = options.ownerId;
    this.selection = { backend: options.defaultBackend };
  }

  currentStep(): ResumeStep {
    return this.step;
  }

  // The channel id the resumed session was bound to, or null before a successful
  // resume. The router links it back to the driver.
  sessionChannelId(): string | null {
    return this.resumedChannelId;
  }

  // Advance the flow by one input. Returns the new step. Unknown inputs are ignored.
  //   'resume.backend'        select → pending backend + re-render
  //   'resume.backend.next'   button → commit backend, list sessions, go to 'pick'
  //                                    (or 'empty' when the backend has none)
  //   'resume.pick'           select → RESUME the chosen session
  //   'cancel'                button → 'cancelled'
  async handle(input: { id: string; value?: string }): Promise<ResumeStep> {
    if (input.id === 'cancel') {
      this.step = 'cancelled';
      return this.step;
    }
    if (this.step === 'backend') {
      if (input.id === 'resume.backend' && input.value) {
        this.pendingBackend = input.value;
      } else if (input.id === 'resume.backend.next') {
        this.selection.backend = this.pendingBackend ?? this.selection.backend;
        this.pendingBackend = undefined;
        this.sessions = await this.opts.listResumableFor(this.selection.backend, this.opts.cwd);
        this.step = this.sessions.length === 0 ? 'empty' : 'pick';
      }
      return this.step;
    }
    if (this.step === 'pick') {
      if (input.id === 'resume.pick' && input.value) {
        await this.resumeSession(input.value);
      }
      return this.step;
    }
    return this.step; // done / cancelled / empty: terminal
  }

  private async resumeSession(sessionId: string): Promise<void> {
    // Guard against a stale/foreign id (must be one we listed).
    if (!this.sessions.some((s) => s.sessionId === sessionId)) return;
    const result = await this.opts.resume({
      guildId: this.opts.guildId,
      channelId: this.opts.channelId,
      ownerId: this.opts.ownerId,
      backend: this.selection.backend,
      cwd: this.opts.cwd,
      sessionId,
    });
    this.resumedChannelId = result.channelId;
    this.step = 'done';
  }

  // Render the current step as a plain component spec. 'empty'/'done'/'cancelled'
  // render a notice with no rows (the router surfaces the ephemeral message).
  render(): { embed: EmbedSpec; rows: ComponentRow[] } {
    switch (this.step) {
      case 'backend': {
        const select: SelectSpec = {
          type: 'select',
          customId: 'resume.backend',
          placeholder: t('resume.step.backend'),
          options: this.opts.backends.map((b) => ({
            label: t(`backend.${b}`) === `backend.${b}` ? b : t(`backend.${b}`),
            value: b,
            default: b === (this.pendingBackend ?? this.selection.backend),
          })),
        };
        const next: ButtonSpec = { type: 'button', customId: 'resume.backend.next', label: t('wizard.next'), style: 'primary' };
        return {
          embed: { title: t('wizard.title'), description: t('resume.step.backend') },
          rows: [{ components: [select] }, { components: [next, cancelButton()] }],
        };
      }
      case 'pick': {
        const select: SelectSpec = {
          type: 'select',
          customId: 'resume.pick',
          placeholder: t('resume.select.placeholder'),
          options: this.sessions.slice(0, 25).map((s) => ({
            label: clip(s.label ?? s.sessionId, 95),
            value: s.sessionId,
            description: this.opts.relativeTime(s.updatedAt),
          })),
        };
        return {
          embed: { title: t('wizard.title'), description: t('resume.step.pick') },
          rows: [{ components: [select] }, { components: [cancelButton()] }],
        };
      }
      case 'empty':
        return { embed: { title: t('wizard.title'), description: t('resume.none') }, rows: [] };
      case 'done':
        return { embed: { title: t('resume.status.title'), description: t('resume.done', { channel: '' }) }, rows: [] };
      case 'cancelled':
        return { embed: { title: t('wizard.title'), description: t('wizard.cancelled') }, rows: [] };
    }
  }
}

function cancelButton(): ButtonSpec {
  return { type: 'button', customId: 'cancel', label: t('wizard.cancel'), style: 'secondary' };
}

function clip(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1) + '…';
}
