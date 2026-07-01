import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { ChannelWizard, type StartParams } from './channelWizard.js';
import { DirectoryBrowser } from '../directoryBrowser.js';
import type { ModeSession } from '../../core/contracts.js';

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

function makeWizard(start: (p: StartParams) => Promise<ModeSession>) {
  const browser = new DirectoryBrowser({ allowedRoots: [root], startPath: root });
  return new ChannelWizard({
    guildId: 'g1',
    channelId: 'c1',
    ownerId: 'u1',
    start,
    defaults: { backend: 'claude', model: 'opus', permMode: 'default', profile: null },
    backends: ['claude', 'codex'],
    models: ['opus', 'sonnet'],
    profiles: ['읽기전용', '수정허용'],
    permModes: ['default', 'plan', 'acceptEdits'],
    browser,
  });
}

describe('ChannelWizard state machine', () => {
  it('transitions folder → backend → model → perm → confirm and starts', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeSession());
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
    const start = vi.fn(async (_p: StartParams) => fakeSession());
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

  it('cancel from any step ends the flow without starting', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeSession());
    const wizard = makeWizard(start);
    await wizard.handle({ id: 'dir:here' });
    expect(await wizard.handle({ id: 'cancel' })).toBe('cancelled');
    expect(start).not.toHaveBeenCalled();
  });

  it('ignores a stray input for the current step', async () => {
    const start = vi.fn(async (_p: StartParams) => fakeSession());
    const wizard = makeWizard(start);
    // A 'backend' input during the folder step is ignored.
    expect(await wizard.handle({ id: 'backend', value: 'codex' })).toBe('folder');
    expect(wizard.current().backend).toBe('claude'); // unchanged default
  });
});
