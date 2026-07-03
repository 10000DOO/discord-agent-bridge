import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { ModelInfo } from '@anthropic-ai/claude-agent-sdk';
import {
  getClaudeModels,
  getCodexModels,
  permissionModeChoices,
  permissionModeLabel,
  permissionChoicesFor,
  codexSandboxChoices,
  isCodexSandboxMode,
  effortChoicesFor,
  defaultEffortFor,
  CLAUDE_PERMISSION_MODES,
  CODEX_PERMISSION_MODES,
  CLAUDE_EFFORT_LEVELS,
  CODEX_EFFORT_LEVELS,
  CODEX_SANDBOX_MODES,
  CLAUDE_MODEL_FALLBACK,
  type QueryFn,
} from './providerCatalog.js';
import { permModeSchema } from './configSchema.js';
import { permModeArgs } from '../modes/codex/runner.js';

// The provider catalog is the ONE source of the model + permission-mode option lists.
// These tests MOCK the SDK's supportedModels() — no real SDK, no network.

// Build a fake Query object exposing just what the catalog calls: an async iterable
// that ends at once, supportedModels(), and close(). `supported` is a factory so a
// case can resolve, reject, or hang it.
function fakeQueryFn(supported: () => Promise<ModelInfo[]>, onClose?: () => void): { queryFn: QueryFn; calls: { supportedModels: number } } {
  const calls = { supportedModels: 0 };
  const queryFn = (() => {
    const gen = (async function* () {
      // Yields nothing: the probe query never sends a turn.
    })();
    return Object.assign(gen, {
      supportedModels: () => {
        calls.supportedModels += 1;
        return supported();
      },
      close: () => {
        onClose?.();
      },
    });
  }) as unknown as QueryFn;
  return { queryFn, calls };
}

function model(value: string, displayName: string): ModelInfo {
  return { value, displayName, description: `${displayName} model` };
}

describe('getClaudeModels (dynamic, mocked SDK)', () => {
  it('maps supportedModels() to English {value,label} (value=id, label=displayName)', async () => {
    const { queryFn } = fakeQueryFn(async () => [
      model('claude-opus-4-6', 'Claude Opus 4.6'),
      model('claude-sonnet-4-5', 'Claude Sonnet 4.5'),
    ]);
    const choices = await getClaudeModels({ queryFn });
    expect(choices).toEqual([
      { value: 'claude-opus-4-6', label: 'Claude Opus 4.6' },
      { value: 'claude-sonnet-4-5', label: 'Claude Sonnet 4.5' },
    ]);
  });

  it('falls back to the English aliases when supportedModels() REJECTS', async () => {
    const { queryFn } = fakeQueryFn(async () => {
      throw new Error('unavailable (api-key-only)');
    });
    const debug = vi.fn();
    const choices = await getClaudeModels({ queryFn, logger: { debug, info() {}, warn() {}, error() {} } });
    expect(choices).toEqual([
      { value: 'opus', label: 'opus' },
      { value: 'sonnet', label: 'sonnet' },
      { value: 'haiku', label: 'haiku' },
    ]);
    expect(choices.map((c) => c.value)).toEqual([...CLAUDE_MODEL_FALLBACK]);
    // Logged at debug (not warn/error) as specified.
    expect(debug).toHaveBeenCalledOnce();
  });

  it('falls back to the aliases when supportedModels() TIMES OUT (never resolves)', async () => {
    // A promise that never settles → the internal timeout wins → fallback.
    const { queryFn } = fakeQueryFn(() => new Promise<ModelInfo[]>(() => {}));
    vi.useFakeTimers();
    try {
      const promise = getClaudeModels({ queryFn });
      await vi.advanceTimersByTimeAsync(5_100);
      const choices = await promise;
      expect(choices.map((c) => c.value)).toEqual([...CLAUDE_MODEL_FALLBACK]);
    } finally {
      vi.useRealTimers();
    }
  });

  it('re-probes on every call so an updated account model list is reflected immediately', async () => {
    // First probe returns two models; a later probe returns three (a new model on the
    // account). No cross-invocation cache: the second call MUST see the fresh list.
    let attempt = 0;
    const { queryFn, calls } = fakeQueryFn(async () => {
      attempt += 1;
      return attempt === 1
        ? [model('claude-opus-4-6', 'Claude Opus 4.6')]
        : [model('claude-opus-4-6', 'Claude Opus 4.6'), model('claude-fable-1', 'Claude Fable 1')];
    });
    const first = await getClaudeModels({ queryFn });
    expect(first.map((c) => c.value)).toEqual(['claude-opus-4-6']);
    const second = await getClaudeModels({ queryFn });
    expect(second.map((c) => c.value)).toEqual(['claude-opus-4-6', 'claude-fable-1']);
    expect(calls.supportedModels).toBe(2);
  });

  it('shares one in-flight probe across concurrent callers in the same tick', async () => {
    const { queryFn, calls } = fakeQueryFn(async () => [model('claude-opus-4-6', 'Claude Opus 4.6')]);
    const [a, b] = await Promise.all([getClaudeModels({ queryFn }), getClaudeModels({ queryFn })]);
    expect(a).toEqual(b);
    // Concurrent callers share one probe; the next call after the shared probe
    // resolves probes fresh again.
    expect(calls.supportedModels).toBe(1);
  });

  it('closes the probe query after fetching', async () => {
    const onClose = vi.fn();
    const { queryFn } = fakeQueryFn(async () => [model('claude-opus-4-6', 'Claude Opus 4.6')], onClose);
    await getClaudeModels({ queryFn });
    expect(onClose).toHaveBeenCalledOnce();
  });
});

