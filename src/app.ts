import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PermissionFlagsBits, type Client } from 'discord.js';
import { ConfigStore, type AppConfig, type ServerConfig } from './core/config.js';
import { StateStore } from './core/state/store.js';
import { ChannelRegistry } from './core/channelRegistry.js';
import { EventBus } from './core/eventBus.js';
import { ConfigResolver } from './core/configResolver.js';
import { PermissionResolver } from './core/permissionResolver.js';
import { Authorizer } from './core/auth.js';
import { AuditLog } from './core/auditLog.js';
import { UsageService } from './core/usageService.js';
import { CodexUsageService } from './modes/codex/usageService.js';
import { ModeRegistry } from './core/modeRegistry.js';
import { SessionOrchestrator } from './core/sessionOrchestrator.js';
import { createLogger } from './core/logger.js';
import type { Logger } from './core/contracts.js';
import { ClaudeMode } from './modes/claude/index.js';
import { CodexMode, resolveCodexHome } from './modes/codex/index.js';
import { GrokBuildMode } from './modes/grok/agent/index.js';
import { GrokUsageService } from './modes/grok/usageService.js';
import { CustomMode } from './modes/custom/index.js';
import { customBackendLabel } from './modes/custom/shellEnv.js';
import { MessageRouter } from './discord/messageRouter.js';
import { InteractionRouter } from './discord/interactionRouter.js';
import { createMacFolderPanelOpener } from './discord/folderPanel.js';
import { SessionWiring } from './discord/wiring.js';
import { ChromiumProvisioner } from './discord/render/chromiumProvisioner.js';
import { DiscordClient, resolveGuildProvisioner } from './discord/client.js';
import { autoProvisionGuild } from './discord/guildChannels.js';
import { buildUpdatePrompt } from './discord/renderers/updateButton.js';
import type { MessageChannel } from './discord/ports.js';
import { createAttachGateway } from './discord/attachGateway.js';
import { setLocale, t, type Locale } from './discord/i18n.js';
import { readVersion } from './version.js';
import { AutoUpdater, type UpdateMeta } from './update/autoUpdater.js';
import { fetchLatestVersion } from './update/registry.js';
import { detectRestartStrategy } from './update/environment.js';
import {
  installLatest,
  performRestart,
  realCommandRunner,
  writePidFile,
  removePidFile,
  type MinimalFs,
} from './update/installer.js';

// The real fs slice for PID-file writes (§3.5). Module-level so startBot (write) and
// App.destroy (remove) share one implementation.
const realMinimalFs: MinimalFs = {
  writeFileSync: (filePath, data) => fs.writeFileSync(filePath, data, 'utf-8'),
  existsSync: (filePath) => fs.existsSync(filePath),
  rmSync: (filePath, options) => fs.rmSync(filePath, options),
};

// dist/cli.js resolved relative to this module (dist/app.js → ./cli.js; src/app.ts →
// ./cli.ts in dev). The method-B respawn runs `node <this>` — after `npm i -g` the
// global package was replaced in place, so the same entry path is now the new version.
function appCliEntry(): string {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), 'cli.js');
}

// The application composition root (§2, §4, §9). createApp() builds the full core
// graph, registers the Claude mode, wires permission requests + resume-on-boot +
// always-allow persistence, and constructs the Discord client — WITHOUT logging in
// (so the whole thing is unit-testable with a fake client). startBot() then loads
// config, builds the app, and logs in.
//
// Dependency rule (§4): app.ts is the ONE place that touches every layer to wire
// them together; core/ and each mode/ know nothing about each other or about the
// Discord specifics. discord.js only ever appears here as an injectable Client.

export interface CreateAppDeps {
  // The loaded, validated global config (secrets + defaults). startBot loads it via
  // ConfigStore; tests pass a hand-built config.
  config: AppConfig;
  // The ConfigStore backing `config`. Used for the always-allow persistence write
  // and read through by the resolvers. Tests inject a temp-dir store.
  configStore: ConfigStore;
  // Injectable so tests never construct a real gateway Client (no login). When
  // omitted, DiscordClient builds a real discord.js Client with the required intents.
  client?: Client;
  // Injectable logger (default: redacting console logger at config.logLevel).
  logger?: Logger;
  // Injected fetch for the usage service (default: global fetch). Tests avoid the network.
  fetchFn?: typeof fetch;
}

