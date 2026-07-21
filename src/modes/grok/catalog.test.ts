import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import * as path from 'node:path';
import {
  createGrokCatalog,
  grokCatalog,
  isGrokModel,
  isGrokEffort,
  GROK_PERMISSION_MODES,
} from './catalog.js';
import { GrokConfigSource } from './configSource.js';

// Model/effort values are now DYNAMIC (served from GrokConfigSource, WO-1). The module singleton
// reads the real ~/.grok, so its exact lists are machine-dependent — assertions on models/effort
// use a fixture-backed source injected through the createGrokCatalog factory for determinism.
// Static bits (the honest permission menu, the guards' machine-independent cases) test the
// production exports directly.
const FIXTURE_CACHE = readFileSync(
  fileURLToPath(new URL('./__fixtures__/models_cache.json', import.meta.url)),
  'utf8',
);

function enoent(): NodeJS.ErrnoException {
  const error: NodeJS.ErrnoException = new Error('ENOENT: no such file');
  error.code = 'ENOENT';
  return error;
}

// A GrokConfigSource wired to the measured-shape fixture (two visible models with distinct effort
// sets, one hidden) with no config.toml — so defaultModel() falls back to the first cache model
// (grok-4.5) deterministically.
function fixtureSource(): GrokConfigSource {
  const cachePath = path.join('/fake/.grok', 'models_cache.json');
  return new GrokConfigSource({
    grokHome: '/fake/.grok',
    statSync: (p) => {
      if (p === cachePath) return { mtimeMs: 1 };
      throw enoent();
    },
    readFileSync: (p) => {
      if (p === cachePath) return FIXTURE_CACHE;
      throw enoent();
    },
  });
}

describe('grokCatalog', () => {
  it('serves the dynamic visible models (hidden excluded) with per-model effort attached', () => {
    const catalog = createGrokCatalog(fixtureSource());
    expect(catalog.models()).toEqual([
      { value: 'grok-4.5', label: 'Grok 4.5', supportedEffortLevels: ['high', 'medium', 'low'] },
      { value: 'grok-code-fast-1', label: 'Grok Code Fast 1', supportedEffortLevels: ['low', 'high'] },
    ]);
  });

  it('offers exactly the two enforced permission modes with honest hint labels (D4)', () => {
    const choices = grokCatalog.permissionChoices();
    expect(choices.map((c) => c.value)).toEqual(['bypassPermissions', 'default']);
    expect(choices[0]?.label).toBe('bypassPermissions (auto-approve all tools)');
    expect(choices[1]?.label).toBe('default (prompts are cancelled — tools are skipped)');
  });

  it('reflects only the chosen model: supported set verbatim, empty/undefined → [] (received-only)', () => {
    const catalog = createGrokCatalog(fixtureSource());
    // The chosen model's supported levels are used verbatim (drives the wizard/`/config` step).
    expect(catalog.effortChoices(['high', 'medium', 'low']).map((c) => c.value)).toEqual(['high', 'medium', 'low']);
    expect(catalog.runtimeEffortChoices(['high', 'medium', 'low']).map((c) => c.value)).toEqual(['high', 'medium', 'low']);
    // No advertised effort (model not in cache / no reasoning_efforts) → [] so the wizard skips
    // the effort step; NO borrow from the default model.
    expect(catalog.effortChoices(undefined)).toEqual([]);
    expect(catalog.effortChoices([])).toEqual([]);
    expect(catalog.runtimeEffortChoices(undefined)).toEqual([]);
    expect(catalog.runtimeEffortChoices([])).toEqual([]);
  });

  it('pre-selects the default model default effort in the wizard', () => {
    // grok-4.5's reasoning_efforts marks high as default:true.
    expect(createGrokCatalog(fixtureSource()).defaultEffort()).toBe('high');
  });
});

describe('isGrokModel', () => {
  it('rejects a leaked Claude/Codex model', () => {
    // Positive membership (a known grok model → true) is fixture-backed in configSource.test.ts;
    // isGrokModel binds to the module singleton (real ~/.grok), so a positive here would be
    // machine-dependent. Only the machine-independent negatives belong here.
    expect(isGrokModel('opus')).toBe(false);
    expect(isGrokModel('gpt-5.5')).toBe(false);
    expect(isGrokModel('')).toBe(false);
  });
});

describe('isGrokEffort', () => {
  it("accepts grok's canonical effort enum (none…max) and rejects the rest", () => {
    // The canonical enum is always known regardless of the machine's cache (guard-only, not display).
    for (const e of ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']) expect(isGrokEffort(e)).toBe(true);
    expect(isGrokEffort('bogus')).toBe(false);
    expect(isGrokEffort('')).toBe(false);
  });
});

describe('GROK_PERMISSION_MODES', () => {
  it('is exactly the two enforced modes (bypassPermissions, default)', () => {
    expect([...GROK_PERMISSION_MODES]).toEqual(['bypassPermissions', 'default']);
  });
});
