import type { Options } from '@anthropic-ai/claude-agent-sdk';
import type { ModeContext } from '../../core/contracts.js';
import { ClaudeSession, type ClaudeSessionDeps } from '../claude/session.js';

// Deps for a CustomEnvSession: everything ClaudeSession accepts, plus an optional
// env override to pass through to the SDK's Options.env.
export interface CustomEnvSessionDeps extends ClaudeSessionDeps {
  env?: Options['env'];
}

// A Claude session that runs with env vars extracted from the operator's shell
// dotfiles (see shellEnv.ts). The env is injected into the SDK's query() Options;
// it replaces the subprocess env entirely for that session, so only custom-mode
// sessions are affected.
export class CustomEnvSession extends ClaudeSession {
  constructor(ctx: ModeContext, deps: CustomEnvSessionDeps = {}) {
    super(ctx, deps);
  }
}
