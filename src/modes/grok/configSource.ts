import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import type { Logger, ModelChoice } from '../../core/contracts.js';

// Grok's DYNAMIC model/effort source (R1/R2, D1/D3). Instead of hardcoding the model and
// effort vocabulary, this serves the catalog's values from grok's own local structured config
// so a model added on the account surfaces without a bridge restart:
//   - `${GROK_HOME}/models_cache.json` — the catalog grok caches from its /v1/models endpoint
//     (per-model context_window, hidden flag, reasoning_efforts[]).
//   - `${GROK_HOME}/config.toml` — ONLY the `[models] default` key (the user's default model).
// These are small local files, so they are read SYNCHRONOUSLY and cached in memory; a stat()
// mtime check re-reads a file only when it actually changed (R1: "재시작 없이 노출"). Every read is
// fail-safe: any missing/unreadable/malformed file falls back to static constants and NEVER
// throws — the catalog must always answer. fs access and the grok home are injectable so the
// unit test drives this against a fixture with no real ~/.grok — mirroring the injectable-seam
// style of discovery.ts and the supportedEffortLevels attachment of providerCatalog.ts:229.

// ---- Static model fallback (used when the cache is absent or unreadable) -----------------
// models_cache may be incomplete (e.g. unauthenticated machine caches only grok-4.5 while the
// config default is grok-composer-2.5-fast) → the static list keeps both selectable (§8/D3).
const STATIC_MODELS = ['grok-4.5', 'grok-composer-2.5-fast'] as const;

// Grok's DOCUMENTED canonical reasoning-effort enum (14-headless-mode.md). Used ONLY by the
// isKnownEffort guard to accept a manually-typed /effort value grok would honor. NEVER used for
// display: effort options are RECEIVED-ONLY (a model's advertised reasoning_efforts), never
// fabricated from this set — an un-advertised model shows no effort options at all.
const CANONICAL_EFFORT_LEVELS = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'] as const;

// ---- The subset of models_cache.json we read (all optional so a partial/older cache degrades
// gracefully instead of throwing; unrelated fields are ignored). --------------------------
interface GrokReasoningEffort {
  id?: string;
  value?: string;
  default?: boolean;
}
interface GrokModelInfo {
  id?: string;
  name?: string;
  context_window?: number;
  hidden?: boolean;
  reasoning_effort?: string; // the model's default effort as a bare string
  reasoning_efforts?: GrokReasoningEffort[];
}
interface GrokModelEntry {
  info?: GrokModelInfo;
}
interface GrokModelsCache {
  models?: Record<string, GrokModelEntry>;
}

// ---- Injectable seams (default to real fs + resolved grok home) --------------------------
export type ReadFileSyncFn = (filePath: string) => string;
export type StatSyncFn = (filePath: string) => { mtimeMs: number };

export interface GrokConfigSourceOptions {
  readFileSync?: ReadFileSyncFn;
  statSync?: StatSyncFn;
  grokHome?: string;
  logger?: Logger;
}

// GROK_HOME overrides ~/.grok (14-headless-mode.md); empty/unset → <home>/.grok (mirrors the
// codex resolveCodexHome pattern, codex/index.ts:213). Exported so every grok path lookup
// (configSource here, GrokBuildMode.listResumable) resolves the home identically.
export function resolveGrokHome(): string {
  const env = process.env.GROK_HOME;
  return env && env.length > 0 ? env : path.join(os.homedir(), '.grok');
}

export class GrokConfigSource {
  private readonly readFileSync: ReadFileSyncFn;
  private readonly statSync: StatSyncFn;
  private readonly grokHome: string;
  private readonly logger?: Logger;

  // Parsed models_cache.json (null → use the static fallback), plus the mtime it was read at so
  // a later call re-reads only when the file changed. `cacheWarned` gates the warn to once.
  private cache: GrokModelsCache | null = null;
  private cacheMtimeMs: number | undefined = undefined;
  private cacheWarned = false;

  // The `[models] default` parsed from config.toml, cached the same mtime-gated way.
  private configDefault: string | undefined = undefined;
  private configMtimeMs: number | undefined = undefined;
  private configWarned = false;

