import type { CanUseTool, PermissionResult } from '@anthropic-ai/claude-agent-sdk';
import type { ModeContext } from '../../core/contracts.js';

// Bridges the SDK's canUseTool callback to the core permission flow (§5a, §7A).
//
// In the SDK's `default` permission mode this callback IS the per-action confirm:
// for every tool the SDK is about to run it asks us whether to allow it. We map
// that to `ctx.requestPermission({toolName, input})`, which the Discord layer
// turns into Allow/Deny buttons and resolves. The returned PermissionDecision is
// mapped back onto the SDK's PermissionResult union.
//
// Auto-allow is config-driven (fixes A8): tools listed in the resolved layered
// allowlist (`ctx.config.allowedTools` / `autoAllowClaudeTools`, threaded by the
// orchestrator from PermissionResolver) are allowed without prompting. We do NOT
// re-hardcode a safe-tool list here. Non-`default` SDK permission modes
// (acceptEdits / bypassPermissions / plan) largely resolve inside the SDK before
// canUseTool is reached; this callback stays the single, config-driven gate for
// anything that does surface.
export function makeCanUseTool(ctx: ModeContext): CanUseTool {
  const autoAllow = new Set<string>([
    ...(ctx.config.allowedTools ?? []),
    ...(ctx.config.autoAllowClaudeTools ?? []),
  ]);

  return async (toolName, input): Promise<PermissionResult> => {
    if (autoAllow.has(toolName)) {
      return { behavior: 'allow', updatedInput: input };
    }

    const decision = await ctx.requestPermission({ toolName, input });
    if (decision.behavior === 'allow') {
      return { behavior: 'allow', updatedInput: input };
    }
    return {
      behavior: 'deny',
      message: decision.message ?? 'Denied by operator.',
    };
  };
}