describe('permission modes (SDK-synced, English, per-backend)', () => {
  it('the Claude list is the full SDK-synced set with English labels', () => {
    expect([...CLAUDE_PERMISSION_MODES]).toEqual([
      'default',
      'acceptEdits',
      'bypassPermissions',
      'plan',
      'dontAsk',
      'auto',
    ]);
    const choices = permissionModeChoices('claude');
    expect(choices.map((c) => c.value)).toEqual([...CLAUDE_PERMISSION_MODES]);
    // Labels are the English identifier + a short English hint (no Korean).
    expect(permissionModeLabel('bypassPermissions')).toBe('bypassPermissions (auto-approve all)');
    const hangul = /[가-힣]/;
    for (const c of choices) expect(hangul.test(c.label)).toBe(false);
  });

  it('the Codex list excludes dontAsk/auto (no codex mapping)', () => {
    expect([...CODEX_PERMISSION_MODES]).toEqual(['default', 'acceptEdits', 'bypassPermissions', 'plan']);
    const codex = permissionModeChoices('codex').map((c) => c.value);
    expect(codex).not.toContain('dontAsk');
    expect(codex).not.toContain('auto');
  });

  it('the config schema accepts ALL Claude permission modes', () => {
    for (const mode of CLAUDE_PERMISSION_MODES) {
      expect(permModeSchema.safeParse(mode).success).toBe(true);
    }
  });

  it('permModeArgs stays valid for every Codex permission mode', () => {
    for (const mode of CODEX_PERMISSION_MODES) {
      const args = permModeArgs(mode);
      expect(Array.isArray(args)).toBe(true);
      expect(args.length).toBeGreaterThan(0);
    }
  });
});

describe('getCodexModels (researched convenience list, English)', () => {
  it('returns the current researched list as English {value,label} (label=id) when nothing is configured', () => {
    const choices = getCodexModels('');
    expect(choices).toEqual([
      { value: 'gpt-5.5', label: 'gpt-5.5' },
      { value: 'gpt-5.4', label: 'gpt-5.4' },
      { value: 'gpt-5.4-mini', label: 'gpt-5.4-mini' },
      { value: 'gpt-5.2-codex', label: 'gpt-5.2-codex' },
    ]);
  });

  it('offers a configured codexModel FIRST, de-duplicated', () => {
    const choices = getCodexModels('gpt-5.4');
    expect(choices[0]).toEqual({ value: 'gpt-5.4', label: 'gpt-5.4' });
    // No duplicate of the configured model further down the list.
    expect(choices.filter((c) => c.value === 'gpt-5.4')).toHaveLength(1);
    expect(choices).toHaveLength(4);
  });

  it('leads with a novel configured model (e.g. the operator config.toml model) without dropping the defaults', () => {
    const choices = getCodexModels('gpt-5.5-codex');
    expect(choices[0]?.value).toBe('gpt-5.5-codex');
    expect(choices).toHaveLength(5);
  });
});

