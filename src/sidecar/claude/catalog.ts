// Claude provider catalog snapshot for the `claude.catalog` RPC (additive, v1).
// Reuses core/providerCatalog so model probing (15s timeout · in-flight dedup ·
// alias fallback) and the SDK-bound perm/effort vocab stay single-sourced.

import {
  getClaudeModels,
  permissionModeChoices,
  CLAUDE_EFFORT_LEVELS,
  CLAUDE_RUNTIME_EFFORT_LEVELS,
  defaultEffortFor,
  type QueryFn,
} from '../../core/providerCatalog.js';
import type { Logger } from '../../core/contracts.js';

export interface ClaudeCatalogResult {
  // `value` is the SDK alias (what the Host persists); `resolvedModel`/`description` are the
  // display-only companions the Host renders the concrete wire id + blurb from.
  models: {
    value: string;
    label: string;
    supportedEffortLevels?: string[];
    resolvedModel?: string;
    description?: string;
  }[];
  permissionModes: { value: string; label: string }[];
  effortLevels: string[];
  runtimeEffortLevels: string[];
  defaultEffort: string;
}

/**
 * Assemble the Claude catalog snapshot. `getClaudeModels` handles the timeout /
 * dedup / alias fallback internally, so this never throws for a probe failure.
 * `deps.queryFn` lets tests inject a fake SDK probe.
 */
export async function getClaudeCatalog(
  deps: { queryFn?: QueryFn; logger?: Logger } = {},
): Promise<ClaudeCatalogResult> {
  const models = await getClaudeModels(deps);
  return {
    models,
    permissionModes: permissionModeChoices('claude'),
    effortLevels: [...CLAUDE_EFFORT_LEVELS],
    runtimeEffortLevels: [...CLAUDE_RUNTIME_EFFORT_LEVELS],
    defaultEffort: defaultEffortFor('claude'),
  };
}
