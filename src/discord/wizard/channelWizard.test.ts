import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { ChannelWizard, type StartFn, type StartParams, type StartResult } from './channelWizard.js';
import { DirectoryBrowser } from '../directoryBrowser.js';
import type { ModelChoice, ModeSession } from '../../core/contracts.js';
import {
  permissionChoicesFor,
  effortChoicesFor,
  defaultEffortFor,
  codexSandboxChoices,
} from '../../core/providerCatalog.js';

let root: string;

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'dab-wizard-'));
  fs.mkdirSync(path.join(root, 'project'));
});
afterEach(() => {
  fs.rmSync(root, { recursive: true, force: true });
});

function fakeSession(): ModeSession {
  return { sessionId: 'sess-1', async send() {}, async stop() {} };
}

// The router creates a dedicated session channel and binds there; the wizard's start
// callback returns that new channel id alongside the session.
function fakeStartResult(): StartResult {
  return { session: fakeSession(), channelId: 'new-session-channel' };
}

// Backend-aware option suppliers, mirroring what the router injects.
const CLAUDE_MODELS: ModelChoice[] = [
  { value: 'opus', label: 'opus' },
  { value: 'sonnet', label: 'sonnet' },
];
const CODEX_MODELS: ModelChoice[] = [
  { value: 'gpt-5.5', label: 'gpt-5.5' },
  { value: 'gpt-5.4', label: 'gpt-5.4' },
];

function makeWizard(start: StartFn) {
  const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
  return new ChannelWizard({
    guildId: 'g1',
    channelId: 'c1',
    ownerId: 'u1',
    start,
    defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
    backends: ['claude', 'codex'],
    modelsFor: (b) => (b === 'codex' ? CODEX_MODELS : CLAUDE_MODELS),
    profiles: ['읽기전용', '수정허용'],
    permsFor: (b) => permissionChoicesFor(b),
    effortsFor: (b, model) => effortChoicesFor(b, CLAUDE_MODELS.find((m) => m.value === model)?.supportedEffortLevels),
    defaultEffortFor,
    browser,
  });
}

// A wizard with NO profiles, so the permission step shows only the raw/sandbox select.
function makeWizardNoProfiles(start: StartFn) {
  const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
  return new ChannelWizard({
    guildId: 'g1',
    channelId: 'c1',
    ownerId: 'u1',
    start,
    defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
    backends: ['claude', 'codex'],
    modelsFor: (b) => (b === 'codex' ? CODEX_MODELS : CLAUDE_MODELS),
    profiles: [],
    permsFor: (b) => permissionChoicesFor(b),
    effortsFor: (b) => effortChoicesFor(b),
    defaultEffortFor,
    browser,
  });
}

function flat(rows: { components: { type: string; customId: string; label?: string; options?: { value: string; label: string; default?: boolean }[] }[] }[]) {
  return rows.flatMap((r) => r.components);
}
function selectOptions(wizard: ChannelWizard, customId: string) {
  const c = flat(wizard.render().rows).find((x) => x.customId === customId);
  return c?.options ?? [];
}

