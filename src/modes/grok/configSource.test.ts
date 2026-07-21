import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import * as os from 'node:os';
import * as path from 'node:path';
import { GrokConfigSource } from './configSource.js';

// The measured-shape fixture (grok 0.2.103): two visible models with distinct effort sets plus
// one hidden model, to exercise filtering + multi-model effort. Read as text (the same
// __fixtures__ convention as eventMapper.test.ts) and written into a temp grok home per test so
// the real fs seams are exercised with no dependency on a real ~/.grok.
const FIXTURE_CACHE = readFileSync(
  fileURLToPath(new URL('./__fixtures__/models_cache.json', import.meta.url)),
  'utf8',
);

async function withGrokHome(
  files: { cache?: string; config?: string },
  fn: (dir: string) => Promise<void>,
): Promise<void> {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'dab-grok-cfg-'));
  try {
    if (files.cache !== undefined) await writeFile(path.join(dir, 'models_cache.json'), files.cache, 'utf8');
    if (files.config !== undefined) await writeFile(path.join(dir, 'config.toml'), files.config, 'utf8');
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// A minimal models_cache with the given visible model ids (each with a single high-effort entry)
// — used by the mtime test where content/mtime must be controlled deterministically.
function makeCache(ids: string[]): string {
  const models: Record<string, unknown> = {};
  for (const id of ids) {
    models[id] = {
      info: {
        id,
        name: id,
        hidden: false,
        reasoning_effort: 'high',
        reasoning_efforts: [{ id: 'high', value: 'high', default: true }],
      },
    };
  }
  return JSON.stringify({ models });
}

function enoent(): NodeJS.ErrnoException {
  const error: NodeJS.ErrnoException = new Error('ENOENT: no such file');
  error.code = 'ENOENT';
  return error;
}

describe('GrokConfigSource', () => {
  it('lists visible models only (hidden excluded) with per-model effort levels attached', async () => {
    await withGrokHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      const models = source.models();
      expect(models.map((m) => m.value)).toEqual(['grok-4.5', 'grok-code-fast-1']);
      expect(models.some((m) => m.value === 'grok-4.5-preview')).toBe(false); // hidden:true excluded
      const byValue = new Map(models.map((m) => [m.value, m]));
      expect(byValue.get('grok-4.5')?.label).toBe('Grok 4.5'); // info.name → label
      expect(byValue.get('grok-4.5')?.supportedEffortLevels).toEqual(['high', 'medium', 'low']);
      expect(byValue.get('grok-code-fast-1')?.supportedEffortLevels).toEqual(['low', 'high']);
    });
  });

  it('derives per-model effort levels, defaults, and context window from the cache', async () => {
    await withGrokHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      // grok-4.5: reasoning_efforts high(default)/medium/low.
      expect(source.effortLevelsFor('grok-4.5')).toEqual(['high', 'medium', 'low']);
      expect(source.defaultEffortFor('grok-4.5')).toBe('high');
      // grok-code-fast-1: a different set with a different default (proves per-model derivation).
      expect(source.effortLevelsFor('grok-code-fast-1')).toEqual(['low', 'high']);
      expect(source.defaultEffortFor('grok-code-fast-1')).toBe('low');
      // grok-composer-2.5-fast is NOT in the fixture cache → RECEIVED-ONLY: no effort, no default.
      expect(source.effortLevelsFor('grok-composer-2.5-fast')).toEqual([]);
      expect(source.defaultEffortFor('grok-composer-2.5-fast')).toBe('');
      expect(source.contextWindow('grok-4.5')).toBe(500000);
      expect(source.contextWindow('grok-code-fast-1')).toBe(256000);
    });
  });

  it('returns received-only effort: a model with no advertised efforts (present or absent) → [] / ""', async () => {
    // A model present in the cache but advertising NO reasoning_efforts — composer's real shape.
    const cache = JSON.stringify({
      models: {
        'grok-composer-2.5-fast': {
          info: { id: 'grok-composer-2.5-fast', name: 'Composer', hidden: false },
        },
      },
    });
    await withGrokHome({ cache }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      // present but no reasoning_efforts → [] (never fabricated); default '' (grok's own applies).
      expect(source.effortLevelsFor('grok-composer-2.5-fast')).toEqual([]);
      expect(source.defaultEffortFor('grok-composer-2.5-fast')).toBe('');
      // a model entirely absent from the cache → the same received-only result.
      expect(source.effortLevelsFor('grok-4.5')).toEqual([]);
      expect(source.defaultEffortFor('grok-4.5')).toBe('');
    });
  });

  it('defaultEffortFor rejects a bare reasoning_effort absent from effortLevelsFor (received-only)', async () => {
    // reasoning_efforts lists low/high (no default:true) but the bare reasoning_effort is 'medium',
    // which is NOT among them → the mismatched bare value is rejected. With no default:true entry
    // and no valid bare value, the default is '' (received-only: never a fabricated selection).
    const cache = JSON.stringify({
      models: {
        'grok-x': {
          info: {
            id: 'grok-x',
            name: 'grok-x',
            hidden: false,
            reasoning_effort: 'medium',
            reasoning_efforts: [
              { id: 'low', value: 'low' },
              { id: 'high', value: 'high' },
            ],
          },
        },
      },
    });
    await withGrokHome({ cache }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      const levels = source.effortLevelsFor('grok-x');
      expect(levels).toEqual(['low', 'high']);
      const def = source.defaultEffortFor('grok-x');
      expect(def).not.toBe('medium'); // the bare value outside the listed efforts is not accepted
      expect(def).toBe(''); // no default:true + invalid bare → received-only empty, not fabricated
    });
  });

  it('accepts dynamic models/efforts and rejects leaked non-grok values (R4 guards)', async () => {
    await withGrokHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      expect(source.isKnownModel('grok-code-fast-1')).toBe(true); // dynamic, absent from static list
      expect(source.isKnownModel('claude-sonnet-4-5')).toBe(false); // leaked Claude id dropped
      expect(source.isKnownEffort('high')).toBe(true); // advertised by grok-4.5 in the fixture
      expect(source.isKnownEffort('max')).toBe(true); // canonical enum member (advertised by no model)
      expect(source.isKnownEffort('minimal')).toBe(true); // canonical enum member
      expect(source.isKnownEffort('bogus')).toBe(false);
    });
  });

  it('falls back to the static model list when the cache file is absent (effort stays received-only)', async () => {
    await withGrokHome({}, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      expect(source.models().map((m) => m.value)).toEqual(['grok-4.5', 'grok-composer-2.5-fast']);
      // No cache → no advertised effort for any model → received-only [] / '' (never fabricated).
      expect(source.effortLevelsFor('grok-4.5')).toEqual([]);
      expect(source.defaultEffortFor('grok-4.5')).toBe('');
      expect(source.defaultModel()).toBe('grok-4.5');
      expect(source.isKnownModel('grok-composer-2.5-fast')).toBe(true);
      expect(source.isKnownEffort('xhigh')).toBe(true); // canonical enum member — guard still accepts it
    });
  });

  it('defaultModel() falls back to the first cache model when config.toml is absent', async () => {
    await withGrokHome({ cache: FIXTURE_CACHE }, async (dir) => {
      expect(new GrokConfigSource({ grokHome: dir }).defaultModel()).toBe('grok-4.5');
    });
  });

  it('defaultModel() honors config.toml [models] default even when absent from the cache', async () => {
    const config = '[ui]\ncompact_mode = false\n\n[models]\ndefault = "grok-composer-2.5-fast"\n';
    await withGrokHome({ cache: FIXTURE_CACHE, config }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      // config default wins over the cache's first entry, even though it is not in the cache…
      expect(source.defaultModel()).toBe('grok-composer-2.5-fast');
      // …and models() merges it in, first, ahead of the cache-derived list (§8).
      expect(source.models().map((m) => m.value)).toEqual([
        'grok-composer-2.5-fast',
        'grok-4.5',
        'grok-code-fast-1',
      ]);
    });
  });

  it('models() surfaces the config default first when the cache omits it, keeping hidden excluded (§8)', async () => {
    // present-but-incomplete cache: the two visible fixture models, none of them the config default.
    const config = '[models]\ndefault = "grok-composer-2.5-fast"\n';
    await withGrokHome({ cache: FIXTURE_CACHE, config }, async (dir) => {
      const source = new GrokConfigSource({ grokHome: dir });
      const values = source.models().map((m) => m.value);
      // the user's default is FIRST (wizard pre-selects models[0]) …
      expect(values[0]).toBe('grok-composer-2.5-fast');
      // … followed by the cached, visible models …
      expect(values).toEqual(['grok-composer-2.5-fast', 'grok-4.5', 'grok-code-fast-1']);
      // … and the hidden model is still excluded after the merge.
      expect(values).not.toContain('grok-4.5-preview');
    });
  });

  it('defaultModel() ignores a decoy default under a non-[models] table (table scoping)', async () => {
    const config = '[mcp_servers.serena]\ndefault = "WRONG"\n\n[models]\ndefault = "grok-composer-2.5-fast"\n';
    await withGrokHome({ cache: FIXTURE_CACHE, config }, async (dir) => {
      expect(new GrokConfigSource({ grokHome: dir }).defaultModel()).toBe('grok-composer-2.5-fast');
    });
  });

  it('re-reads the cache when its mtime changes and serves cached data otherwise (R1)', () => {
    const cachePath = path.join('/fake/.grok', 'models_cache.json');
    let file = { content: makeCache(['grok-4.5']), mtimeMs: 1000 };
    let reads = 0;
    const source = new GrokConfigSource({
      grokHome: '/fake/.grok',
      statSync: (p) => {
        if (p === cachePath) return { mtimeMs: file.mtimeMs };
        throw enoent();
      },
      readFileSync: (p) => {
        if (p === cachePath) {
          reads++;
          return file.content;
        }
        throw enoent();
      },
    });

    expect(source.models().map((m) => m.value)).toEqual(['grok-4.5']);
    expect(reads).toBe(1);

    // Content changes underneath but the mtime is unchanged → served from cache, no re-read.
    file = { content: makeCache(['grok-4.5', 'grok-code-fast-1']), mtimeMs: 1000 };
    expect(source.models().map((m) => m.value)).toEqual(['grok-4.5']);
    expect(reads).toBe(1);

    // mtime bumped → re-read, and the new model shows up without a restart (R1).
    file = { content: file.content, mtimeMs: 2000 };
    expect(source.models().map((m) => m.value)).toEqual(['grok-4.5', 'grok-code-fast-1']);
    expect(reads).toBe(2);
  });
});
