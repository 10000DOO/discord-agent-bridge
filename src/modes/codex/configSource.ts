import * as fs from 'node:fs';
import * as path from 'node:path';
import type { Logger, ModelChoice } from '../../core/contracts.js';
import { resolveCodexHome } from './resolveHome.js';

// Codex's DYNAMIC model/effort source (R1/R4/R5, D1/D2/D3). Instead of hardcoding the model
// and effort vocabulary, this serves the catalog from codex's local models_cache.json so a
// model added on the account surfaces without a bridge restart:
//   - `${codexHome}/models_cache.json` — models[] with slug, visibility, supported_reasoning_levels
// These are small local files, so they are read SYNCHRONOUSLY and cached in memory; a stat()
// mtime check re-reads only when the file actually changed (R1). Every read is fail-safe: any
// missing/unreadable/malformed file falls back to static constants and NEVER throws.
// Mirrors GrokConfigSource (modes/grok/configSource.ts). Fallback constants live HERE (not
// providerCatalog) so WO-2 can import this without a circular dependency.

// ---- Static fallbacks (used when the cache is absent, unreadable, or a model is missing) --
// Same ids as the former providerCatalog CODEX_MODEL_DEFAULTS list.
export const CODEX_MODEL_FALLBACK = [
  'gpt-5.5',
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.2-codex',
] as const;

// Canonical codex effort enum (model_reasoning_effort). Used as effortLevelsFor fallback when
// the model is absent from the cache, and as the isKnownEffort union base (D2/D4). Unlike Grok
// (received-only empty), Codex always offers a selectable effort list (R4).
export const CODEX_EFFORT_FALLBACK = ['minimal', 'low', 'medium', 'high', 'xhigh'] as const;

// ---- The subset of models_cache.json we read (all optional so a partial/older cache degrades
// gracefully; unrelated fields like base_instructions are ignored). -----------------------
interface CodexReasoningLevel {
  effort?: string;
}
interface CodexModelEntry {
  slug?: string;
  display_name?: string;
  visibility?: string;
  default_reasoning_level?: string;
  supported_reasoning_levels?: CodexReasoningLevel[];
}
interface CodexModelsCache {
  models?: CodexModelEntry[];
}

// ---- Injectable seams (default to real fs + resolved codex home) -------------------------
export type ReadFileSyncFn = (filePath: string) => string;
export type StatSyncFn = (filePath: string) => { mtimeMs: number };

export interface CodexConfigSourceOptions {
  readFileSync?: ReadFileSyncFn;
  statSync?: StatSyncFn;
  codexHome?: string;
  logger?: Logger;
}

export class CodexConfigSource {
  private readonly readFileSync: ReadFileSyncFn;
  private readonly statSync: StatSyncFn;
  private readonly codexHome: string;
  private readonly logger?: Logger;

  // Parsed models_cache.json (null → use the static fallback), plus the mtime it was read at so
  // a later call re-reads only when the file changed. `cacheWarned` gates the warn to once.
  private cache: CodexModelsCache | null = null;
  private cacheMtimeMs: number | undefined = undefined;
  private cacheWarned = false;

  constructor(options: CodexConfigSourceOptions = {}) {
    this.readFileSync = options.readFileSync ?? ((p) => fs.readFileSync(p, 'utf8'));
    this.statSync = options.statSync ?? ((p) => fs.statSync(p));
    this.codexHome = options.codexHome ?? resolveCodexHome(undefined);
    if (options.logger) this.logger = options.logger;
  }

  // Visible models from the cache (visibility === 'list', D3), each carrying its own effort
  // levels on supportedEffortLevels. Empty/absent cache → static fallback list.
  // `configured` non-empty is always first even when visibility is hide (persisted binding).
  models(configured?: string): ModelChoice[] {
    this.ensureCacheLoaded();
    const derived = this.listModels();
    const base =
      derived.length > 0
        ? derived
        : CODEX_MODEL_FALLBACK.map((m) => ({ value: m, label: m }));
    const def = this.defaultModel(configured);
    const rest = base.filter((m) => m.value !== def);
    const fromBase = base.find((m) => m.value === def);
    if (fromBase) return [fromBase, ...rest];
    // configured/hide model not in the list models — look up cache for label/efforts (D3).
    const entry = this.entryFor(def);
    const efforts = entry ? effortIdsFrom(entry) : [];
    const defChoice: ModelChoice = {
      value: def,
      label:
        entry && typeof entry.display_name === 'string' && entry.display_name.length > 0
          ? entry.display_name
          : def,
      ...(efforts.length > 0 ? { supportedEffortLevels: efforts } : {}),
    };
    return [defChoice, ...rest];
  }

