import {
  query as realQuery,
  type EffortLevel,
  type ModelInfo,
  type Options,
  type PermissionMode,
  type Query,
  type SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import type { Logger, ModeCatalog, ModelChoice, PermMode } from './contracts.js';

// The ONE source of truth for the model + permission-mode option lists offered in
// the Discord dropdowns (/config defaults and /agent start wizard). Both consumers
// read from here, choosing the list by the selected backend, so the two UIs never
// drift. Labels are the ORIGINAL ENGLISH names/identifiers — no Korean translation
// of the selectable option values (surrounding guidance text stays localized).

// ModelChoice (the dropdown option shape) now lives in contracts.ts so ModeCatalog can
// reference it without a layer-inverting import; the functions below still return it.

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
// (see modes/codex/policy.ts resolveThreadPolicy). Codex has no mapping for 'dontAsk'/'auto',
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

// ---- Codex-NATIVE sandbox permission choices --------------------------------
// Codex does NOT use Claude's permission-mode vocabulary; its own model is sandbox +
// approval. The permission step therefore offers Codex's actual sandbox values so the
// operator sees Codex terms, not Claude ones. modes/codex/policy resolveThreadPolicy
// maps each to app-server approvalPolicy + sandbox. `danger-full-access` is the bypass.
export const CODEX_SANDBOX_MODES = ['read-only', 'workspace-write', 'danger-full-access'] as const;
export type CodexSandboxMode = (typeof CODEX_SANDBOX_MODES)[number];

// True when `value` is a Codex-native sandbox mode (vs a Claude PermMode). Lets the
// runner and wizard tell the two vocabularies apart without a separate type channel.
export function isCodexSandboxMode(value: string): value is CodexSandboxMode {
  return (CODEX_SANDBOX_MODES as readonly string[]).includes(value);
}

// Short English hint appended in parens to a Codex sandbox label. English only — these
// are the selectable option labels, wanted verbatim.
const CODEX_SANDBOX_HINTS: Record<CodexSandboxMode, string> = {
  'read-only': 'read-only, ask to run',
  'workspace-write': 'write in workspace',
  'danger-full-access': 'no sandbox (⚠ dangerous)',
};

// The Codex sandbox permission option list as English {value,label}, e.g.
// `workspace-write (write in workspace)`. Never localized.
export function codexSandboxChoices(): ModelChoice[] {
  return CODEX_SANDBOX_MODES.map((m) => ({ value: m, label: `${m} (${CODEX_SANDBOX_HINTS[m]})` }));
}

// The permission OPTION list for the wizard's permission step, keyed by backend: Codex
// shows its native sandbox modes; every other backend shows the Claude PermMode list.
export function permissionChoicesFor(backend: string): ModelChoice[] {
  return backend === 'codex' ? codexSandboxChoices() : permissionModeChoices(backend);
}

// ---- Reasoning-effort choices (per-backend) ---------------------------------
// Claude effort levels — TIED to the SDK's EffortLevel so the list can't drift: if a
// future SDK adds/removes a level this fails to compile until synced. Passed to the
// SDK's `options.effort`. A model may narrow this via ModelInfo.supportedEffortLevels.
export const CLAUDE_EFFORT_LEVELS = [
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
] as const satisfies readonly EffortLevel[];

// Claude effort levels settable at RUNTIME on a live session via
// query.applyFlagSettings({ effortLevel }). This is the SDK's Settings.effortLevel
// domain, which EXCLUDES 'max' — 'max' is only settable at session start via
// options.effort, not mid-session. Drives the /effort autocomplete for a Claude channel
// and guards the Claude session's setEffort (see modes/claude/session.ts).
export const CLAUDE_RUNTIME_EFFORT_LEVELS = [
  'low',
  'medium',
  'high',
  'xhigh',
] as const satisfies readonly EffortLevel[];
export type ClaudeRuntimeEffort = (typeof CLAUDE_RUNTIME_EFFORT_LEVELS)[number];

// True when `value` is a Claude effort level settable at runtime (the applyFlagSettings
// domain — 'max' excluded). Narrows the string so it can be passed to the SDK.
export function isClaudeRuntimeEffort(value: string): value is ClaudeRuntimeEffort {
  return (CLAUDE_RUNTIME_EFFORT_LEVELS as readonly string[]).includes(value);
}

// Codex reasoning-effort values accepted by `-c model_reasoning_effort="…"` (verified
// against developers.openai.com/codex/config-reference, 2026-07). The operator's own
// config uses 'medium', which is the sensible default here too.
export const CODEX_EFFORT_LEVELS = ['minimal', 'low', 'medium', 'high', 'xhigh'] as const;
export type CodexEffortLevel = (typeof CODEX_EFFORT_LEVELS)[number];

// True when `value` is a Codex reasoning-effort level `-c model_reasoning_effort` accepts.
// Guards CodexSession.setEffort (mirrors isClaudeRuntimeEffort) so a /effort value typed
// outside the autocomplete list can't be persisted and fail every subsequent `codex exec`.
export function isCodexEffort(value: string): value is CodexEffortLevel {
  return (CODEX_EFFORT_LEVELS as readonly string[]).includes(value);
}

// The default reasoning effort offered pre-selected in the wizard per backend. Claude's
// SDK default is 'high'; Codex's practical default (and the operator's config) is 'medium'.
export function defaultEffortFor(backend: string): string {
  return backend === 'codex' ? 'medium' : 'high';
}

// The reasoning-effort OPTION list for the wizard's effort step, keyed by backend and —
// for Claude — narrowed to a model's supported levels when the SDK reports them. Labels
// are the plain English level names. `supportedClaudeLevels`, when non-empty, replaces
// the full Claude list (e.g. a model with only low/medium/high).
export function effortChoicesFor(backend: string, supportedClaudeLevels?: readonly string[]): ModelChoice[] {
  if (backend === 'codex') {
    return CODEX_EFFORT_LEVELS.map((e) => ({ value: e, label: e }));
  }
  const levels =
    supportedClaudeLevels && supportedClaudeLevels.length > 0
      ? supportedClaudeLevels
      : CLAUDE_EFFORT_LEVELS;
  return levels.map((e) => ({ value: e, label: e }));
}

// The reasoning-effort option list for the LIVE `/effort` command, keyed by backend.
// Unlike effortChoicesFor (the wizard's start-time list, which for Claude includes
// 'max'), this returns only levels that can be changed mid-session: Codex → the full
// CODEX_EFFORT_LEVELS; Claude → the runtime-settable set {low,medium,high,xhigh},
// further narrowed to the chosen model's supportedEffortLevels (∩) when the SDK reports
// them. 'max' is never offered here because query.applyFlagSettings cannot set it.
export function runtimeEffortChoicesFor(backend: string, supportedClaudeLevels?: readonly string[]): ModelChoice[] {
  if (backend === 'codex') {
    return CODEX_EFFORT_LEVELS.map((e) => ({ value: e, label: e }));
  }
  const levels =
    supportedClaudeLevels && supportedClaudeLevels.length > 0
      ? CLAUDE_RUNTIME_EFFORT_LEVELS.filter((l) => supportedClaudeLevels.includes(l))
      : CLAUDE_RUNTIME_EFFORT_LEVELS;
  return levels.map((e) => ({ value: e, label: e }));
}

// ---- Claude models — DYNAMIC (runtime, cached) -------------------------------
// Friendly aliases used as the graceful fallback when the SDK cannot report models
// (API-key-only auth, offline, timeout). English, so the dropdown never breaks.
export const CLAUDE_MODEL_FALLBACK: readonly string[] = ['opus', 'sonnet', 'haiku'];

// How long we wait for supportedModels() before giving up and using the fallback.
// The probe spawns the SDK's native CLI, whose cold init routinely exceeds 5s on this
// host — a 5s budget races the probe and usually loses, silently hiding new models.
// Wizard/config opens sit behind a deferred reply, so a longer wait is tolerable.
const SUPPORTED_MODELS_TIMEOUT_MS = 15_000;

// The injectable query() seam (mirrors modes/claude/session.ts QueryFn) so tests
// supply a fake that returns a scripted Query exposing supportedModels() — no real
// SDK, no network.
export type QueryFn = (params: { prompt: AsyncIterable<SDKUserMessage>; options?: Options }) => Query;

// In-flight fetch shared by concurrent callers within the same tick so a burst of
// interactions (e.g. `/config` re-open) does not launch two probe queries at once.
// NO cross-invocation cache: every logical open re-probes the SDK, so a model added
// or removed on the account reflects on the next open.
let inFlight: Promise<ModelChoice[]> | null = null;

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
      .map((m) => ({
        value: m.value,
        label: m.displayName || m.value,
        ...(m.supportedEffortLevels && m.supportedEffortLevels.length > 0
          ? { supportedEffortLevels: [...m.supportedEffortLevels] }
          : {}),
      }));
    if (choices.length === 0) return fallbackChoices();
    return choices;
  } catch (err) {
    logger?.warn('providerCatalog: supportedModels() unavailable; using alias fallback', {
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

// The Claude model list as English {value,label}. Always fetches live from the SDK
// so a model added or removed on the account is reflected on the very next call.
// Concurrent callers within the same tick share one in-flight probe so a burst of
// interactions does not spawn multiple probes. On failure/timeout the alias fallback
// is returned; no result is retained across calls.
export async function getClaudeModels(deps: { queryFn?: QueryFn; logger?: Logger } = {}): Promise<ModelChoice[]> {
  if (inFlight) return inFlight;
  const queryFn = deps.queryFn ?? (realQuery as QueryFn);
  inFlight = fetchClaudeModels(queryFn, deps.logger).finally(() => {
    inFlight = null;
  });
  return inFlight;
}

// ---- Codex models — honest static default (NOT auto-fetched) -----------------
// Codex has no model-list API and `codex exec -m` is FREE-FORM (any OpenAI model the
// account can reach works), so this is a documented convenience list, not a dynamic
// source. A configured non-empty codexModel is offered first (de-duplicated). English
// ids. The list below reflects the models currently used with the OpenAI Codex CLI as
// of 2026-07 (researched against developers.openai.com/codex/models): gpt-5.5 is the
// current default for ChatGPT-authenticated sessions, gpt-5.4 the fallback, gpt-5.4-mini
// for lighter tasks/subagents, and gpt-5.2-codex the Codex-specialized id kept for
// API-key workflows.
const CODEX_MODEL_DEFAULTS: readonly string[] = [
  'gpt-5.5',
  'gpt-5.4',
  'gpt-5.4-mini',
  'gpt-5.2-codex',
];

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

// ---- Built-in mode catalogs — ASSEMBLE the pieces above ----------------------
// Each catalog just wires the existing per-backend functions into the ModeCatalog seam
// (§6.2). The SDK drift guards are UNCHANGED: they live on the `satisfies`-bound
// CLAUDE_PERMISSION_MODES / CLAUDE_EFFORT_LEVELS / CLAUDE_RUNTIME_EFFORT_LEVELS constants
// that these functions read, so a future SDK change still fails to compile. A mode assigns
// its catalog by reference (ClaudeMode/CustomMode → claudeCatalog, CodexMode → codexCatalog),
// and call sites reach the vocabulary via modeRegistry.get(backend).catalog rather than
// branching on the backend id.
//
// claudeCatalog.models ignores `configured` (Claude probes the SDK's live list) and calls
// getClaudeModels() without a logger: the probe already falls back to the alias list on
// any failure, so the only loss is a warn line — an accepted minimal-surface tradeoff so
// the catalog stays a module const (no logger to thread through the ModeCatalog seam).
export const claudeCatalog: ModeCatalog = {
  models: () => getClaudeModels(),
  permissionChoices: () => permissionModeChoices('claude'),
  effortChoices: (levels) => effortChoicesFor('claude', levels),
  runtimeEffortChoices: (levels) => runtimeEffortChoicesFor('claude', levels),
  defaultEffort: () => 'high',
};

// codexCatalog.models forwards `configured` (config.defaults.codexModel) so a set value
// leads the documented static list; effort/permission use Codex's own vocabulary.
export const codexCatalog: ModeCatalog = {
  models: (configured) => getCodexModels(configured),
  permissionChoices: () => codexSandboxChoices(),
  effortChoices: () => effortChoicesFor('codex'),
  runtimeEffortChoices: () => runtimeEffortChoicesFor('codex'),
  defaultEffort: () => 'medium',
};
