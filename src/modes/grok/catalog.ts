import type { ModeCatalog, ModelChoice, PermMode } from '../../core/contracts.js';
import { GrokConfigSource, grokConfigSource } from './configSource.js';
import {
  GROK_PERMISSION_FALLBACK,
  GrokPermissionSource,
  grokPermissionSource,
} from './permissionSource.js';

// Grok's OWN model/permission/effort vocabulary for the Discord UI (§6/§9). Grok owns its
// catalog (providerCatalog.ts is untouched); the wizard/`/config`/`/effort` reach these lists
// via modeRegistry.get('grok-build').catalog.* so core/Discord never branch on the backend id.
// Model and effort values are DYNAMIC — served from grokConfigSource (models_cache.json /
// config.toml) so a model added on the account surfaces without a bridge restart.
// Permission modes are DYNAMIC from installed `grok --help` (permissionSource); session
// wiring still maps only bypassPermissions → --always-approve (see acpSession).

// Fallback alias of the full CLI default list (permissionSource). Kept as GROK_PERMISSION_MODES
// so existing importers (capabilities, tests) keep a stable name; runtime catalogs use the
// dynamic source.
export const GROK_PERMISSION_MODES = GROK_PERMISSION_FALLBACK;

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

// Assemble a catalog over the given config + permission sources. A factory (rather than a bare
// const) so a test can inject fixture-backed sources for deterministic assertions; production
// wires the module singletons below.
export function createGrokCatalog(
  source: GrokConfigSource,
  permissionSource: GrokPermissionSource = grokPermissionSource,
): ModeCatalog {
  // Options reflect ONLY the chosen model's advertised effort levels (RECEIVED-ONLY): an
  // absent/empty `supported` (model not in cache, or advertising no effort) → [] so the wizard
  // skips the effort step and grok's own per-model default applies. No borrow from the default
  // model — that borrow is what would make an un-advertised model wrongly show another's effort.
  const effortChoices = (supported?: readonly string[]): ModelChoice[] =>
    (supported ?? []).map((v) => ({ value: v, label: v }));
  return {
    models: () => source.models(),
    permissionChoices: (): ModelChoice[] => permissionSource.permissionChoices(),
    // Non-empty → the wizard shows an effort step; runtime list drives /effort (setEffort, §6).
    effortChoices,
    runtimeEffortChoices: effortChoices,
    defaultEffort: () => source.defaultEffortFor(source.defaultModel()),
  };
}

export const grokCatalog: ModeCatalog = createGrokCatalog(grokConfigSource);

// Re-export for callers that need the dynamic permission mode list as PermMode[].
export function grokPermissionModes(): PermMode[] {
  return grokPermissionSource.permissionModesAsPermModes();
}
