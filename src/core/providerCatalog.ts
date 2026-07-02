import {
  query as realQuery,
  type ModelInfo,
  type Options,
  type PermissionMode,
  type Query,
  type SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { Logger, PermMode } from './contracts.js';

// The ONE source of truth for the model + permission-mode option lists offered in
// the Discord dropdowns (/config defaults and /agent start wizard). Both consumers
// read from here, choosing the list by the selected backend, so the two UIs never
// drift. Labels are the ORIGINAL ENGLISH names/identifiers — no Korean translation
// of the selectable option values (surrounding guidance text stays localized).

// A single dropdown option: `value` is what we persist/pass to the backend, `label`
// is the English text shown in the menu.
export interface ModelChoice {
  value: string;
  label: string;
}

// ---- Claude permission modes — TIED to the installed SDK's PermissionMode type ----
// `satisfies readonly PermissionMode[]` binds this list to the SDK: if a future SDK
// version adds or removes a mode, this constant fails to compile until it is synced,
// so new modes surface on upgrade instead of silently going missing. All SDK-declared
// modes are exposed; we pass `permissionMode` natively to the SDK, so every one works.
export const CLAUDE_PERMISSION_MODES = [
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
  'dontAsk',
  'auto',
] as const satisfies readonly PermissionMode[];

// Codex permission modes = ONLY the subset that maps to codex approval/sandbox flags
// (see modes/codex/runner.ts permModeArgs). Codex has no mapping for 'dontAsk'/'auto',
// so they are deliberately excluded from the Codex list (honest per-backend limits).
export const CODEX_PERMISSION_MODES = [
  'default',
  'acceptEdits',
  'bypassPermissions',
  'plan',
] as const satisfies readonly PermMode[];

// Short English hint appended in parens to a permission-mode label. NO Korean here —
// these are the selectable option labels the user wants in the original English.
const PERM_MODE_HINTS: Record<PermissionMode, string> = {
  default: 'ask each time',
  acceptEdits: 'auto-approve edits',
  bypassPermissions: 'auto-approve all',
  plan: 'read-only planning',
  dontAsk: 'deny if not pre-approved',
  auto: 'model-classified',
};

// English label for a permission mode: the identifier plus a short English hint,
// e.g. `bypassPermissions (auto-approve all)`. Never localized.
export function permissionModeLabel(mode: PermissionMode): string {
  return `${mode} (${PERM_MODE_HINTS[mode]})`;
}

// The permission-mode option list for a backend, as {value,label} with English labels.
export function permissionModeChoices(backend: string): ModelChoice[] {
  const modes: readonly PermissionMode[] =
    backend === 'codex' ? CODEX_PERMISSION_MODES : CLAUDE_PERMISSION_MODES;
  return modes.map((m) => ({ value: m, label: permissionModeLabel(m) }));
}

// ---- Claude models — DYNAMIC (runtime, cached) -------------------------------
// Friendly aliases used as the graceful fallback when the SDK cannot report models
// (API-key-only auth, offline, timeout). English, so the dropdown never breaks.
export const CLAUDE_MODEL_FALLBACK: readonly string[] = ['opus', 'sonnet', 'haiku'];

// How long we wait for supportedModels() before giving up and using the fallback.
const SUPPORTED_MODELS_TIMEOUT_MS = 5_000;

// The injectable query() seam (mirrors modes/claude/session.ts QueryFn) so tests
// supply a fake that returns a scripted Query exposing supportedModels() — no real
// SDK, no network.
export type QueryFn = (params: { prompt: AsyncIterable<SDKUserMessage>; options?: Options }) => Query;

// Module-level cache: the resolved English model list is fetched ONCE and reused.
// We cache the ModelChoice[] itself (not the promise) so a failed fetch is not
// memoized — a later render can retry (and will still fall back safely meanwhile).
let cachedClaudeModels: ModelChoice[] | null = null;
// In-flight fetch shared by concurrent callers so we never launch two probe queries.
let inFlight: Promise<ModelChoice[]> | null = null;

// Reset the cache (tests only) so each case starts from a cold catalog.
export function __resetClaudeModelCache(): void {
  cachedClaudeModels = null;
  inFlight = null;
}

// A prompt stream that yields nothing and ends immediately: we only need the query
// object alive long enough to answer the supportedModels() control request. No user
// turn is ever sent, so this never spends tokens.
async function* emptyPrompt(): AsyncGenerator<SDKUserMessage> {
  // Intentionally empty: end the stream at once.
}

// Fetch the Claude model list from the SDK's supportedModels() and map each to an
// English {value,label} (value = model id, label = the SDK's displayName). Runs a
// short-lived query() purely to reach the control request, races it against a
// timeout, and always closes the query. Any failure resolves to the alias fallback.
async function fetchClaudeModels(queryFn: QueryFn, logger?: Logger): Promise<ModelChoice[]> {
  let q: Query | null = null;
  try {
    q = queryFn({ prompt: emptyPrompt() });
    const models = await withTimeout(q.supportedModels(), SUPPORTED_MODELS_TIMEOUT_MS);
    const choices = models
      .filter((m): m is ModelInfo => Boolean(m && typeof m.value === 'string' && m.value.length > 0))
      .map((m) => ({ value: m.value, label: m.displayName || m.value }));
    if (choices.length === 0) return fallbackChoices();
    return choices;
  } catch (err) {
    logger?.debug('providerCatalog: supportedModels() unavailable; using alias fallback', {
      error: err instanceof Error ? err.message : String(err),
    });
    return fallbackChoices();
  } finally {
    try {
      q?.close();
    } catch {
      // Closing an already-finished probe query is a no-op we can ignore.
    }
  }
}

function fallbackChoices(): ModelChoice[] {
  return CLAUDE_MODEL_FALLBACK.map((m) => ({ value: m, label: m }));
}

// Resolve a promise or the timeout, whichever comes first. A timeout rejects so the
// caller falls back to the aliases.
function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`supportedModels() timed out after ${ms}ms`)), ms);
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}

