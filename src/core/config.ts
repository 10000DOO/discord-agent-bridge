// TODO(Phase 1): config.json + servers/<guildId>.json load/save (0600), zod-validated (§8).
export interface AppConfig {
  version: number;
  discord: { token: string; clientId: string };
  // Full shape defined in docs/DESIGN.md §8.1; validated via core/state/schema.ts (zod).
  [key: string]: unknown;
}

export class ConfigStore {
  load(): Promise<AppConfig> {
    throw new Error('not implemented');
  }

  save(_config: AppConfig): Promise<void> {
    throw new Error('not implemented');
  }
}