describe('ChannelWizard state machine (button-advance, backend-aware)', () => {
  it('advances folder → backend → model → effort → perm and starts on the perm.start button', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);

    expect(wizard.currentStep()).toBe('folder');

    // Folder: descend into 'project' then select it.
    await wizard.handle({ id: 'dir:into', value: 'project' });
    expect(wizard.current().cwd).toBeNull(); // not selected yet
    expect(await wizard.handle({ id: 'dir:here' })).toBe('backend');
    expect(wizard.current().cwd).toBe(path.join(root, 'project'));

    // Backend: a select-change does NOT advance; the 다음 button does.
    expect(await wizard.handle({ id: 'backend', value: 'codex' })).toBe('backend');
    expect(wizard.current().backend).toBe('claude'); // not committed yet
    expect(await wizard.handle({ id: 'backend.next' })).toBe('model');
    expect(wizard.current().backend).toBe('codex');

    // Model
    expect(await wizard.handle({ id: 'model', value: 'gpt-5.4' })).toBe('model'); // no advance on change
    expect(await wizard.handle({ id: 'model.next' })).toBe('effort');
    expect(wizard.current().model).toBe('gpt-5.4');

    // Reasoning effort
    expect(await wizard.handle({ id: 'effort', value: 'high' })).toBe('effort'); // no advance on change
    expect(await wizard.handle({ id: 'effort.next' })).toBe('perm');
    expect(wizard.current().effort).toBe('high');

    // Permission — pick a profile (Claude quick path), then the ✅ 시작 button starts.
    expect(await wizard.handle({ id: 'perm.profile', value: '수정허용' })).toBe('perm'); // no advance on change
    expect(await wizard.handle({ id: 'perm.start' })).toBe('done');
    expect(wizard.current().profile).toBe('수정허용');
    expect(start).toHaveBeenCalledTimes(1);
    expect(start).toHaveBeenCalledWith({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'codex',
      cwd: path.join(root, 'project'),
      ownerId: 'u1',
      // Switching to codex reset permMode to codex's first sandbox mode (read-only); the
      // profile pick rides its own channel and does not change permMode.
      permMode: 'read-only',
      profile: '수정허용',
      effort: 'high',
      // The dropdown pick (non-default: codex reset the model to gpt-5.5) reaches start.
      model: 'gpt-5.4',
    });
  });

  // REGRESSION for the reported bug: keeping the pre-selected default and pressing the
  // step's button (WITHOUT any select-change) must advance. Discord does not re-fire a
  // select interaction for the already-selected option, so advancing on change alone
  // left a user who kept the default stuck.
  it('keeping every default and pressing the buttons advances all the way to start', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    expect(await wizard.handle({ id: 'dir:here' })).toBe('backend');
    // No select-change on any step — only the confirm buttons.
    expect(await wizard.handle({ id: 'backend.next' })).toBe('model');
    expect(await wizard.handle({ id: 'model.next' })).toBe('effort');
    expect(await wizard.handle({ id: 'effort.next' })).toBe('perm');
    expect(await wizard.handle({ id: 'perm.start' })).toBe('done');
    expect(start).toHaveBeenCalledOnce();
    // Defaults carried through: claude backend, default model, high effort, default
    // permission, no profile — an untouched model dropdown still reaches start.
    expect(start).toHaveBeenCalledWith(
      expect.objectContaining({ mode: 'claude', model: 'opus', effort: 'high', permMode: 'default', profile: null }),
    );
  });

  it('skips the effort step when the backend offers no effort options (§6)', async () => {
    // A backend whose catalog has no reasoning-effort concept: effortsFor returns [].
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const wizard = new ChannelWizard({
      guildId: 'g1',
      channelId: 'c1',
      ownerId: 'u1',
      start,
      defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
      backends: ['claude'],
      modelsFor: () => CLAUDE_MODELS,
      profiles: [],
      permsFor: (b) => permissionChoicesFor(b),
      effortsFor: () => [],
      defaultEffortFor: () => '',
      browser,
    });
    expect(await wizard.handle({ id: 'dir:here' })).toBe('backend');
    expect(await wizard.handle({ id: 'backend.next' })).toBe('model');
    // model.next jumps straight to perm — the effort step is omitted.
    expect(await wizard.handle({ id: 'model.next' })).toBe('perm');
    expect(await wizard.handle({ id: 'perm.start' })).toBe('done');
    expect(start).toHaveBeenCalledOnce();
    // No effort was collected, so start receives an empty effort (backend uses its own).
    expect(start).toHaveBeenCalledWith(expect.objectContaining({ mode: 'claude', effort: '' }));
  });

  it('a select-change updates PENDING state (shown selected) without advancing the step', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    // Change the backend select to codex — step stays 'backend' and the option renders
    // as default-selected, but the committed backend is still claude.
    await wizard.handle({ id: 'backend', value: 'codex' });
    expect(wizard.currentStep()).toBe('backend');
    expect(wizard.current().backend).toBe('claude');
    const codexOpt = selectOptions(wizard, 'backend').find((o) => o.value === 'codex');
    expect(codexOpt?.default).toBe(true);
  });

  it('after selecting Codex, the model step shows CODEX models and the perm step shows CODEX sandbox terms', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend', value: 'codex' });
    await wizard.handle({ id: 'backend.next' }); // commit codex → model step

    // Model options are the Codex models, not Claude's.
    expect(selectOptions(wizard, 'model').map((o) => o.value)).toEqual(['gpt-5.5', 'gpt-5.4']);

    await wizard.handle({ id: 'model.next' }); // effort step
    // Codex effort options include 'minimal' (Codex-only) and NOT Claude's 'max'.
    const effortValues = selectOptions(wizard, 'effort').map((o) => o.value);
    expect(effortValues).toContain('minimal');
    expect(effortValues).not.toContain('max');

    await wizard.handle({ id: 'effort.next' }); // perm step
    // Permission options are Codex sandbox terms (perm.mode select), not Claude modes.
    const permValues = selectOptions(wizard, 'perm.mode').map((o) => o.value);
    expect(permValues).toEqual(['read-only', 'workspace-write', 'danger-full-access']);
    expect(permValues).not.toContain('acceptEdits');
  });

  it('after selecting Claude, the model step shows CLAUDE models and the perm step shows CLAUDE modes', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' }); // keep claude
    expect(selectOptions(wizard, 'model').map((o) => o.value)).toEqual(['opus', 'sonnet']);
    await wizard.handle({ id: 'model.next' });
    // Claude effort options include 'max' and NOT Codex's 'minimal'.
    const effortValues = selectOptions(wizard, 'effort').map((o) => o.value);
    expect(effortValues).toContain('max');
    expect(effortValues).not.toContain('minimal');
    await wizard.handle({ id: 'effort.next' });
    const permValues = selectOptions(wizard, 'perm.mode').map((o) => o.value);
    expect(permValues).toContain('acceptEdits');
    expect(permValues).toContain('dontAsk');
    expect(permValues).not.toContain('workspace-write');
  });

  it('a Codex sandbox permission pick rides the permMode channel to start', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend', value: 'codex' });
    await wizard.handle({ id: 'backend.next' });
    await wizard.handle({ id: 'model.next' });
    await wizard.handle({ id: 'effort.next' });
    await wizard.handle({ id: 'perm.mode', value: 'danger-full-access' });
    await wizard.handle({ id: 'perm.start' });
    expect(start).toHaveBeenCalledWith(
      expect.objectContaining({ mode: 'codex', permMode: 'danger-full-access', profile: null }),
    );
  });

  it('advanced path: a raw permission mode clears any profile', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' }); // select root as cwd
    await wizard.handle({ id: 'backend.next' }); // keep claude
    await wizard.handle({ id: 'model.next' }); // keep opus
    await wizard.handle({ id: 'effort.next' }); // keep high
    await wizard.handle({ id: 'perm.mode', value: 'plan' });
    await wizard.handle({ id: 'perm.start' });
    expect(start).toHaveBeenCalledWith(
      expect.objectContaining({ mode: 'claude', permMode: 'plan', profile: null }),
    );
  });

  it('exposes the created session channel id after start', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' });
    await wizard.handle({ id: 'model.next' });
    await wizard.handle({ id: 'effort.next' });
    expect(wizard.sessionChannelId()).toBeNull(); // not started yet
    await wizard.handle({ id: 'perm.start' });
    expect(wizard.sessionChannelId()).toBe('new-session-channel');
  });

  it('cancel from any step ends the flow without starting', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    expect(await wizard.handle({ id: 'cancel' })).toBe('cancelled');
    expect(start).not.toHaveBeenCalled();
  });

  it('ignores a stray input for the current step', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    // A 'backend' input during the folder step is ignored.
    expect(await wizard.handle({ id: 'backend', value: 'codex' })).toBe('folder');
    expect(wizard.current().backend).toBe('claude'); // unchanged default
  });

  it('wizard.back walks perm → effort → model → backend → folder', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' });
    await wizard.handle({ id: 'model.next' });
    await wizard.handle({ id: 'effort.next' });
    expect(wizard.currentStep()).toBe('perm');
    expect(await wizard.handle({ id: 'wizard.back' })).toBe('effort');
    expect(await wizard.handle({ id: 'wizard.back' })).toBe('model');
    expect(await wizard.handle({ id: 'wizard.back' })).toBe('backend');
    expect(await wizard.handle({ id: 'wizard.back' })).toBe('folder');
    // The first step has nothing before it — a stray back is a no-op.
    expect(await wizard.handle({ id: 'wizard.back' })).toBe('folder');
    expect(start).not.toHaveBeenCalled();
  });

  it('wizard.back keeps committed selections, so re-advancing shows the previous pick pre-selected', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    // Commit codex, advance to model, then step back to the backend step.
    await wizard.handle({ id: 'backend', value: 'codex' });
    await wizard.handle({ id: 'backend.next' });
    expect(wizard.currentStep()).toBe('model');
    await wizard.handle({ id: 'wizard.back' });
    expect(wizard.currentStep()).toBe('backend');
    // The committed backend survived the back — codex renders pre-selected.
    expect(wizard.current().backend).toBe('codex');
    expect(selectOptions(wizard, 'backend').find((o) => o.value === 'codex')?.default).toBe(true);
    // Re-advancing lands on codex's model catalog, as if back never happened.
    await wizard.handle({ id: 'backend.next' });
    expect(selectOptions(wizard, 'model').map((o) => o.value)).toEqual(CODEX_MODELS.map((m) => m.value));
  });

  it("wizard.back discards the current step's un-confirmed pending pick", async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' });
    // Touch the model dropdown (pending only), then back out and return.
    await wizard.handle({ id: 'model', value: 'sonnet' });
    await wizard.handle({ id: 'wizard.back' });
    await wizard.handle({ id: 'backend.next' });
    // The un-confirmed sonnet was dropped — the committed default is selected again.
    expect(wizard.current().model).toBe('opus');
    expect(selectOptions(wizard, 'model').find((o) => o.value === 'opus')?.default).toBe(true);
  });

  it('wizard.back from perm skips the effort step when the backend has none (mirrors the forward skip)', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const wizard = new ChannelWizard({
      guildId: 'g1',
      channelId: 'c1',
      ownerId: 'u1',
      start,
      defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
      backends: ['claude'],
      modelsFor: () => CLAUDE_MODELS,
      profiles: [],
      permsFor: (b) => permissionChoicesFor(b),
      effortsFor: () => [],
      defaultEffortFor: () => '',
      browser,
    });
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' });
    expect(await wizard.handle({ id: 'model.next' })).toBe('perm'); // forward skip
    expect(await wizard.handle({ id: 'wizard.back' })).toBe('model'); // backward skip
  });
});

