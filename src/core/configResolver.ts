import type { ModeConfigView } from './contracts.js';
import type { AppConfig, ServerConfig } from './configSchema.js';
import type { ConfigStore } from './config.js';
import type { ChannelRegistry, ChannelBinding } from './channelRegistry.js';

// 3-level config layering: global (config.json) → server (servers/<guildId>.json)
// → project (per-channel binding in state.json). The most specific PRESENT value
// wins; absent levels fall through. Deep-merge for nested objects. See DESIGN §8.1.
//
// DESIGN §8 is explicit about where project-level overrides live: the per-channel
// binding in state.json carries `permissionMode`, `permissionProfile`, and
// `projectAuth`. So the project layer here reads from ChannelRegistry, not a
// separate project file. (This resolves the brief's "if ambiguous" note — §8 is
// not ambiguous: project overrides = the channel binding.)

// Typed, fully-resolved view of the layerable settings (§8.1).
export interface ResolvedConfig {
  mode: 'claude' | 'codex';
  claudeModel: string;
  permissionMode: AppConfig['defaults']['permissionMode'];
  permissionProfile: string | null;
  codexHome: string;
  codexCliCommand: string;
  codexCliVersion: string | null;
  limits: AppConfig['limits'];
}

// Deep-merge plain objects: for keys present in `over`, its value wins unless
// both sides are plain objects, in which case merge recursively. `undefined`
// values in `over` are treated as absent (fall through to `base`). Arrays and
// null are replaced wholesale (they are leaf settings here, not merge targets).
function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// Recursively-optional overlay: every field, at every depth, may be omitted.
// Leaf settings (arrays, null) are replaced wholesale, so they are not recursed.
type DeepPartial<T> = {
  [K in keyof T]?: T[K] extends readonly unknown[]
    ? T[K]
    : T[K] extends object
      ? DeepPartial<T[K]>
      : T[K];
};

function deepMerge<T>(base: T, over: DeepPartial<T> | undefined): T {
  if (over === undefined) return base;
  if (!isPlainObject(base) || !isPlainObject(over)) {
    return over as T;
  }
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(over as Record<string, unknown>)) {
    if (v === undefined) continue;
    const prev = out[k];
    out[k] = isPlainObject(prev) && isPlainObject(v) ? deepMerge(prev, v) : v;
  }
  return out as T;
}

export class ConfigResolver {
  constructor(
    private readonly configStore: ConfigStore,
    private readonly channelRegistry: ChannelRegistry,
  ) {}

  // Resolve the effective config for a channel. Layers global defaults, then the
  // server override (if servers/<guildId>.json exists), then the project override
  // (the channel binding, if one exists).
  resolve(guildId: string, channelId: string): ResolvedConfig {
    const global = this.configStore.load();
    const server = this.configStore.loadServerConfig(guildId);
    const binding = this.channelRegistry.get(guildId, channelId);
    return this.merge(global, server, binding);
  }

  // The resolved view narrowed to what a mode needs (ModeContext.config).
  resolveModeConfig(guildId: string, channelId: string): ModeConfigView {
    const r = this.resolve(guildId, channelId);
    return {
      model: r.claudeModel,
      codexHome: r.codexHome,
      codexCliCommand: r.codexCliCommand,
      codexCliVersion: r.codexCliVersion ?? undefined,
      permissionTimeoutSec: r.limits.permissionTimeoutSec,
      codexTimeoutMs: r.limits.codexTimeoutMs,
    };
  }

  // Pure merge, exposed for direct/testable layering without disk reads.
  private merge(
    global: AppConfig,
    server: ServerConfig | null,
    binding: ChannelBinding | undefined,
  ): ResolvedConfig {
    // Level 1: global defaults.
    let result: ResolvedConfig = {
      mode: global.defaults.mode,
      claudeModel: global.defaults.claudeModel,
      permissionMode: global.defaults.permissionMode,
      permissionProfile: global.defaults.permissionProfile,
      codexHome: global.defaults.codexHome,
      codexCliCommand: global.defaults.codexCliCommand,
      codexCliVersion: global.defaults.codexCliVersion,
      limits: { ...global.limits },
    };

    // Level 2: server override (only the fields §8.1 allows a server to set).
    if (server) {
      result = deepMerge(result, {
        mode: server.defaults?.mode,
        claudeModel: server.defaults?.claudeModel,
        permissionMode: server.defaults?.permissionMode,
        permissionProfile: server.defaults?.permissionProfile,
        limits: server.limits,
      });
    }

    // Level 3: project override (the channel binding). Only the fields the
    // binding carries are layered (§8: mode, permissionMode, permissionProfile).
    if (binding) {
      result = deepMerge(result, {
        mode: binding.mode,
        permissionMode: binding.permMode,
        permissionProfile: binding.profile,
      });
    }

    return result;
  }
}
