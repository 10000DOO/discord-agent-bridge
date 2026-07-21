import type { ModeCatalog, ModelChoice, PermMode } from '../../core/contracts.js';
import { GrokConfigSource, grokConfigSource } from './configSource.js';

// Grok's OWN model/permission/effort vocabulary for the Discord UI (§6/§9). Grok owns its
// catalog (providerCatalog.ts is untouched); the wizard/`/config`/`/effort` reach these lists
// via modeRegistry.get('grok-build').catalog.* so core/Discord never branch on the backend id.
// Model and effort values are DYNAMIC — served from grokConfigSource (models_cache.json /
// config.toml) so a model added on the account surfaces without a bridge restart.

// Permission menu = ONLY the modes grok actually enforces (D4/R3): bypassPermissions
// auto-approves every tool; default requires approval (ACP interactive path). acceptEdits/
// auto/dontAsk/plan are accepted-but-ignored by the flag, so offering them would misrepresent
// what happens. Bound to PermMode via `satisfies` so both stay members of the persisted
// permModeSchema (state/schema.ts) — no schema change to persist a grok binding.
export const GROK_PERMISSION_MODES = ['bypassPermissions', 'default'] as const satisfies readonly PermMode[];

// Honest hint labels for the two enforced modes (English + hint, matching the other backends'
// tone).
const GROK_PERMISSION_LABELS: Record<(typeof GROK_PERMISSION_MODES)[number], string> = {
  bypassPermissions: 'bypassPermissions (auto-approve all tools)',
  default: 'default (prompts are cancelled — tools are skipped)',
};

// True when `value` is a known grok model. Guards the runner's `-m`: ctx.model can carry a
// leaked Claude model (buildContext routes a non-codex model pick onto ctx.model), so `-m` is
// only added when the value is actually a grok model — otherwise grok uses its own config
// default instead of inheriting a Claude id. Delegates to the dynamic source (R4).
export function isGrokModel(value: string): boolean {
  return grokConfigSource.isKnownModel(value);
}

// True when `value` is a grok reasoning-effort level. Guards GrokSession.setEffort (mirrors the
// Codex guard) so a free-typed /effort value can't be persisted and then fail every turn.
// Delegates to the dynamic source, so a valid new effort is not dropped (R4).
export function isGrokEffort(value: string): boolean {
  return grokConfigSource.isKnownEffort(value);
}

// Assemble a catalog over the given config source. A factory (rather than a bare const) so a test
// can inject a fixture-backed GrokConfigSource for deterministic model/effort assertions;
// production wires the module singleton below.
export function createGrokCatalog(source: GrokConfigSource): ModeCatalog {
  // Options reflect ONLY the chosen model's advertised effort levels (RECEIVED-ONLY): an
  // absent/empty `supported` (model not in cache, or advertising no effort) → [] so the wizard
  // skips the effort step and grok's own per-model default applies. No borrow from the default
  // model — that borrow is what would make an un-advertised model wrongly show another's effort.
  const effortChoices = (supported?: readonly string[]): ModelChoice[] =>
    (supported ?? []).map((v) => ({ value: v, label: v }));
  return {
    models: () => source.models(),
    permissionChoices: (): ModelChoice[] =>
      GROK_PERMISSION_MODES.map((m) => ({ value: m, label: GROK_PERMISSION_LABELS[m] })),
    // Non-empty → the wizard shows an effort step; runtime list drives /effort (setEffort, §6).
    effortChoices,
    runtimeEffortChoices: effortChoices,
    defaultEffort: () => source.defaultEffortFor(source.defaultModel()),
  };
}

export const grokCatalog: ModeCatalog = createGrokCatalog(grokConfigSource);