  // Effort levels a specific model accepts (supported_reasoning_levels[].effort, cache order).
  // Model absent from cache or listing no efforts → CODEX_EFFORT_FALLBACK (R4: always selectable).
  effortLevelsFor(model: string): string[] {
    this.ensureCacheLoaded();
    const entry = this.entryFor(model);
    if (entry) {
      const ids = effortIdsFrom(entry);
      if (ids.length > 0) return ids;
    }
    return [...CODEX_EFFORT_FALLBACK];
  }

  // A model's default effort: default_reasoning_level when it is among the listed levels,
  // else 'medium' if listed, else the first level, else 'medium'.
  defaultEffortFor(model: string): string {
    const levels = this.effortLevelsFor(model);
    this.ensureCacheLoaded();
    const entry = this.entryFor(model);
    const marked =
      entry && typeof entry.default_reasoning_level === 'string'
        ? entry.default_reasoning_level
        : undefined;
    if (marked && levels.includes(marked)) return marked;
    if (levels.includes('medium')) return 'medium';
    if (levels.length > 0) return levels[0];
    return 'medium';
  }

  // The default model: configured if non-empty → first visibility=list model → first fallback.
  defaultModel(configured?: string): string {
    const trimmed = typeof configured === 'string' ? configured.trim() : '';
    if (trimmed.length > 0) return trimmed;
    this.ensureCacheLoaded();
    const derived = this.listModels();
    if (derived.length > 0) return derived[0].value;
    return CODEX_MODEL_FALLBACK[0];
  }

  // Guard for setEffort (R5): true when `value` is any cached model's advertised effort OR a
  // member of CODEX_EFFORT_FALLBACK, so a manually-typed /effort value codex would honor is
  // not dropped.
  isKnownEffort(value: string): boolean {
    this.ensureCacheLoaded();
    const known = new Set<string>(CODEX_EFFORT_FALLBACK);
    const models = this.cache?.models;
    if (Array.isArray(models)) {
      for (const entry of models) {
        for (const id of effortIdsFrom(entry)) known.add(id);
      }
    }
    return known.has(value);
  }

  // ---- Internals -------------------------------------------------------------------------

  // Models with visibility === 'list' only (D3). Hide entries are lookup-only for configured.
  private listModels(): ModelChoice[] {
    const models = this.cache?.models;
    if (!Array.isArray(models)) return [];
    const choices: ModelChoice[] = [];
    for (const entry of models) {
      if (!entry || typeof entry.slug !== 'string' || entry.slug.length === 0) continue;
      if (entry.visibility !== 'list') continue;
      const ids = effortIdsFrom(entry);
      choices.push({
        value: entry.slug,
        label:
          typeof entry.display_name === 'string' && entry.display_name.length > 0
            ? entry.display_name
            : entry.slug,
        ...(ids.length > 0 ? { supportedEffortLevels: ids } : {}),
      });
    }
    return choices;
  }

  // Look up a model entry by exact slug (hide included: a configured binding may reference a
  // now-hidden model and still needs its effort/label).
  private entryFor(model: string): CodexModelEntry | undefined {
    const models = this.cache?.models;
    if (!Array.isArray(models)) return undefined;
    for (const entry of models) {
      if (entry?.slug === model) return entry;
    }
    return undefined;
  }

  // stat() the cache and re-read only when the mtime changed (R1). An absent file falls back
  // silently; a read/parse failure warns once.
  private ensureCacheLoaded(): void {
    const cachePath = path.join(this.codexHome, 'models_cache.json');
    let mtimeMs: number;
    try {
      mtimeMs = this.statSync(cachePath).mtimeMs;
    } catch {
      this.cache = null;
      this.cacheMtimeMs = undefined;
      return;
    }
    if (this.cacheMtimeMs === mtimeMs) return;
    this.cacheMtimeMs = mtimeMs;
    try {
      this.cache = JSON.parse(this.readFileSync(cachePath)) as CodexModelsCache;
    } catch (error) {
      this.cache = null;
      if (!this.cacheWarned) {
        this.cacheWarned = true;
        this.logger?.warn('codex configSource: models_cache.json unreadable; using static fallback', {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }
}

// Effort ids for a model, in the cache's order (supported_reasoning_levels[].effort).
function effortIdsFrom(entry: CodexModelEntry): string[] {
  const levels = entry.supported_reasoning_levels;
  if (!Array.isArray(levels)) return [];
  const ids: string[] = [];
  for (const level of levels) {
    if (typeof level?.effort === 'string' && level.effort.length > 0) ids.push(level.effort);
  }
  return ids;
}

// Module singleton for WO-2 (codexCatalog) to consume.
export const codexConfigSource = new CodexConfigSource();
