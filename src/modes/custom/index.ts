import type { Options } from '@anthropic-ai/claude-agent-sdk';
import type { ModeContext } from '../../core/contracts.js';
import {
  ClaudeMode,
  type ClaudeModeDeps,
  type ClaudeSessionPrep,
} from '../claude/index.js';
import { resolveCustomEnv } from './shellEnv.js';

// Re-export for tests that inject listSessions without importing from claude/.
export type { ListSessionsFn } from '../claude/index.js';

// Custom mode accepts the same injectables as ClaudeMode, minus the identity/prep
// hooks which this subclass always wires for the `custom` backend.
export type CustomModeDeps = Omit<ClaudeModeDeps, 'name' | 'prepareSession'>;

// Resolve shell-dotfile env, prefer ANTHROPIC_MODEL, warn on dangerous alias flag.
// Shared by start/resume via ClaudeMode.prepareSession.
function prepareCustomSession(ctx: ModeContext): ClaudeSessionPrep {
  const { env: extracted, source, hasDangerousFlag } = resolveCustomEnv();
  if (hasDangerousFlag && ctx.permMode !== 'bypassPermissions') {
    ctx.logger.warn(
      'custom backend alias contains --dangerously-skip-permissions but permMode is not bypassPermissions',
      { source },
    );
  }
  const env: Options['env'] = { ...process.env, ...extracted };
  const customCtx = { ...ctx, model: extracted.ANTHROPIC_MODEL ?? ctx.model };
  ctx.logger.info('custom backend env resolved', { source, keys: Object.keys(extracted) });
  return { ctx: customCtx, env };
}

// The `custom` backend: ClaudeMode + shell-env prep. Capabilities, catalog,
// listResumable, and session wiring all come from ClaudeMode; only name and
// prepareSession differ.
export class CustomMode extends ClaudeMode {
  constructor(deps: CustomModeDeps = {}) {
    super({ ...deps, name: 'custom', prepareSession: prepareCustomSession });
  }
}
