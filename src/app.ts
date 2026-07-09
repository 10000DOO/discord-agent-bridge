import { PermissionFlagsBits, type Client } from 'discord.js';
import { ConfigStore, type AppConfig } from './core/config.js';
import { StateStore } from './core/state/store.js';
import { ChannelRegistry } from './core/channelRegistry.js';
import { EventBus } from './core/eventBus.js';
import { ConfigResolver } from './core/configResolver.js';
import { PermissionResolver } from './core/permissionResolver.js';
import { Authorizer } from './core/auth.js';
import { AuditLog } from './core/auditLog.js';
import { UsageService } from './core/usageService.js';
import { ModeRegistry } from './core/modeRegistry.js';
import { SessionOrchestrator } from './core/sessionOrchestrator.js';
import { createLogger } from './core/logger.js';
import type { Logger } from './core/contracts.js';
import { ClaudeMode } from './modes/claude/index.js';
import { CodexMode } from './modes/codex/index.js';
import { CustomMode } from './modes/custom/index.js';
import { getClaudeModels, getCodexModels } from './core/providerCatalog.js';
import { MessageRouter } from './discord/messageRouter.js';
import { InteractionRouter } from './discord/interactionRouter.js';
import { SessionWiring } from './discord/wiring.js';
import { DiscordClient, resolveGuildProvisioner } from './discord/client.js';
import { autoProvisionGuild } from './discord/guildChannels.js';
import { setLocale, t, type Locale } from './discord/i18n.js';

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
    logger,
    auditLog,
    // Read the guild's notifications config at attach() to forward key session events
    // (result/error; tool_use if enabled) to the per-guild status channel.
    configStore,
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

  // ---- Register the backends (§4/§10). Registering a mode automatically surfaces
  // it as a `/mode backend` choice and in the channel wizard (both read
  // modeRegistry.list()). ----
  // Claude: sendFileFor is wired to the wiring layer's per-channel sink factory so
  // the in-process attach_file MCP tool can deliver a confined file to the channel a
  // session is bound to (kept out of the mode so modes stay transport-agnostic).
  modeRegistry.register(
    new ClaudeMode({ sendFileFor: (guildId, channelId) => wiring.sendFileFor(guildId, channelId) }),
  );
  // Codex: no transport-specific deps (fileAttach:false → no sendFile); the runner
  // and ~/.codex discovery are wired inside the mode. Its capabilities disable the
  // Discord renderers Codex doesn't support (§5b/§6).
  modeRegistry.register(new CodexMode());
  // Custom: reuses the Claude SDK but injects env vars extracted from the operator's
  // shell aliases (kimi / claude). Wired like Claude for attach_file delivery.
  modeRegistry.register(
    new CustomMode({ sendFileFor: (guildId, channelId) => wiring.sendFileFor(guildId, channelId) }),
  );

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
    usageService,
    logger,
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
    // Per-backend model options from the central provider catalog (§ providerCatalog).
    // Codex: a documented static default list (Codex has no model-list API; -m is
    // free-form), with config.defaults.codexModel offered first when set. Claude:
    // the SDK's supportedModels(), probed live on EVERY /config or /agent start open
    // (no cross-invocation cache) so a model added or removed on the account is
    // reflected immediately. A short in-tick de-dupe still shares one probe across
    // concurrent callers. On failure/timeout falls back to the alias list.
    modelsFor: async (backend: string) =>
      backend === 'codex'
        ? getCodexModels(config.defaults.codexModel)
        : await getClaudeModels({ logger }),
  });

  const discord = new DiscordClient({
    clientId: config.discord.clientId,
    logger,
    messageRouter,
    interactionRouter,
    // Only registered backends are offered as `/mode backend` choices. Evaluated at
    // command-registration time, so both Claude and Codex now appear.
    backends: () => modeRegistry.list(),
    onReady: async (client: Client) => {
      // Resume every persisted, non-archived channel binding (fixes A2), then
      // re-attach its renderers so the live UX survives a restart (§9 step 4).
      await orchestrator.resumeAll();
      for (const binding of channelRegistry.list().filter((b) => !b.archived)) {
        await wiring.attach(binding.guildId, binding.channelId, binding.mode);
      }
      logger.info('boot complete', { guilds: client.guilds.cache.size });
    },
    // Auto-provision each guild's channel structure on ready / guild-join so /init is
    // optional. Resolves the guild's provisioner over the live gateway, then runs the
    // idempotent, Manage-Channels-guarded, non-throwing provisioner.
    autoProvisionGuild: async (guildId: string) => {
      const provisioner = await resolveGuildProvisioner(discord.raw, guildId);
      if (provisioner) await autoProvisionGuild(provisioner, configStore, logger);
    },
    // A user deleted a channel directly in Discord. If it was a BOUND, non-archived
    // session channel, detach its renderers (dispose cancels any armed stream/thinking
    // debounce so no late edit fires at the deleted channel) and stop the turn. This is
    // the ROOT fix for the Unknown Channel (10003) crash. Control channels and
    // unbound/archived channels have no live session → ignored.
    onChannelDelete: (channelId, guildId) => {
      const binding = channelRegistry.get(guildId, channelId);
      if (!binding || binding.archived) return;
      wiring.detach(guildId, channelId);
      void orchestrator.stop(guildId, channelId).catch((err) => {
        logger.error('stop on channelDelete failed', { guildId, channelId, err: String(err) });
      });
    },
    ...(deps.client ? { client: deps.client } : {}),
  });

  // Bind the wiring's channel resolver to the live gateway now that the client exists.
  wiring.setResolveChannel(SessionWiring.resolveOverClient(discord.raw));
  // Bind the interaction router's guild/channel resolvers for /init + auto-created
  // session channels (same late-binding pattern: the client depends on the router).
  interactionRouter.setResolveGuildProvisioner((guildId) => resolveGuildProvisioner(discord.raw, guildId));
  interactionRouter.setResolveChannel(SessionWiring.resolveOverClient(discord.raw));

  return {
    discord,
    orchestrator,
    modeRegistry,
    wiring,
    usageService,
    logger,
    config,
    login: () => discord.login(config.discord.token),
    destroy: () => discord.destroy(),
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
  await app.login();
  return app;
}