describe('ChannelWizard render (step guidance + labels + buttons)', () => {
  function componentsOf(rows: { components: { type: string; customId: string; label?: string }[] }[]) {
    return rows.flatMap((r) => r.components);
  }

  it('the folder step renders the browser guidance + current path, and a ✅ start button', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    const { embed, rows } = wizard.render();
    expect(embed.description).toContain('프로젝트 폴더');
    expect(embed.description).toContain(root);
    const dirHere = componentsOf(rows).find((c) => c.customId === 'dir:here');
    expect(dirHere?.label).toContain('시작');
  });

  it('each choice step carries a "다음" button (backend/model/effort) so the button advances, not the select', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    // backend step
    expect(componentsOf(wizard.render().rows).find((c) => c.customId === 'backend.next')?.label).toBe('다음');
    await wizard.handle({ id: 'backend.next' });
    // model step
    expect(componentsOf(wizard.render().rows).find((c) => c.customId === 'model.next')?.label).toBe('다음');
    await wizard.handle({ id: 'model.next' });
    // effort step
    expect(componentsOf(wizard.render().rows).find((c) => c.customId === 'effort.next')?.label).toBe('다음');
  });

  it('the permission step (final) uses a ✅ 시작 button (perm.start), not a 다음 button', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' });
    await wizard.handle({ id: 'model.next' });
    await wizard.handle({ id: 'effort.next' });
    expect(wizard.currentStep()).toBe('perm');
    const startBtn = componentsOf(wizard.render().rows).find((c) => c.customId === 'perm.start');
    expect(startBtn?.label).toContain('시작');
    // The cancel button is a short label, not a full sentence.
    const cancel = componentsOf(wizard.render().rows).find((c) => c.customId === 'cancel');
    expect(cancel?.label).toBe('취소');
  });

  it('every step after the folder carries a "⬅ 이전" back button; the folder step does not', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    const backOn = () => componentsOf(wizard.render().rows).find((c) => c.customId === 'wizard.back');
    // Folder is the first step — nothing to go back to.
    expect(backOn()).toBeUndefined();
    await wizard.handle({ id: 'dir:here' });
    expect(backOn()?.label).toBe('⬅ 이전'); // backend
    await wizard.handle({ id: 'backend.next' });
    expect(backOn()?.label).toBe('⬅ 이전'); // model
    await wizard.handle({ id: 'model.next' });
    expect(backOn()?.label).toBe('⬅ 이전'); // effort
    await wizard.handle({ id: 'effort.next' });
    expect(backOn()?.label).toBe('⬅ 이전'); // perm (final)
  });

  it('the model + permission OPTION labels are the original ENGLISH (no Korean)', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizardNoProfiles(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend.next' }); // claude
    expect(selectOptions(wizard, 'model').map((o) => o.label)).toEqual(['opus', 'sonnet']);
    await wizard.handle({ id: 'model.next' });
    await wizard.handle({ id: 'effort.next' });
    const permSelect = selectOptions(wizard, 'perm.mode');
    const byValue = (v: string) => permSelect.find((o) => o.value === v);
    expect(byValue('default')?.label).toBe('default (ask each time)');
    expect(byValue('plan')?.label).toBe('plan (read-only planning)');
    const hangul = /[가-힣]/;
    for (const o of permSelect) expect(hangul.test(o.label)).toBe(false);
  });

  it('the "custom" backend option is named after the resolved provider when injected', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const wizard = new ChannelWizard({
      guildId: 'g1',
      channelId: 'c1',
      ownerId: 'u1',
      start,
      defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
      backends: ['claude', 'custom'],
      customBackendLabel: 'Custom (kimi-k2.7-code)',
      modelsFor: () => CLAUDE_MODELS,
      profiles: [],
      permsFor: (b) => permissionChoicesFor(b),
      effortsFor: (b) => effortChoicesFor(b),
      defaultEffortFor,
      browser,
    });
    await wizard.handle({ id: 'dir:here' });
    const custom = selectOptions(wizard, 'backend').find((o) => o.value === 'custom');
    expect(custom?.label).toBe('Custom (kimi-k2.7-code)');
  });

  it('falls back to the plain i18n label when no custom-backend label is injected', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
    const wizard = new ChannelWizard({
      guildId: 'g1',
      channelId: 'c1',
      ownerId: 'u1',
      start,
      defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
      backends: ['claude', 'custom'],
      modelsFor: () => CLAUDE_MODELS,
      profiles: [],
      permsFor: (b) => permissionChoicesFor(b),
      effortsFor: (b) => effortChoicesFor(b),
      defaultEffortFor,
      browser,
    });
    await wizard.handle({ id: 'dir:here' });
    const custom = selectOptions(wizard, 'backend').find((o) => o.value === 'custom');
    expect(custom?.label).toBe('Custom');
  });
});

// Guard the exported Codex sandbox catalog stays the three documented sandbox modes.
describe('codexSandboxChoices', () => {
  it('offers exactly read-only / workspace-write / danger-full-access with English labels', () => {
    const choices = codexSandboxChoices();
    expect(choices.map((c) => c.value)).toEqual(['read-only', 'workspace-write', 'danger-full-access']);
    const hangul = /[가-힣]/;
    for (const c of choices) expect(hangul.test(c.label)).toBe(false);
  });
});
