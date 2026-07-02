import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock the three modules cli.ts dispatches to so no real bot boots, no real wizard
// runs, and no real config file is touched. Spies are declared via vi.hoisted so
// they exist before the (hoisted) vi.mock factories reference them.
//
// `exists`/`tokenPresent` drive the mocked ConfigStore's needsSetup inputs: exists()
// returns `exists`, and load() returns a config whose token is empty (needs setup)
// or non-empty (already configured) based on `tokenPresent`. A load() that should
// throw (invalid config) is exercised where noted.
const { startBot, runSetup, exists, load } = vi.hoisted(() => ({
  startBot: vi.fn(async () => ({}) as never),
  runSetup: vi.fn(async () => {}),
  exists: vi.fn(() => true),
  load: vi.fn(() => ({ discord: { token: 'present', clientId: 'client-id-000' } })),
}));

vi.mock('./app.js', () => ({ startBot }));
vi.mock('./setup/wizard.js', () => ({ runSetup }));
vi.mock('./core/config.js', () => ({
  ConfigStore: class {
    exists = exists;
    load = load;
  },
}));

import { run, readVersion } from './cli.js';

describe('cli.run — argv dispatch', () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    startBot.mockClear();
    runSetup.mockClear();
    exists.mockReset();
    load.mockReset();
    // Default: configured (config present, token present) so the no-flag path starts
    // directly unless a test opts into the first-run condition below.
    exists.mockReturnValue(true);
    load.mockReturnValue({ discord: { token: 'present', clientId: 'client-id-000' } });
    logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
  });
  afterEach(() => {
    logSpy.mockRestore();
  });

  it('--version prints the package version and boots nothing', async () => {
    await run(['--version']);
    expect(logSpy).toHaveBeenCalledWith(readVersion());
    // readVersion() reads the real package.json — assert it looks like a semver.
    expect(readVersion()).toMatch(/^\d+\.\d+\.\d+/);
    expect(startBot).not.toHaveBeenCalled();
    expect(runSetup).not.toHaveBeenCalled();
  });

  it('--setup calls runSetup only and boots nothing', async () => {
    await run(['--setup']);
    expect(runSetup).toHaveBeenCalledTimes(1);
    expect(startBot).not.toHaveBeenCalled();
    // --setup must not even probe config presence: it is an explicit re-configure.
    expect(exists).not.toHaveBeenCalled();
  });

  it('no flag + no config → runs setup THEN starts the bot (in that order)', async () => {
    exists.mockReturnValue(false); // no config.json → needs setup

    await run([]);

    expect(runSetup).toHaveBeenCalledTimes(1);
    expect(startBot).toHaveBeenCalledTimes(1);
    // Order: setup must complete before the bot starts.
    expect(runSetup.mock.invocationCallOrder[0]).toBeLessThan(
      startBot.mock.invocationCallOrder[0]!,
    );
    // load() is never consulted when the file does not exist.
    expect(load).not.toHaveBeenCalled();
  });

  it('no flag + config present with empty token → runs setup THEN starts the bot', async () => {
    exists.mockReturnValue(true);
    load.mockReturnValue({ discord: { token: '   ', clientId: 'client-id-000' } });

    await run([]);

    expect(runSetup).toHaveBeenCalledTimes(1);
    expect(startBot).toHaveBeenCalledTimes(1);
    expect(runSetup.mock.invocationCallOrder[0]).toBeLessThan(
      startBot.mock.invocationCallOrder[0]!,
    );
  });

  it('no flag + config present and valid → starts the bot only (setup NOT called)', async () => {
    // Defaults from beforeEach: exists()=true, token present.
    await run([]);

    expect(startBot).toHaveBeenCalledTimes(1);
    expect(runSetup).not.toHaveBeenCalled();
  });

  it('no flag + present-but-invalid config → error propagates (no auto-setup swallow)', async () => {
    exists.mockReturnValue(true);
    load.mockImplementation(() => {
      throw new Error('invalid config');
    });

    await expect(run([])).rejects.toThrow('invalid config');
    // A real config bug must not trigger the wizard or a bot start.
    expect(runSetup).not.toHaveBeenCalled();
    expect(startBot).not.toHaveBeenCalled();
  });
});