describe('Codex-native sandbox permission choices (backend-specific)', () => {
  it('CODEX_SANDBOX_MODES is exactly the three documented -s values', () => {
    expect([...CODEX_SANDBOX_MODES]).toEqual(['read-only', 'workspace-write', 'danger-full-access']);
  });

  it('isCodexSandboxMode recognizes sandbox modes and rejects Claude PermMode names', () => {
    expect(isCodexSandboxMode('workspace-write')).toBe(true);
    expect(isCodexSandboxMode('danger-full-access')).toBe(true);
    expect(isCodexSandboxMode('acceptEdits')).toBe(false);
    expect(isCodexSandboxMode('default')).toBe(false);
  });

  it('codexSandboxChoices are English {value,label} with a short hint (no Korean)', () => {
    const choices = codexSandboxChoices();
    expect(choices.map((c) => c.value)).toEqual(['read-only', 'workspace-write', 'danger-full-access']);
    const hangul = /[가-힣]/;
    for (const c of choices) expect(hangul.test(c.label)).toBe(false);
    expect(choices.find((c) => c.value === 'workspace-write')?.label).toBe('workspace-write (write in workspace)');
  });

  it('permissionChoicesFor keys off the backend: Codex → sandbox terms, Claude → PermMode', () => {
    expect(permissionChoicesFor('codex').map((c) => c.value)).toEqual([...CODEX_SANDBOX_MODES]);
    expect(permissionChoicesFor('claude').map((c) => c.value)).toEqual([...CLAUDE_PERMISSION_MODES]);
  });

  it('permModeArgs maps each Codex sandbox choice to the right -s / approval flags', () => {
    expect(permModeArgs('read-only')).toEqual(['-c', 'approval_policy="on-request"', '-s', 'read-only']);
    expect(permModeArgs('workspace-write')).toEqual(['-c', 'approval_policy="on-request"', '-s', 'workspace-write']);
    // danger-full-access → the single codex bypass flag (no -s/-c/-a).
    expect(permModeArgs('danger-full-access')).toEqual(['--dangerously-bypass-approvals-and-sandbox']);
    for (const m of CODEX_SANDBOX_MODES) {
      expect(permModeArgs(m)).not.toContain('-a');
      expect(permModeArgs(m)).not.toContain('--ask-for-approval');
    }
  });
});

describe('reasoning-effort choices (per-backend)', () => {
  it('Claude effort levels are the SDK-synced set; Codex adds minimal and drops max', () => {
    expect([...CLAUDE_EFFORT_LEVELS]).toEqual(['low', 'medium', 'high', 'xhigh', 'max']);
    expect([...CODEX_EFFORT_LEVELS]).toEqual(['minimal', 'low', 'medium', 'high', 'xhigh']);
  });

  it('effortChoicesFor branches by backend with plain English labels', () => {
    expect(effortChoicesFor('claude').map((c) => c.value)).toEqual([...CLAUDE_EFFORT_LEVELS]);
    expect(effortChoicesFor('codex').map((c) => c.value)).toEqual([...CODEX_EFFORT_LEVELS]);
  });

  it('effortChoicesFor narrows Claude to a model’s supportedEffortLevels when provided', () => {
    const narrowed = effortChoicesFor('claude', ['low', 'medium', 'high']);
    expect(narrowed.map((c) => c.value)).toEqual(['low', 'medium', 'high']);
    // Codex ignores the Claude-only narrowing argument.
    expect(effortChoicesFor('codex', ['low']).map((c) => c.value)).toEqual([...CODEX_EFFORT_LEVELS]);
  });

  it('defaultEffortFor is high for Claude and medium for Codex', () => {
    expect(defaultEffortFor('claude')).toBe('high');
    expect(defaultEffortFor('codex')).toBe('medium');
  });
});
