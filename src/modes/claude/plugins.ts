import * as fs from 'node:fs';
import * as path from 'node:path';
import * as os from 'node:os';
import type { SdkPluginConfig } from '@anthropic-ai/claude-agent-sdk';
import type { Logger } from '../../core/contracts.js';

// Auto-load the user's installed & enabled Claude Code plugins from ~/.claude/ so
// a session gets the same plugin commands/agents/skills/hooks as the terminal
// `claude` (adapts A4D utils/plugins.ts; uses the injected redacting logger
// instead of console). A missing/unreadable config is not an error — it just
// means no plugins, so we return [].

const CLAUDE_DIR = path.join(os.homedir(), '.claude');
const SETTINGS_PATH = path.join(CLAUDE_DIR, 'settings.json');
const INSTALLED_PLUGINS_PATH = path.join(CLAUDE_DIR, 'plugins', 'installed_plugins.json');

interface InstalledPluginEntry {
  scope: string;
  installPath: string;
  version: string;
}

interface InstalledPluginsFile {
  version: number;
  plugins: Record<string, InstalledPluginEntry[]>;
}

interface SettingsFile {
  enabledPlugins?: Record<string, boolean>;
}

export function resolvePlugins(logger: Logger): SdkPluginConfig[] {
  let settings: SettingsFile;
  try {
    settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf-8')) as SettingsFile;
  } catch {
    return [];
  }

  const enabledPlugins = settings.enabledPlugins;
  if (!enabledPlugins || typeof enabledPlugins !== 'object') return [];

  const enabledNames = Object.entries(enabledPlugins)
    .filter(([, enabled]) => enabled === true)
    .map(([name]) => name);
  if (enabledNames.length === 0) return [];

  let installed: InstalledPluginsFile;
  try {
    installed = JSON.parse(fs.readFileSync(INSTALLED_PLUGINS_PATH, 'utf-8')) as InstalledPluginsFile;
  } catch {
    return [];
  }
  if (!installed.plugins || typeof installed.plugins !== 'object') return [];

  const result: SdkPluginConfig[] = [];
  for (const name of enabledNames) {
    const entries = installed.plugins[name];
    const installPath = entries?.[0]?.installPath;
    if (!installPath) {
      logger.warn('claude: enabled plugin not resolvable; skipping', { plugin: name });
      continue;
    }
    if (!fs.existsSync(installPath)) {
      logger.warn('claude: plugin install path missing; skipping', { plugin: name, installPath });
      continue;
    }
    result.push({ type: 'local', path: installPath });
  }

  if (result.length > 0) {
    logger.info('claude: loaded plugins', { count: result.length });
  }
  return result;
}