  constructor(options: GrokConfigSourceOptions = {}) {
    this.readFileSync = options.readFileSync ?? ((p) => fs.readFileSync(p, 'utf8'));
    this.statSync = options.statSync ?? ((p) => fs.statSync(p));
    this.grokHome = options.grokHome ?? resolveGrokHome();
    if (options.logger) this.logger = options.logger;
  }

  // Visible models from the cache (hidden:true excluded, R1), each carrying its own effort
  // levels on supportedEffortLevels (providerCatalog.ts:229). Empty/absent cache → static list.
  models(): ModelChoice[] {
    this.ensureCacheLoaded();
    const derived = this.derivedModels();
    const base = derived.length > 0 ? derived : STATIC_MODELS.map((m) => ({ value: m, label: m }));
    const def = this.defaultModel(); // config.toml [models] default → cache first → static first
    // §8: the cache may omit the user's default model (incomplete cache) — always keep it
    // selectable, and first so the wizard pre-selects it (models[0]).
    const rest = base.filter((m) => m.value !== def);
    const defChoice = base.find((m) => m.value === def) ?? { value: def, label: def };
    return [defChoice, ...rest];
  }

  // Effort levels a specific model accepts (its reasoning_efforts[] ids, in cache order). A model
  // absent from the cache, or listing no efforts, → [] (RECEIVED-ONLY: never fabricated). The
  // wizard then skips the effort step and grok's own per-model default applies.
  effortLevelsFor(model: string): string[] {
    this.ensureCacheLoaded();
    const info = this.infoFor(model);
    if (info) {
      const ids = effortIdsFrom(info);
      if (ids.length > 0) return ids;
    }
    return [];
  }

  // A model's default effort: the reasoning_efforts[] entry flagged default:true, else the
  // per-model reasoning_effort string only when it is among the listed effort ids. A model with no
  // advertised effort → '' (RECEIVED-ONLY: never fabricated; grok's own default then applies).
  defaultEffortFor(model: string): string {
    this.ensureCacheLoaded();
    const info = this.infoFor(model);
    if (info) {
      const marked = (info.reasoning_efforts ?? []).find((e) => e?.default === true);
      const id = effortId(marked);
      if (id) return id;
      const ids = effortIdsFrom(info);
      if (typeof info.reasoning_effort === 'string' && ids.includes(info.reasoning_effort)) {
        return info.reasoning_effort;
      }
    }
    return '';
  }

  // The user's default model (D3 precedence): config.toml [models] default → first cache model →
  // first static model. The config default may be absent from the cache (e.g. the cache is
  // incomplete on an unauthenticated machine) — it still wins, as it is the user's stated choice.
  defaultModel(): string {
    this.ensureConfigLoaded();
    if (this.configDefault && this.configDefault.length > 0) return this.configDefault;
    this.ensureCacheLoaded();
    const derived = this.derivedModels();
    if (derived.length > 0) return derived[0].value;
    return STATIC_MODELS[0];
  }

  // A model's context window (models_cache), for the usage panel (WO-5/R9). Absent → undefined
  // so the caller can omit the panel.
  contextWindow(model: string): number | undefined {
    this.ensureCacheLoaded();
    const info = this.infoFor(model);
    return typeof info?.context_window === 'number' ? info.context_window : undefined;
  }

  // Guard for the runner's `-m` (R4): true when `value` is one of the models we would offer
  // (dynamic list or static fallback), so a leaked non-grok model id is dropped.
  isKnownModel(value: string): boolean {
    return this.models().some((m) => m.value === value);
  }

  // Guard for setEffort (R4): true when `value` is any cached model's advertised effort level OR a
  // member of grok's documented canonical enum, so a manually-typed /effort value grok would honor
  // is not dropped. The canonical set is used ONLY here — never to fabricate display options.
  isKnownEffort(value: string): boolean {
    this.ensureCacheLoaded();
    const known = new Set<string>(CANONICAL_EFFORT_LEVELS);
    const models = this.cache?.models;
    if (models) {
      for (const entry of Object.values(models)) {
        if (entry?.info) for (const id of effortIdsFrom(entry.info)) known.add(id);
      }
    }
    return known.has(value);
  }

  // ---- Internals -------------------------------------------------------------------------