// The wired application. `discord.login(token)` is the only step createApp does not
// perform, so a test can construct the whole graph and assert its wiring without a
// network connection.
export interface App {
  discord: DiscordClient;
  orchestrator: SessionOrchestrator;
  modeRegistry: ModeRegistry;
  wiring: SessionWiring;
  usageService: UsageService;
  logger: Logger;
  config: AppConfig;
  // Log in and start the gateway. Registers slash commands and runs onReady
  // (resume-on-boot + renderer re-attach) once ClientReady fires.
  login(): Promise<void>;
  // Tear down the gateway (tests / graceful shutdown).
  destroy(): Promise<void>;
}

export function createApp(deps: CreateAppDeps): App {
  const { config, configStore } = deps;

  // Locale is a global default the i18n catalog reads; set it before any user-facing
  // string is rendered (§8.1 config.locale, §11 item 14).
  setLocale((config.locale as Locale) ?? 'ko');

  const logger = deps.logger ?? createLogger('app', { level: config.logLevel });

  // ---- Core graph (§2). Dependencies flow one way: everything below depends on
  // ConfigStore/StateStore, nothing in core depends on Discord or a mode. ----
  const stateStore = new StateStore(configStore.dir);
  const channelRegistry = new ChannelRegistry(stateStore);
  const eventBus = new EventBus();
  // Chromium provisioner for image rendering (tables/mermaid → PNG). Cheap to construct
  // (no download/launch here); shared by the wiring layer (executable resolution) and the
  // interaction router (/init + /config install prompts). Cache dir lives in the app home.
  const imageProvisioner = new ChromiumProvisioner({
    cacheDir: ChromiumProvisioner.cacheDirFor(configStore.dir),
    logger,
  });
  const configResolver = new ConfigResolver(configStore, channelRegistry);
  const permissionResolver = new PermissionResolver(configStore, configResolver);
  const authorizer = new Authorizer(configStore, channelRegistry);
  const auditLog = new AuditLog({ baseDir: configStore.dir });
  const usageService = new UsageService({
    logger,
    userAgentVersion: config.usage.userAgent,
    cacheSec: config.usage.cacheSec,
    ...(deps.fetchFn ? { fetchFn: deps.fetchFn } : {}),
  });
  // Grok Build weekly-limit poller (separate endpoint/auth from Claude OAuth).
  const grokUsageService = new GrokUsageService({
    logger,
    cacheSec: config.usage.cacheSec,
    ...(deps.fetchFn ? { fetchFn: deps.fetchFn } : {}),
  });
  // Codex rate limits via short-lived app-server account/rateLimits/read.
  // Expand `~` in codexHome — passing literal "~/.codex" as CODEX_HOME makes app-server exit 1.
  const codexUsageService = new CodexUsageService({
    logger,
    cacheSec: config.usage.cacheSec,
    ...(config.defaults.codexCliCommand !== undefined
      ? { codexCommand: config.defaults.codexCliCommand }
      : {}),
    codexHome: resolveCodexHome(config.defaults.codexHome),
  });
  const modeRegistry = new ModeRegistry();

  // ---- Discord session wiring (renderers + permission buttons + sendFile) ----
  // Built BEFORE the orchestrator so its requestPermission hook can be injected into
  // the orchestrator at construction (the orchestrator's requestPermission is a
  // constructor dep, not a mutable field). resolveChannel is bound to the live
  // gateway once the client exists (below), via setResolveChannel.
  const wiring = new SessionWiring({
    eventBus,
    modeRegistry,
    channelRegistry,
    usageService,
    grokUsageService,
    codexUsageService,
    logger,
    auditLog,
    // Read the guild's notifications config at attach() to forward key session events
    // (result/error; tool_use if enabled) to the per-guild status channel.
    configStore,
    // Resolve the browser executable + install state for image rendering at attach().
    imageProvisioner,
    permissionTimeoutSec: config.limits.permissionTimeoutSec,
    // Always-allow persistence (§7A): a tool the operator chose "always-allow" for
    // is written into the GLOBAL autoAllowClaudeTools set, so the next turn (on any
    // channel) auto-allows it via PermissionResolver → orchestrator → canUseTool.
    // The wiring layer audits the GLOBAL write (who/where) before this runs.
    onAlwaysAllow: (toolName: string) => {
      configStore.addAutoAllowClaudeTool(toolName);
    },
  });

  const orchestrator = new SessionOrchestrator({
    channelRegistry,
    modeRegistry,
    eventBus,
    configResolver,
    permissionResolver,
    auditLog,
    logger,
    // Route orchestrator permission prompts through the wiring's per-channel
    // PermissionButtonsHandler (§7.5); the config timeout denies on expiry.
    requestPermission: wiring.requestPermission,
  });

  // Loopback attach gateway for subprocess backends (Grok MCP attach_file). One per app.
  const attachGateway = createAttachGateway();

  // ---- Register the backends (§4/§10). Registering a mode automatically surfaces
  // it as a `/mode backend` choice and in the channel wizard (both read
  // modeRegistry.list()). ----
  // Claude: sendFileFor is wired to the wiring layer's per-channel sink factory so
  // the in-process attach_file MCP tool can deliver a confined file to the channel a
  // session is bound to (kept out of the mode so modes stay transport-agnostic).
  // shareDocumentFor is the sibling factory for the in-process share_document tool
  // (path-only markdown → Discord thread; same funnel as the /doc slash).
  modeRegistry.register(
    new ClaudeMode({
      sendFileFor: (guildId, channelId) => wiring.sendFileFor(guildId, channelId),
      shareDocumentFor: (guildId, channelId) => wiring.shareDocumentFor(guildId, channelId),
    }),
  );
  // Codex: long-lived `codex app-server` + phase 2 thinking/usage/fileDiff; dynamicTools
  // attach_file when sendFileFor is wired, plus share_document (path-only markdown → Discord
  // thread; same funnel as the /doc slash) when shareDocumentFor is wired.
  modeRegistry.register(
    new CodexMode({
      sendFileFor: (guildId, channelId) => wiring.sendFileFor(guildId, channelId),
      shareDocumentFor: (guildId, channelId) => wiring.shareDocumentFor(guildId, channelId),
    }),
  );
  // Grok Build: long-lived `grok agent stdio` ACP session. fileAttach + share_document via
  // subprocess MCP → AttachGateway (loopback /attach and /share). shareDocumentFor is the
  // sibling factory to sendFileFor (same funnel as the /doc slash), threaded to the ACP
  // session so buildMcpServers registers the share sink on the same loopback token.
  // Persisted ids `grok` / `grok-agent` migrate to `grok-build` on load.
  modeRegistry.register(
    new GrokBuildMode({
      sendFileFor: (guildId, channelId) => wiring.sendFileFor(guildId, channelId),
      shareDocumentFor: (guildId, channelId) => wiring.shareDocumentFor(guildId, channelId),
      attachGateway,
    }),
  );
  // Custom: reuses the Claude SDK but injects env vars extracted from the operator's
  // shell aliases (kimi / claude). Wired like Claude for attach_file + share_document.
  modeRegistry.register(
    new CustomMode({
      sendFileFor: (guildId, channelId) => wiring.sendFileFor(guildId, channelId),
      shareDocumentFor: (guildId, channelId) => wiring.shareDocumentFor(guildId, channelId),
    }),
  );

  // A defaults.mode that no registered backend matches would fail at every use site (a
  // session start throws; the wizard never offers it). Warn ONCE at boot — right after
  // registration — so an operator's config typo / stale id is visible, but NEVER throw:
  // a bad default must not brick boot (§5.4). The value stays as-is (no auto-correction).
  if (!modeRegistry.has(config.defaults.mode)) {
    logger.warn('config defaults.mode is not a registered backend', {
      mode: config.defaults.mode,
      registered: modeRegistry.list(),
    });
  }

  // ---- Discord client (§2/§4). onReady resumes persisted sessions AND re-attaches a
  // RendererDispatcher per resumed channel so a restart restores the live UX (§9). ----
  const messageRouter = new MessageRouter({
    authorizer,
    channelRegistry,
    orchestrator,
    // The router arms a one-shot listener on this bus per accepted turn to clear the
    // ⏳ working indicator (→ ✅/❌) when the channel's turn finishes.
    eventBus,
    logger,
    // A server admin can drive a session by messaging even with an empty role config
    // (never locked out): the router reads this bit off the member's permissions.
    administratorBit: PermissionFlagsBits.Administrator,
    // After a turn is accepted, arm the per-channel idle watchdog so ~3 min of
    // silence posts a one-shot "still working / may have stalled" notice.
    onTurnAccepted: (g, c) => wiring.armIdleWatchdog(g, c),
    // Best-effort renderer re-attach before each turn: a resumed session whose boot attach
    // failed transiently regains its sink before send produces output (lazy re-wire, §6.0).
    // Delegates to the wiring's finite-retry ensureAttached (a no-op when already attached);
    // the AttachOutcome is discarded — the router only needs the attach to have been tried.
    ensureRenderers: async (guildId, channelId, mode) => {
      await wiring.ensureAttached(guildId, channelId, mode);
    },
  });
  const interactionRouter = new InteractionRouter({
    authorizer,
    orchestrator,
    channelRegistry,
    configStore,
    configResolver,
    permissionResolver,
    modeRegistry,
    wiring,
    // /doc funnels through the wiring's per-channel shareDocumentFor factory (mirrors the
    // sendFileFor closure injected into the modes above): it resolves the bound channel +
    // cwd, reads the documentShare config, and posts the markdown into a thread via the
    // documentShare core.
    shareDocumentFor: (guildId, channelId) => wiring.shareDocumentFor(guildId, channelId),
    usageService,
    logger,
    // Chromium provisioner: /init offers a background-install prompt when no browser is
    // present, and /config can install/toggle image rendering later.
    imageProvisioner,
    // Folder-browser roots + per-backend model list are config-driven (§8.1): the
    // saved project favorites seed the browse roots; the model step offers the
    // per-backend model list. Codex's list is a small documented default (the
    // config `defaults.codexModel` — when set — plus common Codex model ids), so the
    // wizard's model step isn't empty; a configured value is offered first. The
    // wizard's model pick is EFFECTIVE: it rides StartParams.model and overrides the
    // matching per-backend config field via SessionOrchestrator.buildContext (Claude →
    // ctx.model, Codex → config.codexModel). Absent/untouched keeps the resolved
    // config default (Codex: empty codexModel lets `codex` use its own config.toml).
    browseRoots: config.favorites,
    // Per-backend model options come from the backend's OWN catalog (§6), so this no
    // longer branches on the backend id — a new mode contributes its list by carrying a
    // catalog, not by editing here. Codex: a documented static list (Codex has no model
    // API; -m is free-form) with config.defaults.codexModel offered first when set. Claude:
    // the SDK's supportedModels(), probed live on EVERY open (no cross-invocation cache)
    // with a short in-tick de-dupe, falling back to the alias list on failure/timeout.
    modelsFor: async (backend: string) => modeRegistry.get(backend).catalog.models(config.defaults.codexModel),
    // Names the wizard's 'custom' backend choice after the operator's actual dotfile
    // config (mirrors /mode backend's choice label — client.ts buildSlashCommands).
    customBackendLabel,
    // Native host-side folder picker for the wizard's folder step (dir:panel) — macOS
    // only, where the bot typically runs in the operator's GUI session and osascript
    // can raise a real Finder open-panel. Other hosts simply don't render the button.
    ...(process.platform === 'darwin' ? { pickFolder: createMacFolderPanelOpener() } : {}),
  });

  // A channel is GONE — either a live ChannelDelete or a boot re-wire that resolved to
  // 10003 (a delete missed while the bot was offline). If it was a BOUND, non-archived
  // session channel, detach its renderers (dispose cancels any armed stream/thinking
  // debounce so no late edit fires at the deleted channel) and stop the turn — a hard
  // remove that also clears any orphan session resumeAll may have created for it. Shared
  // by onChannelDelete and the boot attach loop so both take the EXACT same cleanup path
  // (§7.3). Control channels and unbound/archived channels have no live session → ignored.
  const handleChannelGone = (guildId: string, channelId: string): void => {
    const binding = channelRegistry.get(guildId, channelId);
    if (!binding || binding.archived) return;
    wiring.detach(guildId, channelId);
    void orchestrator.stop(guildId, channelId).catch((err) => {
      logger.error('stop on channel-gone failed', { guildId, channelId, err: String(err) });
    });
  };

  const discord = new DiscordClient({
    clientId: config.discord.clientId,
    logger,
    messageRouter,
    interactionRouter,
    // Only registered backends are offered as `/mode backend` choices. Evaluated at
    // command-registration time, so both Claude and Codex now appear.
    backends: () => modeRegistry.list(),
    onReady: async (client: Client) => {
      // Resume every persisted, non-archived channel binding (fixes A2), then re-wire its
      // renderers so the live UX survives a restart (§9 step 4). The attach loop runs in
      // PARALLEL (resumeAll stays sequential): attachWithRetry adds finite backoff on a
      // transient fetch, so serial awaits would stack per-channel delay — Promise.allSettled
      // collapses the worst case to a single channel's retry window (§6.2). Each channel
      // gets its own independent boot retry budget (≤5).
      await orchestrator.resumeAll();
      await Promise.allSettled(
        channelRegistry
          .list()
          .filter((b) => !b.archived)
          .map(async (binding) => {
            const outcome = await wiring.attachWithRetry(binding.guildId, binding.channelId, binding.mode);
            // 'gone' (10003) = a delete missed while offline → hard-clean the stale binding
            // (same path as a live ChannelDelete). 'unavailable' (retries exhausted) keeps
            // the binding for the next message's lazy ensureAttached to retry. 'attached' = ok.
            if (outcome === 'gone') handleChannelGone(binding.guildId, binding.channelId);
          }),
      );
      // Start the auto-updater only now — the gateway + guilds are ready, so postPrompt
      // can enumerate guilds and resolve their control channels (§4). No-op when disabled.
      autoUpdater.start();
      logger.info('boot complete', { guilds: client.guilds.cache.size });
    },
    // Auto-provision each guild's channel structure on ready / guild-join so /init is
    // optional. Resolves the guild's provisioner over the live gateway, then runs the
    // idempotent, Manage-Channels-guarded, non-throwing provisioner.
    autoProvisionGuild: async (guildId: string, isNewGuild: boolean) => {
      const provisioner = await resolveGuildProvisioner(discord.raw, guildId);
      if (!provisioner) return;
      const channels = await autoProvisionGuild(provisioner, configStore, logger);
      // Only a FRESH invite (GuildCreate) posts the one-time Chromium install prompt to the
      // new control channel. ClientReady re-provisions every existing guild on each restart,
      // so prompting there would re-post the prompt after every boot. The prompt is further
      // gated (render.enabled + chromium.decision==='undecided' + !isInstalled) inside
      // maybePromptRenderSetup, and is best-effort (never affects provisioning).
      if (isNewGuild && channels) await interactionRouter.maybePromptRenderSetup(channels.controlChannelId);
    },
    // A user deleted a channel directly in Discord. Route it through the shared
    // handleChannelGone (detach + stop, hard remove) — the ROOT fix for the Unknown
    // Channel (10003) crash, and the exact same cleanup the boot loop applies to a
    // delete missed while the bot was offline.
    onChannelDelete: (channelId, guildId) => handleChannelGone(guildId, channelId),
    ...(deps.client ? { client: deps.client } : {}),
  });

  // Bind the wiring's channel resolvers to the live gateway now that the client exists.
  // The result-aware resolver (ok/gone/unavailable) drives attach's retry-vs-cleanup;
  // the plain null-or-channel resolver still backs notifier/sendFile.
  wiring.setResolveChannel(SessionWiring.resolveOverClient(discord.raw));
  wiring.setResolveChannelResult(SessionWiring.resolveResultOverClient(discord.raw));
  // Bind the interaction router's guild/channel resolvers for /init + auto-created
  // session channels (same late-binding pattern: the client depends on the router).
  interactionRouter.setResolveGuildProvisioner((guildId) => resolveGuildProvisioner(discord.raw, guildId));
  interactionRouter.setResolveChannel(SessionWiring.resolveOverClient(discord.raw));

  // ---- Auto-update (§7). Created AFTER the client so postPrompt/announce can enumerate
  // guilds and resolve each guild's control channel over the live gateway. This closure is
  // the ONE place guild/discord.js meets the updater — src/update/ depends only on ports.
  // Notifications target each guild's control channel (#session-generator) so the prompt
  // lands where operators act and can carry an admin @mention, admin-gated at the button
  // in interactionRouter. ----
  const resolveControlChannel = SessionWiring.resolveOverClient(discord.raw);
  const forEachControlChannel = async (fn: (channel: MessageChannel, server: ServerConfig | null) => Promise<void>): Promise<void> => {
    for (const guildId of discord.raw.guilds.cache.keys()) {
      const server = configStore.loadServerConfig(guildId);
      const channelId = server?.channels?.controlChannelId;
      if (!channelId) continue;
      const channel = await resolveControlChannel(channelId);
      if (!channel) continue;
      try {
        await fn(channel, server);
      } catch (err) {
        logger.warn('auto-update notify failed', { guildId, err: String(err) });
      }
    }
  };
  const autoUpdater = new AutoUpdater({
    currentVersion: readVersion(),
    // Read fresh each check so a config.json edit + restart takes effect.
    enabled: () => config.autoUpdate.enabled,
    fetchLatest: () =>
      fetchLatestVersion(deps.fetchFn ?? fetch, { logger, userAgent: `discord-agent-bridge/${readVersion()}` }),
    readMeta: () => stateStore.getUpdateMeta(),
    writeMeta: (patch: Partial<UpdateMeta>) => stateStore.setUpdateMeta(patch),
    postPrompt: async (version: string) => {
      const { embed, rows } = buildUpdatePrompt(version, readVersion());
      await forEachControlChannel(async (channel, server) => {
        // Ping the guild's effective admin roles so Discord actually notifies; @here when
        // no admin role is configured. The mention text is per-guild, so build it here.
        const adminRoles = server?.auth?.adminRoleIds ?? config.auth.adminRoleIds;
        if (adminRoles.length > 0) {
          const content = adminRoles.map((id) => `<@&${id}>`).join(' ');
          await channel.send({ content, embeds: [embed], components: rows, mentionRoleIds: adminRoles });
        } else {
          await channel.send({ content: '@here', embeds: [embed], components: rows, mentionHere: true });
        }
      });
    },
    announce: async (text: string) => {
      await forEachControlChannel(async (channel) => {
        await channel.send({ content: text });
      });
    },
    install: () => installLatest(realCommandRunner, process.platform),
    // Detect the run form (§3.3) and restart accordingly: supervised = exit only (the
    // service manager relaunches, so `service restart`/`uninstall` stay in control);
    // respawn = spawn a detached successor then exit (foreground / npx / Windows).
    restart: () =>
      performRestart({
        strategy: detectRestartStrategy({
          platform: process.platform,
          env: process.env,
          home: os.homedir(),
          fileExists: (p) => fs.existsSync(p),
        }),
        nodePath: process.execPath,
        cliEntry: appCliEntry(),
        spawn: (command, args, options) => spawn(command, args, options),
        exit: (code) => process.exit(code),
        env: process.env,
      }),
    messages: {
      busy: t('update.busy'),
      installed: t('update.installed'),
      installFailed: t('update.installFailed'),
      dismissed: t('update.dismissed'),
    },
    logger,
  });
  interactionRouter.setAutoUpdater(autoUpdater);

  return {
    discord,
    orchestrator,
    modeRegistry,
    wiring,
    usageService,
    logger,
    config,
    login: () => discord.login(config.discord.token),
    destroy: async () => {
      // Stop the update interval and clear the PID file before tearing down the gateway.
      autoUpdater.stop();
      try {
        removePidFile(configStore.dir, realMinimalFs);
      } catch (err) {
        logger.warn('failed to remove pid file', { err: String(err) });
      }
      // Release the warm image-render browser (if one was launched) before tearing down the
      // gateway, so a graceful shutdown frees Chromium instead of relying on the idle timer.
      await wiring.closeImageRenderer();
      try {
        await attachGateway.close();
      } catch (err) {
        logger.warn('failed to close attach gateway', { err: String(err) });
      }
      await discord.destroy();
    },
  };
}

