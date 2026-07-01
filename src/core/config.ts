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

// Fill missing fields from CONFIG_DEFAULTS. Present values win; secrets (discord)
// carry no default and must be supplied by the raw object.
function applyDefaults(raw: Record<string, unknown>): unknown {
  const discord = raw['discord'];
  return {
    ...CONFIG_DEFAULTS,
    ...raw,
    version: typeof raw['version'] === 'number' ? raw['version'] : CONFIG_VERSION,
    discord,
    auth: { ...CONFIG_DEFAULTS.auth, ...(raw['auth'] as object | undefined) },
    defaults: { ...CONFIG_DEFAULTS.defaults, ...(raw['defaults'] as object | undefined) },
    limits: { ...CONFIG_DEFAULTS.limits, ...(raw['limits'] as object | undefined) },
    policy: { ...CONFIG_DEFAULTS.policy, ...(raw['policy'] as object | undefined) },
    usage: { ...CONFIG_DEFAULTS.usage, ...(raw['usage'] as object | undefined) },
    audit: { ...CONFIG_DEFAULTS.audit, ...(raw['audit'] as object | undefined) },
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

  loadServerConfig(guildId: string): ServerConfig | null {
    const filePath = this.serverConfigPath(guildId);
    if (!fs.existsSync(filePath)) return null;
    const raw = JSON.parse(fs.readFileSync(filePath, 'utf-8')) as unknown;
    return serverConfigSchema.parse(raw);
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
