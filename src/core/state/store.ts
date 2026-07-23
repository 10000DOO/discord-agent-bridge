import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import { normalizeModeId } from '../config.js';
import { appStateSchema, emptyState, STATE_VERSION, type AppState, type AutoUpdateState, type PresetDraftState } from './schema.js';

// Versioned JSON state store. Loads state.json, runs ordered migrations up to the
// current version, zod-validates, and writes atomically (tmp + rename). Unknown
// fields are tolerated on read (z.object strips them → normalized on write).
// See docs/DESIGN.md §8. The base dir is injectable so tests never touch the real
// home directory: explicit ctor arg > env DAB_HOME > ~/.discord-agent-bridge/.
const DEFAULT_DIR_NAME = '.discord-agent-bridge';

function defaultBaseDir(): string {
  const fromEnv = process.env.DAB_HOME;
  if (fromEnv && fromEnv.length > 0) return fromEnv;
  return path.join(os.homedir(), DEFAULT_DIR_NAME);
}

// Ordered migrations, keyed by the version they upgrade FROM. Each returns the
// object shape at the next version. Run in sequence until STATE_VERSION.
// v1 stored channels keyed by bare "<channelId>" without a guildId field; v2
// rekeys them to "<guildId>:<channelId>" (§8, store.ts note). v1 is hypothetical
// (pre-release) but the migration path is exercised for forward safety.
const migrations: Record<number, (raw: Record<string, unknown>) => Record<string, unknown>> = {
  1: (raw) => {
    const oldChannels = (raw['channels'] as Record<string, Record<string, unknown>>) ?? {};
    const channels: Record<string, Record<string, unknown>> = {};
    for (const [key, binding] of Object.entries(oldChannels)) {
      const guildId = typeof binding['guildId'] === 'string' ? binding['guildId'] : 'unknown';
      const rekeyed = key.includes(':') ? key : `${guildId}:${key}`;
      channels[rekeyed] = binding;
    }
    return { ...raw, version: 2, channels };
  },
};

function migrate(raw: Record<string, unknown>): Record<string, unknown> {
  let current = raw;
  let version = typeof current['version'] === 'number' ? (current['version'] as number) : STATE_VERSION;
  while (version < STATE_VERSION) {
    const step = migrations[version];
    if (!step) {
      throw new Error(`No migration registered from state version ${version}.`);
    }
    current = step(current);
    const next = typeof current['version'] === 'number' ? (current['version'] as number) : version + 1;
    if (next <= version) {
      throw new Error(`Migration from state version ${version} did not advance the version.`);
    }
    version = next;
  }
  return current;
}

export class StateStore {
  private readonly baseDir: string;

  constructor(baseDir?: string) {
    this.baseDir = baseDir ?? defaultBaseDir();
  }

  get dir(): string {
    return this.baseDir;
  }

  get statePath(): string {
    return path.join(this.baseDir, 'state.json');
  }

  // Load state.json → migrate → zod-validate. When absent, return fresh v2 state.
  // Retired Grok backend ids on channel bindings (`grok`, `grok-agent`) → `grok-build`.
  load(): AppState {
    if (!fs.existsSync(this.statePath)) {
      return emptyState();
    }
    const raw = JSON.parse(fs.readFileSync(this.statePath, 'utf-8')) as unknown;
    if (typeof raw !== 'object' || raw === null) {
      throw new Error(`Invalid state file at ${this.statePath}: expected a JSON object.`);
    }
    const migrated = migrate(raw as Record<string, unknown>);
    const state = appStateSchema.parse(migrated);
    for (const binding of Object.values(state.channels)) {
      binding.mode = normalizeModeId(binding.mode);
    }
    return state;
  }

  // Validate, normalize to current version, then write atomically (tmp + rename).
  save(state: AppState): void {
    const validated = appStateSchema.parse({ ...state, version: STATE_VERSION });
    if (!fs.existsSync(this.baseDir)) {
      fs.mkdirSync(this.baseDir, { recursive: true });
    }
    const data = JSON.stringify(validated, null, 2) + '\n';
    const tmp = `${this.statePath}.tmp`;
    fs.writeFileSync(tmp, data, { encoding: 'utf-8' });
    fs.renameSync(tmp, this.statePath);
  }

  // Auto-update bookkeeping convenience accessors (§8), mirroring ConfigStore's
  // addAutoAllowClaudeTool style: the AutoUpdater reads/patches this block without
  // touching the channel bindings. getUpdateMeta returns the resolved (defaulted) block.
  getUpdateMeta(): AutoUpdateState {
    return this.load().autoUpdate;
  }

  // Patch the auto-update block (lastCheckAt and/or dismissedVersion) and persist.
  // Load → merge → save so an unrelated concurrent field is preserved.
  setUpdateMeta(patch: Partial<AutoUpdateState>): void {
    const state = this.load();
    state.autoUpdate = { ...state.autoUpdate, ...patch };
    this.save(state);
  }

  // Preset-draft backup convenience accessors, mirroring setUpdateMeta: the interaction
  // router restores these on boot and backs up a draft when the wizard reaches 'done', so
  // a "💾 save as preset" button survives a restart. Keyed by "<guildId>:<channelId>".
  getPresetDrafts(): Record<string, PresetDraftState> {
    return this.load().presetDrafts;
  }

  // Back up (or overwrite) one channel's draft. Load → set → save so unrelated drafts and
  // the channel bindings are preserved.
  setPresetDraft(key: string, draft: PresetDraftState): void {
    const state = this.load();
    state.presetDrafts[key] = draft;
    this.save(state);
  }

  // Drop one channel's backed-up draft (a missing key is a no-op). Load → delete → save.
  deletePresetDraft(key: string): void {
    const state = this.load();
    delete state.presetDrafts[key];
    this.save(state);
  }
}
