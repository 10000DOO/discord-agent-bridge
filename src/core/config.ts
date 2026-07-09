import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import {
  configSchema,
  serverConfigSchema,
  CONFIG_DEFAULTS,
  CONFIG_VERSION,
  type AppConfig,
  type ServerConfig,
} from './configSchema.js';

export type { AppConfig, ServerConfig } from './configSchema.js';

// Load/save the GLOBAL config.json and per-server servers/<guildId>.json (§8).
// The base dir is injectable so tests never touch the real home directory:
// explicit ctor arg > env DAB_HOME > ~/.discord-agent-bridge/.
const DEFAULT_DIR_NAME = '.discord-agent-bridge';

function defaultBaseDir(): string {
  const fromEnv = process.env.DAB_HOME;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  return path.join(os.homedir(), DEFAULT_DIR_NAME);
}

// A plain object (not array, not primitive), or undefined otherwise. Used by
// mergeNested to decide whether a raw nested value is safe to spread.
function obj(v: unknown): Record<string, unknown> | undefined {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
}

// Merge one nested section over its default. When absent, the default stands.
// When present AND a plain object, the raw fields win over the default. When
// present but malformed (an array or a primitive where an object is expected), the
// raw value is passed THROUGH unchanged so zod rejects it with a clear error for
// that field, instead of spreading garbage (array indices / nothing) into an
// otherwise-valid default and silently swallowing the mistake.
function mergeNested(raw: unknown, def: Record<string, unknown>): unknown {
  if (raw === undefined) return def;
  const asObj = obj(raw);
  if (asObj === undefined) return raw; // malformed: let zod report it
  return { ...def, ...asObj };
}

// Fill missing fields from CONFIG_DEFAULTS. Present values win; secrets (discord)
// carry no default and must be supplied by the raw object. Malformed nested values
// (array/primitive where an object is expected) are surfaced to zod rather than
// silently merged (see mergeNested).
function applyDefaults(raw: Record<string, unknown>): unknown {
  const discord = raw['discord'];
  return {
    ...CONFIG_DEFAULTS,
    ...raw,
    version: typeof raw['version'] === 'number' ? raw['version'] : CONFIG_VERSION,
    discord,
    auth: mergeNested(raw['auth'], CONFIG_DEFAULTS.auth),
    defaults: mergeNested(raw['defaults'], CONFIG_DEFAULTS.defaults),
    limits: mergeNested(raw['limits'], CONFIG_DEFAULTS.limits),
    policy: mergeNested(raw['policy'], CONFIG_DEFAULTS.policy),
    usage: mergeNested(raw['usage'], CONFIG_DEFAULTS.usage),
    audit: mergeNested(raw['audit'], CONFIG_DEFAULTS.audit),
    render: mergeNested(raw['render'], CONFIG_DEFAULTS.render),
    chromium: mergeNested(raw['chromium'], CONFIG_DEFAULTS.chromium),
    autoUpdate: mergeNested(raw['autoUpdate'], CONFIG_DEFAULTS.autoUpdate),
  };
}

export class ConfigStore {
  private readonly baseDir: string;

  constructor(baseDir?: string) {
    this.baseDir = baseDir ?? defaultBaseDir();
  }

  get dir(): string {
    return this.baseDir;
  }

  get configPath(): string {
    return path.join(this.baseDir, 'config.json');
  }

  serverConfigPath(guildId: string): string {
    return path.join(this.baseDir, 'servers', `${guildId}.json`);
  }

  exists(): boolean {
    return fs.existsSync(this.configPath);
  }

  // Load config.json, applying DEFAULTS for missing fields, then zod-validate.
  load(): AppConfig {
    if (!fs.existsSync(this.configPath)) {
      throw new Error(
        `Config file not found at ${this.configPath}. Run the setup wizard first.`,
      );
    }
    const raw = JSON.parse(fs.readFileSync(this.configPath, 'utf-8')) as unknown;
    if (typeof raw !== 'object' || raw === null) {
      throw new Error(`Invalid config file at ${this.configPath}: expected a JSON object.`);
    }
    return configSchema.parse(applyDefaults(raw as Record<string, unknown>));
  }

  // Validate then write config.json atomically (tmp + rename); 0600 on non-Windows.
  save(config: AppConfig): void {
    const validated = configSchema.parse(config);
    this.ensureDir(this.baseDir);
    this.writeSecure(this.configPath, validated);
  }

  // Persist an "always-allow" Claude tool into the GLOBAL autoAllowClaudeTools set
  // (§7A/§8.1) so future turns auto-allow it without a prompt. Scope decision: the
  // global auto-allow set — §8.1 lists autoAllowClaudeTools as a global default the
  // orchestrator already threads into every ModeContext, so a globally-persisted
  // tool takes effect for every channel's next turn with no per-project plumbing.
  // Idempotent: a tool already present is a no-op (no rewrite). Returns whether the
  // config was changed.
  addAutoAllowClaudeTool(toolName: string): boolean {
    const config = this.load();
    if (config.autoAllowClaudeTools.includes(toolName)) return false;
    config.autoAllowClaudeTools = [...config.autoAllowClaudeTools, toolName];
    this.save(config);
    return true;
  }

  // Global partial-update helpers for the image-render feature (load → patch → save,
  // mirroring addAutoAllowClaudeTool). Both keys are host-wide (no per-server override).
  setRenderEnabled(enabled: boolean): void {
    const config = this.load();
    config.render = { enabled };
    this.save(config);
  }

  setChromiumDecision(decision: 'undecided' | 'accepted' | 'declined'): void {
    const config = this.load();
    config.chromium = { decision };
    this.save(config);
  }

  // Fail-safe: a corrupt/hand-edited server file (bad JSON or failing zod) is
  // treated as NO override — return null so the caller falls through to global —
  // with a loud warning. This runs at request time inside authorize()/resolve(),
  // so a broken server file must never throw and take down a live request.
  loadServerConfig(guildId: string): ServerConfig | null {
    const filePath = this.serverConfigPath(guildId);
    if (!fs.existsSync(filePath)) return null;
    try {
      const raw = JSON.parse(fs.readFileSync(filePath, 'utf-8')) as unknown;
      return serverConfigSchema.parse(raw);
    } catch (err) {
      console.warn(`[config] ignoring corrupt server config ${filePath}; falling back to global: ${String(err)}`);
      return null;
    }
  }

  saveServerConfig(config: ServerConfig): void {
    const validated = serverConfigSchema.parse(config);
    this.ensureDir(path.dirname(this.serverConfigPath(validated.guildId)));
    this.writeSecure(this.serverConfigPath(validated.guildId), validated);
  }

  private ensureDir(dir: string): void {
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
  }

  // Atomic write (tmp + rename), then restrict perms on non-Windows. Config files
  // hold the bot token, so they must not be world/group-readable.
  private writeSecure(target: string, value: unknown): void {
    const data = JSON.stringify(value, null, 2) + '\n';
    const tmp = `${target}.tmp`;
    fs.writeFileSync(tmp, data, { encoding: 'utf-8', mode: 0o600 });
    fs.renameSync(tmp, target);
    if (process.platform !== 'win32') {
      fs.chmodSync(target, 0o600);
    }
  }
}
