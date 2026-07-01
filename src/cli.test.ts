import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock the two modules cli.ts dispatches to so no real bot boots and no real wizard
// runs. Spies are declared via vi.hoisted so they exist before the (hoisted)
// vi.mock factories reference them.
const { startBot, runSetup } = vi.hoisted(() => ({
  startBot: vi.fn(async () => ({}) as never),
  runSetup: vi.fn(async () => {}),
}));

vi.mock('./app.js', () => ({ startBot }));
vi.mock('./setup/wizard.js', () => ({ runSetup }));

import { run, readVersion } from './cli.js';

describe('cli.run — argv dispatch', () => {
  let logSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    startBot.mockClear();
    runSetup.mockClear();
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

  it('--setup calls runSetup and boots nothing', async () => {
    await run(['--setup']);
    expect(runSetup).toHaveBeenCalledTimes(1);
    expect(startBot).not.toHaveBeenCalled();
  });

  it('no flag calls startBot', async () => {
    await run([]);
    expect(startBot).toHaveBeenCalledTimes(1);
    expect(runSetup).not.toHaveBeenCalled();
  });
});
