import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import * as os from 'node:os';
import * as path from 'node:path';
import {
  CodexConfigSource,
  CODEX_EFFORT_FALLBACK,
  CODEX_MODEL_FALLBACK,
} from './configSource.js';

// Slim measured-shape fixture: two visibility=list models with distinct effort sets plus
// two hide models (one configured in tests). Mirrors grok/configSource.test.ts temp-home style.
const FIXTURE_CACHE = readFileSync(
  fileURLToPath(new URL('./__fixtures__/models_cache.json', import.meta.url)),
  'utf8',
);

async function withCodexHome(
  files: { cache?: string },
  fn: (dir: string) => Promise<void>,
): Promise<void> {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'dab-codex-cfg-'));
  try {
    if (files.cache !== undefined) await writeFile(path.join(dir, 'models_cache.json'), files.cache, 'utf8');
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

function makeCache(entries: Array<{ slug: string; visibility?: string; efforts?: string[] }>): string {
  return JSON.stringify({
    models: entries.map((e) => ({
      slug: e.slug,
      display_name: e.slug,
      visibility: e.visibility ?? 'list',
      default_reasoning_level: e.efforts?.[0] ?? 'medium',
      supported_reasoning_levels: (e.efforts ?? ['medium']).map((effort) => ({ effort })),
    })),
  });
}

function enoent(): NodeJS.ErrnoException {
  const error: NodeJS.ErrnoException = new Error('ENOENT: no such file');
  error.code = 'ENOENT';
  return error;
}

describe('CodexConfigSource', () => {
  it('lists visibility=list models only (hide excluded) with per-model effort levels attached', async () => {
    await withCodexHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      const models = source.models();
      expect(models.map((m) => m.value)).toEqual(['gpt-5.5', 'codex-list-alt']);
      expect(models.some((m) => m.value === 'gpt-5.4')).toBe(false); // hide excluded
      expect(models.some((m) => m.value === 'gpt-5.4-mini')).toBe(false);
      const byValue = new Map(models.map((m) => [m.value, m]));
      expect(byValue.get('gpt-5.5')?.label).toBe('GPT-5.5');
      expect(byValue.get('gpt-5.5')?.supportedEffortLevels).toEqual(['low', 'medium', 'high', 'xhigh']);
      expect(byValue.get('codex-list-alt')?.supportedEffortLevels).toEqual(['high', 'xhigh']);
    });
  });

  it('puts a configured hide model first and looks up its label/efforts from the cache', async () => {
    await withCodexHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      const models = source.models('gpt-5.4');
      expect(models.map((m) => m.value)).toEqual(['gpt-5.4', 'gpt-5.5', 'codex-list-alt']);
      expect(models[0].label).toBe('GPT-5.4');
      expect(models[0].supportedEffortLevels).toEqual([
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
    });
  });

  it('derives per-model effort levels and defaults from the cache', async () => {
    await withCodexHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      // gpt-5.5: low/medium/high/xhigh, default_reasoning_level medium.
      expect(source.effortLevelsFor('gpt-5.5')).toEqual(['low', 'medium', 'high', 'xhigh']);
      expect(source.defaultEffortFor('gpt-5.5')).toBe('medium');
      // hide model still resolves efforts by slug (configured binding lookup).
      expect(source.effortLevelsFor('gpt-5.4')).toEqual([
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
      expect(source.defaultEffortFor('gpt-5.4-mini')).toBe('low'); // default_reasoning_level
      // list alt: only high/xhigh, default high.
      expect(source.effortLevelsFor('codex-list-alt')).toEqual(['high', 'xhigh']);
      expect(source.defaultEffortFor('codex-list-alt')).toBe('high');
    });
  });

  it('defaultEffortFor falls back to medium or first level when default is missing/invalid', async () => {
    const cache = JSON.stringify({
      models: [
        {
          slug: 'no-default',
          display_name: 'No Default',
          visibility: 'list',
          supported_reasoning_levels: [{ effort: 'low' }, { effort: 'high' }],
        },
        {
          slug: 'bad-default',
          display_name: 'Bad Default',
          visibility: 'list',
          default_reasoning_level: 'bogus',
          supported_reasoning_levels: [{ effort: 'minimal' }, { effort: 'high' }],
        },
        {
          slug: 'medium-available',
          visibility: 'list',
          default_reasoning_level: 'bogus',
          supported_reasoning_levels: [{ effort: 'low' }, { effort: 'medium' }],
        },
      ],
    });
    await withCodexHome({ cache }, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      // no default_reasoning_level, no medium → first level
      expect(source.defaultEffortFor('no-default')).toBe('low');
      // invalid default, no medium → first level
      expect(source.defaultEffortFor('bad-default')).toBe('minimal');
      // invalid default but medium is listed → medium
      expect(source.defaultEffortFor('medium-available')).toBe('medium');
    });
  });

  it('falls back to static models and full effort list when the cache is absent', async () => {
    await withCodexHome({}, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      expect(source.models().map((m) => m.value)).toEqual([...CODEX_MODEL_FALLBACK]);
      expect(source.defaultModel()).toBe('gpt-5.5');
      // No cache → effortLevelsFor uses CODEX_EFFORT_FALLBACK (R4; unlike Grok received-only []).
      expect(source.effortLevelsFor('gpt-5.5')).toEqual([...CODEX_EFFORT_FALLBACK]);
      expect(source.defaultEffortFor('gpt-5.5')).toBe('medium');
      expect(source.isKnownEffort('minimal')).toBe(true);
      expect(source.isKnownEffort('xhigh')).toBe(true);
      expect(source.isKnownEffort('bogus')).toBe(false);
    });
  });

  it('isKnownEffort accepts cache-advertised levels and canonical fallback', async () => {
    await withCodexHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      expect(source.isKnownEffort('low')).toBe(true); // advertised by gpt-5.5
      expect(source.isKnownEffort('minimal')).toBe(true); // hide model + fallback union
      expect(source.isKnownEffort('xhigh')).toBe(true);
      expect(source.isKnownEffort('bogus')).toBe(false);
    });
  });

  it('defaultModel honors configured, else first list model, else first fallback', async () => {
    await withCodexHome({ cache: FIXTURE_CACHE }, async (dir) => {
      const source = new CodexConfigSource({ codexHome: dir });
      expect(source.defaultModel('gpt-5.4-mini')).toBe('gpt-5.4-mini');
      expect(source.defaultModel('')).toBe('gpt-5.5');
      expect(source.defaultModel()).toBe('gpt-5.5');
    });
    await withCodexHome({}, async (dir) => {
      expect(new CodexConfigSource({ codexHome: dir }).defaultModel()).toBe(CODEX_MODEL_FALLBACK[0]);
    });
  });

  it('re-reads the cache when its mtime changes and serves cached data otherwise (R1)', () => {
    const cachePath = path.join('/fake/.codex', 'models_cache.json');
    let file = { content: makeCache([{ slug: 'gpt-5.5' }]), mtimeMs: 1000 };
    let reads = 0;
    const source = new CodexConfigSource({
      codexHome: '/fake/.codex',
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

    expect(source.models().map((m) => m.value)).toEqual(['gpt-5.5']);
    expect(reads).toBe(1);

    // Content changes underneath but mtime unchanged → served from cache, no re-read.
    file = {
      content: makeCache([{ slug: 'gpt-5.5' }, { slug: 'codex-list-alt' }]),
      mtimeMs: 1000,
    };
    expect(source.models().map((m) => m.value)).toEqual(['gpt-5.5']);
    expect(reads).toBe(1);

    // mtime bumped → re-read, new list model shows without restart.
    file = { content: file.content, mtimeMs: 2000 };
    expect(source.models().map((m) => m.value)).toEqual(['gpt-5.5', 'codex-list-alt']);
    expect(reads).toBe(2);
  });
});