// Boot the bot end-to-end: load config, build the app, log in. Injectable base dir
// so an operator/test can point at a non-default DAB home.
export interface StartBotOptions {
  baseDir?: string;
}

// LAST-LINE-OF-DEFENSE process safety net. This is NOT the primary crash fix — the
// real fixes are at the source (channelDelete → stop/detach; streamEmbed flush
// swallows a best-effort preview failure). This only ensures that a truly unforeseen
// stray rejection/exception (e.g. a transient REST/network error deep in a library)
// is LOGGED and does NOT hard-crash a long-running bot. Registration is idempotent per
// target (a WeakSet) so calling startBot() repeatedly (tests) never stacks duplicate
// listeners. Target is injectable so a unit test asserts registration without touching
// the real process.
const wiredSafetyNets = new WeakSet<object>();

export function installGlobalSafetyNet(logger: Logger, target: Pick<NodeJS.EventEmitter, 'on'> = process): void {
  if (wiredSafetyNets.has(target)) return;
  wiredSafetyNets.add(target);
  target.on('unhandledRejection', (reason: unknown) => {
    logger.error('unhandled promise rejection (process kept alive)', {
      reason: reason instanceof Error ? reason.message : String(reason),
    });
  });
  target.on('uncaughtException', (err: unknown) => {
    logger.error('uncaught exception (process kept alive)', {
      err: err instanceof Error ? err.message : String(err),
    });
  });
}

