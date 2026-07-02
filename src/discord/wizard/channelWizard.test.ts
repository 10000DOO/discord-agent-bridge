import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { ChannelWizard, type StartFn, type StartParams, type StartResult } from './channelWizard.js';
import { DirectoryBrowser } from '../directoryBrowser.js';
import type { ModeSession } from '../../core/contracts.js';
import { permissionModeChoices } from '../../core/providerCatalog.js';

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

function makeWizard(start: StartFn) {
  const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
  return new ChannelWizard({
    guildId: 'g1',
    channelId: 'c1',
    ownerId: 'u1',
    start,
    defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
    backends: ['claude', 'codex'],
    // English {value,label} pairs from the provider catalog, as the router supplies.
    models: [
      { value: 'opus', label: 'opus' },
      { value: 'sonnet', label: 'sonnet' },
    ],
    profiles: ['읽기전용', '수정허용'],
    permModes: permissionModeChoices('claude'),
    browser,
  });
}

describe('ChannelWizard state machine', () => {
  it('transitions folder → backend → model → perm → confirm and starts', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);

    expect(wizard.currentStep()).toBe('folder');

    // Folder: descend into 'project' then select it.
    await wizard.handle({ id: 'dir:into', value: 'project' });
    expect(wizard.current().cwd).toBeNull(); // not selected yet
    expect(await wizard.handle({ id: 'dir:here' })).toBe('backend');
    expect(wizard.current().cwd).toBe(path.join(root, 'project'));

    // Backend
    expect(await wizard.handle({ id: 'backend', value: 'codex' })).toBe('model');
    expect(wizard.current().backend).toBe('codex');

    // Model
    expect(await wizard.handle({ id: 'model', value: 'sonnet' })).toBe('perm');
    expect(wizard.current().model).toBe('sonnet');

    // Permission — pick a profile (quick path)
    expect(await wizard.handle({ id: 'perm.profile', value: '수정허용' })).toBe('confirm');
    expect(wizard.current().profile).toBe('수정허용');

    // Confirm → start called with the selected values
    expect(await wizard.handle({ id: 'confirm' })).toBe('done');
    expect(start).toHaveBeenCalledTimes(1);
    expect(start).toHaveBeenCalledWith({
      guildId: 'g1',
      channelId: 'c1',
      mode: 'codex',
      cwd: path.join(root, 'project'),
      ownerId: 'u1',
      permMode: 'default',
      profile: '수정허용',
    });
  });

  it('advanced path: raw permission mode clears any profile', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' }); // select root as cwd
    await wizard.handle({ id: 'backend', value: 'claude' });
    await wizard.handle({ id: 'model', value: 'opus' });
    await wizard.handle({ id: 'perm.mode', value: 'plan' });
    expect(wizard.currentStep()).toBe('confirm');
    expect(wizard.current().permMode).toBe('plan');
    expect(wizard.current().profile).toBeNull();

    await wizard.handle({ id: 'confirm' });
    expect(start).toHaveBeenCalledWith(
      expect.objectContaining({ mode: 'claude', permMode: 'plan', profile: null }),
    );
  });

  it('exposes the created session channel id after confirm', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend', value: 'claude' });
    await wizard.handle({ id: 'model', value: 'opus' });
    await wizard.handle({ id: 'perm.mode', value: 'default' });
    expect(wizard.sessionChannelId()).toBeNull(); // not confirmed yet
    await wizard.handle({ id: 'confirm' });
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
});

describe('ChannelWizard render (step guidance + labels)', () => {
  function componentsOf(rows: { components: { type: string; customId: string; label?: string }[] }[]) {
    return rows.flatMap((r) => r.components);
  }

  it('the folder step renders the browser guidance + current path, and a ✅ start button', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    const { embed, rows } = wizard.render();
    // The folder step is A4D-style: guidance + current path + a dir:here start button.
    expect(embed.description).toContain('프로젝트 폴더');
    expect(embed.description).toContain(root);
    const dirHere = componentsOf(rows).find((c) => c.customId === 'dir:here');
    expect(dirHere?.label).toContain('시작');
  });

  it('the folder step returns NON-EMPTY component rows: subfolder select + ⬆ up / ✅ start', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    const { rows } = wizard.render();
    // The rows must never be empty — that emptiness was the LIVE bug (nothing to click).
    expect(rows.length).toBeGreaterThan(0);
    const flat = componentsOf(rows);
    // Subfolder navigation select listing the child dir 'project'.
    const select = flat.find((c) => c.type === 'select' && c.customId === 'dir:into') as
      | { options: { value: string }[] }
      | undefined;
    expect(select).toBeDefined();
    expect(select?.options.map((o) => o.value)).toContain('project');
    // Both navigation buttons are present.
    expect(flat.some((c) => c.type === 'button' && c.customId === 'dir:up')).toBe(true);
    expect(flat.some((c) => c.type === 'button' && c.customId === 'dir:here')).toBe(true);
  });

  it('"이 폴더로 시작" selects the current folder as cwd and advances to the backend step', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    // Descend into a subfolder, then select it with dir:here.
    await wizard.handle({ id: 'dir:into', value: 'project' });
    expect(await wizard.handle({ id: 'dir:here' })).toBe('backend');
    expect(wizard.current().cwd).toBe(path.join(root, 'project'));
    // The backend step announces its step number in the guidance.
    expect(wizard.render().embed.description).toContain('백엔드');
  });

  it('the model + permission OPTION labels are the original ENGLISH (no Korean)', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend', value: 'claude' });
    // Model step: labels are the English model ids.
    const modelSelect = wizard
      .render()
      .rows.flatMap((r) => r.components)
      .find((c) => c.customId === 'model') as { options: { value: string; label: string }[] } | undefined;
    expect(modelSelect?.options.map((o) => o.label)).toEqual(['opus', 'sonnet']);

    await wizard.handle({ id: 'model', value: 'opus' });
    // Permission step: labels are the English identifier + a short English hint.
    const permSelect = wizard
      .render()
      .rows.flatMap((r) => r.components)
      .find((c) => c.customId === 'perm.mode') as { options: { value: string; label: string }[] } | undefined;
    const byValue = (v: string) => permSelect?.options.find((o) => o.value === v);
    expect(byValue('default')?.label).toBe('default (ask each time)');
    expect(byValue('plan')?.label).toBe('plan (read-only planning)');
    const hangul = /[가-힣]/;
    for (const o of permSelect?.options ?? []) expect(hangul.test(o.label)).toBe(false);
    // Old Korean labels are gone.
    const labels = permSelect?.options.map((o) => o.label) ?? [];
    expect(labels).not.toContain('플랜 (읽기 전용)');
  });

  it('the confirm step uses a ✅ 시작 button, not a folder label', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeStartResult());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    await wizard.handle({ id: 'backend', value: 'claude' });
    await wizard.handle({ id: 'model', value: 'opus' });
    await wizard.handle({ id: 'perm.mode', value: 'plan' });
    expect(wizard.currentStep()).toBe('confirm');
    const confirm = componentsOf(wizard.render().rows).find((c) => c.customId === 'confirm');
    expect(confirm?.label).toContain('시작');
    // The cancel button is a short label, not a full sentence.
    const cancel = componentsOf(wizard.render().rows).find((c) => c.customId === 'cancel');
    expect(cancel?.label).toBe('취소');
  });
});