  private derivedModels(): ModelChoice[] {
    const models = this.cache?.models;
    if (!models) return [];
    const choices: ModelChoice[] = [];
    for (const entry of Object.values(models)) {
      const info = entry?.info;
      if (!info || typeof info.id !== 'string' || info.id.length === 0) continue;
      if (info.hidden === true) continue; // R1: hidden models never surface
      const ids = effortIdsFrom(info);
      choices.push({
        value: info.id,
        label: typeof info.name === 'string' && info.name.length > 0 ? info.name : info.id,
        ...(ids.length > 0 ? { supportedEffortLevels: ids } : {}),
      });
    }
    return choices;
  }

  // Look up a model's info by exact id (hidden included: a persisted binding may reference a
  // now-hidden model and still needs its effort/context_window).
  private infoFor(model: string): GrokModelInfo | undefined {
    const models = this.cache?.models;
    if (!models) return undefined;
    for (const entry of Object.values(models)) {
      if (entry?.info?.id === model) return entry.info;
    }
    return undefined;
  }

  // stat() the cache and re-read only when the mtime changed (R1). An absent file falls back
  // silently (expected on an unauthenticated machine); a read/parse failure warns once.
  private ensureCacheLoaded(): void {
    const cachePath = path.join(this.grokHome, 'models_cache.json');
    let mtimeMs: number;
    try {
      mtimeMs = this.statSync(cachePath).mtimeMs;
    } catch {
      this.cache = null;
      this.cacheMtimeMs = undefined;
      return;
    }
    if (this.cacheMtimeMs === mtimeMs) return; // unchanged since the last read attempt
    this.cacheMtimeMs = mtimeMs;
    try {
      this.cache = JSON.parse(this.readFileSync(cachePath)) as GrokModelsCache;
    } catch (error) {
      this.cache = null;
      if (!this.cacheWarned) {
        this.cacheWarned = true;
        this.logger?.warn('grok configSource: models_cache.json unreadable; using static fallback', {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }

  // Same mtime-gated, fail-safe read for the one config.toml key we need.
  private ensureConfigLoaded(): void {
    const configPath = path.join(this.grokHome, 'config.toml');
    let mtimeMs: number;
    try {
      mtimeMs = this.statSync(configPath).mtimeMs;
    } catch {
      this.configDefault = undefined;
      this.configMtimeMs = undefined;
      return;
    }
    if (this.configMtimeMs === mtimeMs) return;
    this.configMtimeMs = mtimeMs;
    try {
      this.configDefault = parseModelsDefault(this.readFileSync(configPath));
    } catch (error) {
      this.configDefault = undefined;
      if (!this.configWarned) {
        this.configWarned = true;
        this.logger?.warn('grok configSource: config.toml unreadable; using cache/static default', {
          error: error instanceof Error ? error.message : String(error),
        });
      }
    }
  }
}

// Effort ids for a model, in the cache's order (prefer `id`, fall back to `value`).
function effortIdsFrom(info: GrokModelInfo): string[] {
  const efforts = info.reasoning_efforts;
  if (!Array.isArray(efforts)) return [];
  const ids: string[] = [];
  for (const effort of efforts) {
    const id = effortId(effort);
    if (id) ids.push(id);
  }
  return ids;
}

function effortId(effort: GrokReasoningEffort | undefined): string | undefined {
  if (!effort) return undefined;
  if (typeof effort.id === 'string' && effort.id.length > 0) return effort.id;
  if (typeof effort.value === 'string' && effort.value.length > 0) return effort.value;
  return undefined;
}

// Parse ONLY `[models] default = "..."` from config.toml. No TOML dependency exists (and the
// design forbids adding one), so we scan lines to find the [models] table, then apply a single
// regex to its `default` assignment — scoping to the table so a `default =` under another table
// is never misread. Anything unexpected → undefined (the caller falls back).
function parseModelsDefault(raw: string): string | undefined {
  let inModels = false;
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.startsWith('[')) {
      const header = trimmed.replace(/\s*#.*$/, '').trim(); // strip an inline comment after the table header
      inModels = header === '[models]'; // entering/leaving a table; only [models] counts
      continue;
    }
    if (!inModels) continue;
    const match = /^default\s*=\s*["']([^"']*)["']/.exec(trimmed);
    if (match && match[1].length > 0) return match[1];
  }
  return undefined;
}

// Module singleton for WO-2 (grokCatalog) to consume.
export const grokConfigSource = new GrokConfigSource();