// The Claude model list as English {value,label}. Cached: the first call fetches
// (via the SDK), later calls reuse the cached list. Concurrent callers share one
// in-flight fetch. On failure the fallback is returned but NOT cached, so a later
// call can retry once auth/network is available.
export async function getClaudeModels(deps: { queryFn?: QueryFn; logger?: Logger } = {}): Promise<ModelChoice[]> {
  if (cachedClaudeModels) return cachedClaudeModels;
  if (inFlight) return inFlight;

  const queryFn = deps.queryFn ?? (realQuery as QueryFn);
  inFlight = fetchClaudeModels(queryFn, deps.logger)
    .then((choices) => {
      // Cache only a real (non-fallback) result so a transient failure can retry.
      const isFallback =
        choices.length === CLAUDE_MODEL_FALLBACK.length &&
        choices.every((c, i) => c.value === CLAUDE_MODEL_FALLBACK[i]);
      if (!isFallback) cachedClaudeModels = choices;
      return choices;
    })
    .finally(() => {
      inFlight = null;
    });
  return inFlight;
}

// The Claude model list WITHOUT blocking: returns the cached English list if present,
// otherwise kicks off the async fetch (fire-and-forget) and returns the alias fallback
// for THIS render. Lets an interaction ack immediately; the next render sees the cache.
export function getClaudeModelsCachedOrFallback(deps: { queryFn?: QueryFn; logger?: Logger } = {}): ModelChoice[] {
  if (cachedClaudeModels) return cachedClaudeModels;
  void getClaudeModels(deps); // warm the cache for the next render
  return fallbackChoices();
}

// ---- Codex models — honest static default (NOT auto-fetched) -----------------
// Codex has no model-list API and `-m` is free-form (verified against CLI 0.142.4),
// so this is a documented convenience list, not a dynamic source. A configured
// non-empty codexModel is offered first (de-duplicated). English ids.
const CODEX_MODEL_DEFAULTS: readonly string[] = ['gpt-5.1-codex', 'gpt-5-codex', 'o3'];

// The Codex model option list as English {value,label} (label = id). `configured`
// is config.defaults.codexModel: when non-empty it leads the list.
export function getCodexModels(configured = ''): ModelChoice[] {
  const trimmed = configured.trim();
  const ids =
    trimmed.length === 0
      ? [...CODEX_MODEL_DEFAULTS]
      : [trimmed, ...CODEX_MODEL_DEFAULTS.filter((m) => m !== trimmed)];
  return ids.map((id) => ({ value: id, label: id }));
}