// Boot the bot. The two EXPECTED first-run conditions — no config file yet, or a
// config with no Discord token — are not bugs: they mean the operator hasn't run
// `--setup`. For those we print a short, actionable message and set a non-zero exit
// code, then return undefined (no App), instead of letting a raw stack trace out.
// Any OTHER failure (a corrupt/invalid config, a genuine login error) still throws
// so real bugs surface. Returns the running App, or undefined when we bailed with a
// friendly message.
export async function startBot(opts: StartBotOptions = {}): Promise<App | undefined> {
  const configStore = new ConfigStore(opts.baseDir);

  // Not set up yet: no config.json. Point the user at the wizard, exit cleanly.
  if (!configStore.exists()) {
    console.error(t('boot.noConfig'));
    process.exitCode = 1;
    return undefined;
  }

  // A present-but-invalid config is a real error and propagates (not the friendly path).
  const config = configStore.load();

  // Config exists but the token is missing/empty: discord.login('') would dump a
  // stack. Give the same friendly, actionable guidance instead.
  if (config.discord.token.trim().length === 0) {
    setLocale((config.locale as Locale) ?? 'ko');
    console.error(t('boot.noToken'));
    process.exitCode = 1;
    return undefined;
  }

  const logger = createLogger('app', { level: config.logLevel });
  installGlobalSafetyNet(logger);
  const app = createApp({ config, configStore, logger });
  // Record this process's PID (§3.5) so an operator can terminate a detached-respawned
  // (method-B) instance in the foreground case. Best-effort — a write failure never
  // blocks boot. App.destroy removes it.
  try {
    writePidFile(configStore.dir, process.pid, realMinimalFs);
  } catch (err) {
    logger.warn('failed to write pid file', { err: String(err) });
  }
  await app.login();
  return app;
}
