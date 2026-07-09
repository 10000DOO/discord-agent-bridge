import {
  ActionRowBuilder,
  AttachmentBuilder,
  ButtonBuilder,
  ButtonStyle,
  ChannelSelectMenuBuilder,
  ChannelType,
  Client,
  EmbedBuilder,
  Events,
  GatewayIntentBits,
  MessageFlags,
  ModalBuilder,
  PermissionFlagsBits,
  REST,
  RoleSelectMenuBuilder,
  Routes,
  SlashCommandBuilder,
  StringSelectMenuBuilder,
  TextInputBuilder,
  TextInputStyle,
  type AutocompleteInteraction,
  type ChatInputCommandInteraction,
  type Guild,
  type Interaction,
  type Message,
  type MessageActionRowComponentBuilder,
  type MessageComponentInteraction,
  type MessageCreateOptions,
  type ModalActionRowComponentBuilder,
  type ModalSubmitInteraction as DjsModalSubmitInteraction,
  type RESTPostAPIApplicationCommandsJSONBody,
  type SendableChannels,
  type TextBasedChannel,
} from 'discord.js';
import type { Logger } from '../core/contracts.js';
import { customBackendLabel } from '../modes/custom/shellEnv.js';
import type { GuildChannelProvisioner, ProvisionedChannel } from './guildChannels.js';
import { t } from './i18n.js';
import type {
  ButtonSpec,
  ChannelSelectSpec,
  ComponentRow,
  EditableMessage,
  EmbedSpec,
  MessageChannel,
  MessageThread,
  ModalSpec,
  OutgoingMessage,
  RoleSelectSpec,
  SelectSpec,
} from './ports.js';
import type { IncomingMessage, MessageRouter } from './messageRouter.js';
import type {
  AckPayload,
  ComponentInteraction,
  InteractionRouter,
  ModalSubmitInteraction,
  RouterInteraction,
  SlashInteraction,
} from './interactionRouter.js';

// The gateway client (§2/§4). The ONLY place (with the two routers) that imports
// discord.js: it constructs the Client with the required intents, registers the
// slash commands on ready, resumes persisted sessions on ready, and adapts real
// discord.js channels/messages/threads onto the narrow ports.ts interfaces the
// renderers/wizard consume. Everything downstream is discord.js-free.

// Required intents (README): MessageContent + GuildMembers are the privileged
// intents that must also be enabled in the Discord developer portal.
const INTENTS = [
  GatewayIntentBits.Guilds,
  GatewayIntentBits.GuildMessages,
  GatewayIntentBits.MessageContent,
  GatewayIntentBits.GuildMembers,
];

// ---------------------------------------------------------------------------
// Slash command definitions (§9 lifecycle). Adapted from A4D commands/index.ts,
// re-shaped to this project's /agent start|resume|close, /mode, /stop, /stop-all.
// ---------------------------------------------------------------------------

// Human-readable choice labels for known backends; an unknown backend falls back to
// its raw id, so a newly registered backend still appears (just un-prettified). `custom`
// is deliberately absent — its label names the ACTUAL configured provider (e.g. "Custom
// (kimi-k2.7-code)"), computed fresh via customBackendLabel() below, not a fixed string.
const BACKEND_LABELS: Record<string, string> = {
  claude: 'Claude Code',
  codex: 'Codex',
};

// Build the slash commands. `backends` is the list of REGISTERED backend ids
// (modeRegistry.list()): only these appear as `/mode backend` choices, so a backend
// that is not yet registered (e.g. Codex before Phase 2) is not offered. Generic —
// a backend registered later automatically becomes a choice.
// `opts.customBackendLabel` overrides the `custom` backend's choice label — tests inject
// a literal string so this stays a pure function; production leaves it undefined and
// falls back to a fresh dotfile scan (customBackendLabel(), see modes/custom/shellEnv.ts).
export function buildSlashCommands(
  backends: string[],
  opts: { customBackendLabel?: string } = {},
): RESTPostAPIApplicationCommandsJSONBody[] {
  const agent = new SlashCommandBuilder()
    .setName('agent')
    .setDescription('Manage the agent session in this channel')
    .addSubcommand((s) => s.setName('start').setDescription('Start a new agent session (wizard)'))
    .addSubcommand((s) => s.setName('resume').setDescription('Resume a prior session in this channel'))
    .addSubcommand((s) => s.setName('close').setDescription('Stop and archive this channel’s session'))
    .addSubcommand((s) => s.setName('stats').setDescription('활성 세션·바인딩·사용량 요약 보기'));

  const backendChoices = backends.map((b) => ({
    name: b === 'custom' ? opts.customBackendLabel ?? customBackendLabel() : BACKEND_LABELS[b] ?? b,
    value: b,
  }));
  const mode = new SlashCommandBuilder()
    .setName('mode')
    .setDescription('Switch the backend or permission mode')
    .addSubcommand((s) =>
      s
        .setName('backend')
        .setDescription('Switch the agent backend (starts a fresh context)')
        .addStringOption((o) =>
          o
            .setName('backend')
            .setDescription('Backend to switch to')
            .setRequired(true)
            .addChoices(...backendChoices),
        ),
    )
    .addSubcommand((s) =>
      s
        .setName('perm')
        .setDescription('Switch the permission mode or profile (session kept)')
        .addStringOption((o) =>
          o.setName('value').setDescription('Permission mode or profile name').setRequired(true),
        ),
    );

  // /model <value>: switch the Claude model for this session, applied live (no
  // restart). A top-level command (not a /mode subcommand) since it is the operator's
  // most frequent switch. `value` is autocomplete-driven (client.ts InteractionCreate
  // handler → InteractionRouter.getModelAutocomplete → providerCatalog.getClaudeModels),
  // NOT a static addChoices() list — Discord's own opus/sonnet/haiku aliases plus every
  // model the account's SDK actually reports (e.g. a Fable/Mythos release) all show up.
  const model = new SlashCommandBuilder()
    .setName('model')
    .setDescription('Switch the model for this session (Claude, applied live)')
    .addStringOption((o) =>
      o.setName('value').setDescription('Model to switch to').setRequired(true).setAutocomplete(true),
    );

  const stop = new SlashCommandBuilder()
    .setName('stop')
    .setDescription('Stop this channel’s session');

  const stopAll = new SlashCommandBuilder()
    .setName('stop-all')
    .setDescription('Stop every active session (admin)');

  // /config opens the role-tier + defaults panel. Bootstrap gate: only members with
  // the Discord Administrator permission see/use it by default, since the role
  // allowlist may still be empty on first run (the interaction router additionally
  // allows the admin tier once it is configured — see interactionRouter.authorize).
  const config = new SlashCommandBuilder()
    .setName('config')
    .setDescription('Configure role tiers and defaults for this server')
    .setDefaultMemberPermissions(PermissionFlagsBits.Administrator);

  // /init creates the A4D-style channel structure (control channel + sessions
  // category). Administrator-gated: it creates channels, so only server admins run it.
  const init = new SlashCommandBuilder()
    .setName('init')
    .setDescription('Create the agent control channel and sessions category')
    .setDefaultMemberPermissions(PermissionFlagsBits.Administrator);

  return [agent.toJSON(), mode.toJSON(), model.toJSON(), stop.toJSON(), stopAll.toJSON(), config.toJSON(), init.toJSON()];
}

// ---------------------------------------------------------------------------
// discord.js → ports.ts adapters. These are the thin adapter the renderers,
// wizard, and permission buttons consume — no discord.js leaks past this file.
// ---------------------------------------------------------------------------

// Build the discord.js MessageCreateOptions from a plain OutgoingMessage. Embeds,
// component rows, files, and allowed-mentions are mapped here; `ephemeral` is a
// no-op on a channel send (it only applies to interaction replies — see the
// routers) and is ignored, exactly as ports.ts documents.
export function toMessageOptions(msg: OutgoingMessage): MessageCreateOptions {
  const options: MessageCreateOptions = {};
  if (msg.content !== undefined) options.content = msg.content;
  if (msg.embeds && msg.embeds.length > 0) options.embeds = msg.embeds.map(toEmbed);
  if (msg.components && msg.components.length > 0) options.components = msg.components.map(toRow);
  if (msg.files && msg.files.length > 0) {
    options.files = msg.files.map((f) => new AttachmentBuilder(f.path, f.name ? { name: f.name } : {}));
  }
  if (msg.mentionUserIds && msg.mentionUserIds.length > 0) {
    options.allowedMentions = { users: msg.mentionUserIds };
  } else if (msg.content !== undefined) {
    // No explicit pings requested → suppress accidental @mentions from content.
    options.allowedMentions = { parse: [] };
  }
  return options;
}

function toEmbed(spec: EmbedSpec): EmbedBuilder {
  const embed = new EmbedBuilder();
  if (spec.title !== undefined) embed.setTitle(spec.title);
  if (spec.description !== undefined) embed.setDescription(spec.description);
  if (spec.color !== undefined) embed.setColor(spec.color);
  if (spec.fields && spec.fields.length > 0) {
    embed.addFields(spec.fields.map((f) => ({ name: f.name, value: f.value, inline: f.inline ?? false })));
  }
  if (spec.footer !== undefined) embed.setFooter({ text: spec.footer });
  return embed;
}

function toRow(row: ComponentRow): ActionRowBuilder<MessageActionRowComponentBuilder> {
  const builder = new ActionRowBuilder<MessageActionRowComponentBuilder>();
  for (const c of row.components) {
    if (c.type === 'button') builder.addComponents(toButton(c));
    else if (c.type === 'roleSelect') builder.addComponents(toRoleSelect(c));
    else if (c.type === 'channelSelect') builder.addComponents(toChannelSelect(c));
    else builder.addComponents(toSelect(c));
  }
  return builder;
}

const BUTTON_STYLE = {
  primary: ButtonStyle.Primary,
  secondary: ButtonStyle.Secondary,
  success: ButtonStyle.Success,
  danger: ButtonStyle.Danger,
} as const;

function toButton(spec: ButtonSpec): ButtonBuilder {
  const button = new ButtonBuilder()
    .setCustomId(spec.customId)
    .setLabel(spec.label)
    .setStyle(BUTTON_STYLE[spec.style]);
  if (spec.disabled) button.setDisabled(true);
  return button;
}

function toSelect(spec: SelectSpec): StringSelectMenuBuilder {
  const select = new StringSelectMenuBuilder().setCustomId(spec.customId).addOptions(
    spec.options.map((o) => ({
      label: o.label,
      value: o.value,
      ...(o.description !== undefined ? { description: o.description } : {}),
      ...(o.default !== undefined ? { default: o.default } : {}),
    })),
  );
  if (spec.placeholder !== undefined) select.setPlaceholder(spec.placeholder);
  return select;
}

// A Discord Role Select menu (the /config role-tier pickers). min/maxValues bound
// the multi-select; defaultRoleIds prefill the tier's current roles so the panel
// shows the effective values. The user picks role NAMES; the values are role IDs.
function toRoleSelect(spec: RoleSelectSpec): RoleSelectMenuBuilder {
  const select = new RoleSelectMenuBuilder().setCustomId(spec.customId);
  if (spec.placeholder !== undefined) select.setPlaceholder(spec.placeholder);
  if (spec.minValues !== undefined) select.setMinValues(spec.minValues);
  if (spec.maxValues !== undefined) select.setMaxValues(spec.maxValues);
  if (spec.defaultRoleIds && spec.defaultRoleIds.length > 0) {
    select.setDefaultRoles(spec.defaultRoleIds);
  }
  return select;
}

// A Discord Channel Select menu (the /config notifications status-channel picker),
// constrained to GuildText channels. The user picks a channel by name; the values are
// channel IDs. defaultChannelIds prefill the currently-configured channel.
function toChannelSelect(spec: ChannelSelectSpec): ChannelSelectMenuBuilder {
  const select = new ChannelSelectMenuBuilder()
    .setCustomId(spec.customId)
    .setChannelTypes(ChannelType.GuildText);
  if (spec.placeholder !== undefined) select.setPlaceholder(spec.placeholder);
  if (spec.minValues !== undefined) select.setMinValues(spec.minValues);
  if (spec.maxValues !== undefined) select.setMaxValues(spec.maxValues);
  if (spec.defaultChannelIds && spec.defaultChannelIds.length > 0) {
    select.setDefaultChannels(spec.defaultChannelIds);
  }
  return select;
}

// A Discord modal (the /config Codex-path input). Each field becomes a single-line
// TextInput on its own ModalActionRow; a prefilled value is set as the input's value.
// discord.js requires TextInput on a ModalActionRowComponentBuilder row, distinct from
// the message-component row builder used elsewhere.
function toModal(spec: ModalSpec): ModalBuilder {
  const modal = new ModalBuilder().setCustomId(spec.customId).setTitle(spec.title);
  const rows = spec.fields.map((field) => {
    const input = new TextInputBuilder()
      .setCustomId(field.customId)
      .setLabel(field.label)
      .setStyle(TextInputStyle.Short)
      .setRequired(field.required ?? false);
    if (field.value !== undefined) input.setValue(field.value);
    if (field.placeholder !== undefined) input.setPlaceholder(field.placeholder);
    return new ActionRowBuilder<ModalActionRowComponentBuilder>().addComponents(input);
  });
  modal.addComponents(...rows);
  return modal;
}

// A posted discord.js Message adapted onto EditableMessage.
class MessageAdapter implements EditableMessage {
  constructor(private readonly message: Message) {}
  get id(): string {
    return this.message.id;
  }
  async edit(message: OutgoingMessage): Promise<void> {
    // discord.js edit accepts the same option shape as send for these fields.
    await this.message.edit(toMessageOptions(message) as Parameters<Message['edit']>[0]);
  }
}

// A discord.js thread adapted onto MessageThread.
class ThreadAdapter implements MessageThread {
  constructor(private readonly thread: SendableChannels) {}
  get id(): string {
    return this.thread.id;
  }
  async send(message: OutgoingMessage): Promise<EditableMessage> {
    const sent = await this.thread.send(toMessageOptions(message));
    return new MessageAdapter(sent);
  }
}

// A discord.js text channel adapted onto MessageChannel — the single sink every
// renderer receives. Threads are opened either off a message (message.startThread)
// or standalone on the channel (channel.threads.create), matching ports.ts.
export class ChannelAdapter implements MessageChannel {
  constructor(private readonly channel: SendableChannels) {}

  async send(message: OutgoingMessage): Promise<EditableMessage> {
    const sent = await this.channel.send(toMessageOptions(message));
    return new MessageAdapter(sent);
  }

  async startThread(name: string, startFromMessageId?: string): Promise<MessageThread> {
    // Thread off a specific message when we have its id and the channel supports it.
    if (startFromMessageId && 'messages' in this.channel) {
      const parent = await this.channel.messages.fetch(startFromMessageId);
      const thread = await parent.startThread({ name });
      return new ThreadAdapter(thread as unknown as SendableChannels);
    }
    if ('threads' in this.channel) {
      const thread = await this.channel.threads.create({ name });
      return new ThreadAdapter(thread as unknown as SendableChannels);
    }
    throw new Error('Channel does not support threads.');
  }
}

// True when a fetched channel can be sent to (text-based, not a category/voice).
function isSendable(channel: TextBasedChannel | null): channel is SendableChannels {
  return channel !== null && 'send' in channel && typeof channel.send === 'function';
}

// Resolve a channel id to a ChannelAdapter, or null if it is missing/not sendable.
// Used by the wiring layer to obtain the sink for a session's renderers.
export async function resolveChannelAdapter(
  client: Client,
  channelId: string,
): Promise<ChannelAdapter | null> {
  const channel = await client.channels.fetch(channelId).catch(() => null);
  if (channel && isSendable(channel as TextBasedChannel)) {
    return new ChannelAdapter(channel as SendableChannels);
  }
  return null;
}

// A discord.js Guild adapted onto the GuildChannelProvisioner port — the single place
// that touches guild.channels.create/delete for the /init + session-channel flows.
// Every ensure* checks the guild's channel cache for the given id first (idempotency)
// and only creates when absent, mirroring A4D's init.
class GuildProvisionerAdapter implements GuildChannelProvisioner {
  constructor(private readonly guild: Guild) {}

  get guildId(): string {
    return this.guild.id;
  }

  // The bot has Manage Channels in this guild. Reads the bot member's resolved
  // permissions (guild.members.me). Absent member (not yet cached) → false, so
  // auto-provision skips with a warning rather than attempting a create that would fail.
  canManageChannels(): boolean {
    const me = this.guild.members.me;
    return me?.permissions.has(PermissionFlagsBits.ManageChannels) ?? false;
  }

  channelExists(id: string): boolean {
    return this.guild.channels.cache.has(id);
  }

  async ensureCategory(name: string, existingId?: string): Promise<ProvisionedChannel> {
    if (existingId) {
      const cached = this.guild.channels.cache.get(existingId);
      if (cached) return { id: cached.id, name: cached.name };
    }
    const created = await this.guild.channels.create({ name, type: ChannelType.GuildCategory });
    return { id: created.id, name: created.name };
  }

  async ensureTextChannel(name: string, parentId: string, existingId?: string): Promise<ProvisionedChannel> {
    if (existingId) {
      const cached = this.guild.channels.cache.get(existingId);
      if (cached) return { id: cached.id, name: cached.name };
    }
    const created = await this.guild.channels.create({ name, type: ChannelType.GuildText, parent: parentId });
    return { id: created.id, name: created.name };
  }

  async createTextChannel(name: string, parentId?: string): Promise<ProvisionedChannel> {
    const created = await this.guild.channels.create({
      name,
      type: ChannelType.GuildText,
      ...(parentId ? { parent: parentId } : {}),
    });
    return { id: created.id, name: created.name };
  }

  async renameChannel(id: string, name: string): Promise<void> {
    const channel = this.guild.channels.cache.get(id) ?? (await this.guild.channels.fetch(id).catch(() => null));
    if (channel) await channel.setName(name).catch(() => {});
  }

  async deleteChannel(id: string): Promise<void> {
    const channel = this.guild.channels.cache.get(id) ?? (await this.guild.channels.fetch(id).catch(() => null));
    if (channel) await channel.delete().catch(() => {});
  }
}

// Resolve a guildId to a GuildChannelProvisioner over the live client, or null when
// the guild is unknown (not cached / bot no longer a member). Used by the interaction
// router for /init and /agent start's session-channel creation.
export async function resolveGuildProvisioner(
  client: Client,
  guildId: string,
): Promise<GuildChannelProvisioner | null> {
  const guild = client.guilds.cache.get(guildId) ?? (await client.guilds.fetch(guildId).catch(() => null));
  if (!guild) return null;
  return new GuildProvisionerAdapter(guild);
}

// ---------------------------------------------------------------------------
// The gateway client
// ---------------------------------------------------------------------------

export interface DiscordClientDeps {
  clientId: string;
  logger: Logger;
  messageRouter: MessageRouter;
  interactionRouter: InteractionRouter;
  // The REGISTERED backend ids offered as `/mode backend` choices. Evaluated at
  // command-registration time (on ready / guild join), so a backend registered
  // before login appears. Wired to modeRegistry.list by the app boot.
  backends: () => string[];
  // Called once on ClientReady (after commands register) to rebind persisted
  // sessions (§9 step 4). Wired to orchestrator.resumeAll by the app boot.
  onReady: (client: Client) => Promise<void>;
  // Auto-provision the 🤖 Agent category + #session-generator control channel + sessions
  // category for a guild, so /init is optional (§ auto-provision). Called for every
  // existing guild on ClientReady (isNewGuild=false) and for a guild the bot is added to on
  // GuildCreate (isNewGuild=true). The flag lets the app post the one-time render-setup
  // prompt ONLY on a fresh invite, not on every restart's re-provisioning of existing
  // guilds. Idempotent + Manage-Channels-guarded + non-throwing (see autoProvisionGuild).
  // App boot wires it to resolve the guild's provisioner over the live gateway; optional so
  // a test without it just skips provisioning.
  autoProvisionGuild?: (guildId: string, isNewGuild: boolean) => Promise<void>;
  // Called when Discord signals a channel was deleted (Events.ChannelDelete, received
  // via the Guilds intent). The app boot wires it to stop + detach the bound session
  // so no renderer keeps editing a channel a user deleted directly in Discord — the
  // ROOT fix for the Unknown Channel (10003) crash loop. Guild channels only; optional
  // so a test may omit it.
  onChannelDelete?: (channelId: string, guildId: string) => void | Promise<void>;
  // Injectable so tests never construct a real gateway Client. Defaults to a real
  // discord.js Client with the required intents.
  client?: Client;
}

export class DiscordClient {
  private readonly client: Client;
  private readonly clientId: string;
  private readonly logger: Logger;
  private readonly messageRouter: MessageRouter;
  private readonly interactionRouter: InteractionRouter;
  private readonly backends: () => string[];
  private readonly onReady: (client: Client) => Promise<void>;
  private readonly autoProvisionGuild?: (guildId: string, isNewGuild: boolean) => Promise<void>;
  private readonly onChannelDelete?: (channelId: string, guildId: string) => void | Promise<void>;

  constructor(deps: DiscordClientDeps) {
    this.client = deps.client ?? new Client({ intents: INTENTS });
    this.clientId = deps.clientId;
    this.logger = deps.logger;
    this.messageRouter = deps.messageRouter;
    this.interactionRouter = deps.interactionRouter;
    this.backends = deps.backends;
    this.onReady = deps.onReady;
    if (deps.autoProvisionGuild) this.autoProvisionGuild = deps.autoProvisionGuild;
    if (deps.onChannelDelete) this.onChannelDelete = deps.onChannelDelete;
    this.registerHandlers();
  }

  // Expose the underlying client so the wiring layer can resolve channels.
  get raw(): Client {
    return this.client;
  }

  private registerHandlers(): void {
    this.client.once(Events.ClientReady, (ready) => {
      void this.handleReady(ready).catch((err) => {
        this.logger.error('ready handler failed', { err: String(err) });
      });
    });

    // Register commands for a guild the bot joins after startup, too, and
    // auto-provision its channel structure so /init is optional (§ auto-provision).
    // The two are INDEPENDENT: a command-registration hiccup must not prevent channel
    // creation, so each is guarded separately (mirrors handleReady's per-guild loop).
    this.client.on(Events.GuildCreate, (guild) => {
      void this.registerCommands(guild.id).catch((err) => {
        this.logger.error('guild-join command registration failed', { guildId: guild.id, err: String(err) });
      });
      if (this.autoProvisionGuild) {
        // isNewGuild=true: a fresh invite → the app may post the one-time render-setup prompt.
        void this.autoProvisionGuild(guild.id, true).catch((err) => {
          this.logger.error('guild-join auto-provision failed', { guildId: guild.id, err: String(err) });
        });
      }
    });

    this.client.on(Events.MessageCreate, (message) => {
      if (message.author.bot) return; // never react to our own / other bots' messages
      void this.messageRouter.handle(adaptMessage(message, this.client)).catch((err) => {
        this.logger.error('message router failed', { err: String(err) });
      });
    });

    this.client.on(Events.InteractionCreate, (interaction: Interaction) => {
      // Autocomplete has its own reply shape (interaction.respond, no defer/reply) and
      // fires on every keystroke, so it is handled separately from — and before — the
      // logged/adapted slash/component/modal path below.
      if (interaction.isAutocomplete()) {
        void this.handleAutocomplete(interaction).catch((err) => {
          this.logger.error('autocomplete handler failed', { err: errWithStack(err) });
        });
        return;
      }
      // Earliest-possible operator log: record that the gateway delivered SOMETHING,
      // even if adaptation/routing below fails. This is the line that was missing when
      // /config showed "application did not respond" with a silent terminal.
      this.logInteractionArrival(interaction);
      let adapted: RouterInteraction | null;
      try {
        adapted = adaptInteraction(interaction);
      } catch (err) {
        // Adaptation itself threw (unexpected member/permissions shape). Never let this
        // leave the interaction unacknowledged — best-effort ack, then log with stack.
        this.logger.error('interaction adaptation failed', { err: errWithStack(err) });
        void ackFailedInteraction(interaction);
        return;
      }
      if (!adapted) return; // unsupported interaction type: ignored (autocomplete returns above; modals are adapted)
      void this.interactionRouter.handle(adapted).catch((err) => {
        this.logger.error('interaction router failed', { err: errWithStack(err) });
        void ackFailedInteraction(interaction);
      });
    });

    // A channel was deleted at the gateway (e.g. a user deleted a session channel in
    // Discord). Hand its id to the app so it can stop + detach the bound session — the
    // ROOT fix for the Unknown Channel (10003) crash: once detached, no renderer edits
    // the now-missing channel. Guild channels only (DM channels host no session).
    this.client.on(Events.ChannelDelete, (channel) => {
      if (!this.onChannelDelete) return;
      if (channel.isDMBased()) return;
      const channelId = channel.id;
      const guildId = channel.guildId;
      void Promise.resolve(this.onChannelDelete(channelId, guildId)).catch((err) => {
        this.logger.error('channelDelete handler failed', { channelId, guildId, err: String(err) });
      });
    });
  }

  // Log the raw arrival of an interaction at the gateway (before adaptation). The
  // router logs a richer receipt line too; this one guarantees a trace even if
  // adaptation throws. discord.js type guards read command/customId safely.
  private logInteractionArrival(interaction: Interaction): void {
    if (interaction.isChatInputCommand()) {
      this.logger.info('interaction arrived', {
        type: 'slash',
        command: interaction.commandName,
        guildId: interaction.guildId,
        userId: interaction.user.id,
      });
    } else if (interaction.isMessageComponent()) {
      this.logger.info('interaction arrived', {
        type: 'component',
        customId: interaction.customId,
        guildId: interaction.guildId,
        userId: interaction.user.id,
      });
    } else if (interaction.isModalSubmit()) {
      this.logger.info('interaction arrived', {
        type: 'modalSubmit',
        customId: interaction.customId,
        guildId: interaction.guildId,
        userId: interaction.user.id,
      });
    }
  }

  // Answer a slash command's autocomplete request. Only /model's `value` option wires
  // one today; any other autocomplete-enabled option would need a branch here too.
  // Never throws into the InteractionCreate handler: a respond() failure (e.g. the
  // interaction already expired past Discord's ~3s autocomplete window, which has no
  // defer/extend mechanism — unlike a slash command's deferReply) is logged at warn,
  // not debug, so a live miss is visible at the app's default log level.
  private async handleAutocomplete(interaction: AutocompleteInteraction): Promise<void> {
    const choices =
      interaction.commandName === 'model'
        ? await this.interactionRouter.getModelAutocomplete(interaction.options.getFocused())
        : [];
    try {
      await interaction.respond(choices);
    } catch (err) {
      this.logger.warn('autocomplete respond failed', { err: String(err) });
    }
  }

  private async handleReady(ready: Client<true>): Promise<void> {
    this.logger.info('gateway ready', { tag: ready.user.tag, guilds: ready.guilds.cache.size });
    for (const [guildId] of ready.guilds.cache) {
      await this.registerCommands(guildId).catch((err) => {
        this.logger.error('command registration failed', { guildId, err: String(err) });
      });
      // Auto-provision each existing guild so the control/session channels appear
      // without a manual /init (idempotent + Manage-Channels-guarded + non-throwing).
      // isNewGuild=false: re-provisioning an existing guild on (re)boot must NOT re-post the
      // render-setup prompt — only a fresh invite (GuildCreate) does.
      if (this.autoProvisionGuild) {
        await this.autoProvisionGuild(guildId, false).catch((err) => {
          this.logger.error('auto-provision failed', { guildId, err: String(err) });
        });
      }
    }
    await this.onReady(this.client);
  }

  // PUT the slash-command JSON for one guild (fast to propagate vs global).
  private async registerCommands(guildId: string): Promise<void> {
    const token = this.client.token;
    if (!token) throw new Error('Cannot register commands before login (no token).');
    const rest = new REST({ version: '10' }).setToken(token);
    const body = buildSlashCommands(this.backends());
    await rest.put(Routes.applicationGuildCommands(this.clientId, guildId), { body });
    this.logger.info('slash commands registered', { guildId, count: body.length });
  }

  async login(token: string): Promise<void> {
    await this.client.login(token);
  }

  async destroy(): Promise<void> {
    await this.client.destroy();
  }
}

// Serialize an error to a redaction-friendly shape that KEEPS the stack, so the
// operator terminal shows where a failure originated (a bare String(err) drops it).
function errWithStack(err: unknown): { message: string; stack?: string } {
  return err instanceof Error ? { message: err.message, stack: err.stack } : { message: String(err) };
}

// Last-resort acknowledgment for a raw interaction whose adaptation or routing threw
// BEFORE the router could ack it. Discord must never show "application did not
// respond": if the interaction is repliable and not yet acked, send an ephemeral
// error; if already deferred/replied, edit it. Best-effort — swallow any failure (the
// interaction may already be expired). No secrets are surfaced (a generic message).
async function ackFailedInteraction(interaction: Interaction): Promise<void> {
  try {
    if (!interaction.isRepliable()) return;
    const content = t('cmd.error.generic');
    if (interaction.deferred || interaction.replied) {
      await interaction.editReply({ content });
    } else {
      await interaction.reply({ content, flags: MessageFlags.Ephemeral });
    }
  } catch {
    // best-effort: nothing more we can do for an already-expired interaction.
  }
}

// Adapt a raw discord.js Message onto the router's narrow IncomingMessage. The real
// Message already satisfies most of the shape structurally (content/author/react/
// reply/…); this adds `removeReaction`, which discord.js does not expose directly —
// it maps onto message.reactions to remove the BOT's own reaction (used to clear the
// ⏳ working indicator on completion). Best-effort: a missing/uncached reaction or a
// permission error resolves quietly so a clear never breaks a turn.
export function adaptMessage(message: Message, client: Client): IncomingMessage {
  const removeReaction = async (emoji: string): Promise<void> => {
    const botId = client.user?.id;
    if (!botId) return;
    const reaction = message.reactions.cache.get(emoji);
    if (!reaction) return;
    await reaction.users.remove(botId).catch(() => {});
  };
  // The Message structurally satisfies IncomingMessage; attach removeReaction without
  // mutating the discord.js object (a fresh spread would drop its methods, so extend
  // via a prototype-preserving wrapper object that delegates the fields we read).
  return Object.assign(message as unknown as IncomingMessage, { removeReaction });
}

// Adapt a raw discord.js Interaction onto the router's narrow RouterInteraction, so
// the router never imports discord.js as a value. Returns null for interactions the
// router does not handle (modals, autocomplete). The `ephemeral` flag on reply is
// translated to MessageFlags.Ephemeral here — the single discord.js-aware boundary.
export function adaptInteraction(interaction: Interaction): RouterInteraction | null {
  // Build the shared discord.js message-body (content + embeds + component rows) from
  // a plain AckPayload. Embeds and component rows are mapped through the same adapters
  // as channel sends, so a malformed payload cannot slip past this seam. The Ephemeral
  // flag is applied ONLY by reply/followUp (deferReply sets visibility separately);
  // editReply cannot carry it (the deferReply already fixed the reply's visibility).
  const buildBody = (options: AckPayload) => ({
    ...(options.content !== undefined ? { content: options.content } : {}),
    ...(options.embeds && options.embeds.length > 0 ? { embeds: options.embeds.map(toEmbed) } : {}),
    ...(options.components && options.components.length > 0 ? { components: options.components.map(toRow) } : {}),
  });
  const withEphemeral = (options: AckPayload) => ({
    ...buildBody(options),
    ...(options.ephemeral ? { flags: MessageFlags.Ephemeral as const } : {}),
  });

  const repliable = () =>
    interaction as ChatInputCommandInteraction | MessageComponentInteraction | DjsModalSubmitInteraction;

  // Shared actor/context + ack methods. `acknowledged` is a GETTER (reads discord.js's
  // live deferred/replied flags) — it must be attached with defineProperty on the final
  // object rather than spread, since spreading an object evaluates a getter ONCE and
  // freezes its value (which would wrongly report the interaction as never acked and
  // send reply() after a defer → discord.js throws). base() returns fresh fields; the
  // getter is defined on each concrete object below.
  const base = () => ({
    guildId: interaction.guildId,
    channelId: interaction.channelId ?? '',
    user: { id: interaction.user.id },
    member: adaptMember(interaction),
    hasAdminPermission: hasAdminPermission(interaction),
    reply: (options: AckPayload) => repliable().reply(withEphemeral(options)),
    deferReply: (options?: { ephemeral?: boolean }) =>
      repliable().deferReply(options?.ephemeral ? { flags: MessageFlags.Ephemeral } : {}),
    editReply: (options: AckPayload) => repliable().editReply(buildBody(options)),
    followUp: (options: AckPayload) => repliable().followUp(withEphemeral(options)),
  });

  // Define the live `acknowledged` getter on the concrete object (not via spread).
  const withAcknowledged = <T extends object>(obj: T): T & { readonly acknowledged: boolean } =>
    Object.defineProperty(obj, 'acknowledged', {
      get: () => {
        const r = repliable();
        return r.deferred || r.replied;
      },
      enumerable: true,
    }) as T & { readonly acknowledged: boolean };

  if (interaction.isChatInputCommand()) {
    const slash = {
      ...base(),
      kind: 'slash' as const,
      commandName: interaction.commandName,
      subcommand: safeSubcommand(interaction),
      getString: (name: string) => interaction.options.getString(name),
    };
    return withAcknowledged(slash) as SlashInteraction;
  }

  if (
    interaction.isButton() ||
    interaction.isStringSelectMenu() ||
    interaction.isRoleSelectMenu() ||
    interaction.isChannelSelectMenu()
  ) {
    // String-select: single `value` (first) for legacy callers; also expose all
    // `values`. Role-select / channel-select: `values` are the picked IDs (no single
    // `value`).
    const values =
      interaction.isStringSelectMenu() || interaction.isRoleSelectMenu() || interaction.isChannelSelectMenu()
        ? interaction.values
        : undefined;
    const value = interaction.isStringSelectMenu() ? interaction.values[0] : undefined;
    const component = {
      ...base(),
      kind: 'component' as const,
      customId: interaction.customId,
      ...(value !== undefined ? { value } : {}),
      ...(values !== undefined ? { values } : {}),
      deferUpdate: () => interaction.deferUpdate(),
      // showModal is the ack for this interaction — the router calls it INSTEAD of
      // deferring (a deferred component can no longer show a modal). Only a button
      // triggers it in practice; the cast is safe (all three are MessageComponent).
      showModal: (modal: ModalSpec) =>
        (interaction as MessageComponentInteraction).showModal(toModal(modal)),
    };
    return withAcknowledged(component) as ComponentInteraction;
  }

  if (interaction.isModalSubmit()) {
    // A submitted modal (the /config Codex-path input). It replies/defers like any
    // interaction; the field values are read by custom id off the submission.
    const modal = {
      ...base(),
      kind: 'modalSubmit' as const,
      customId: interaction.customId,
      getField: (fieldId: string) => {
        try {
          return interaction.fields.getTextInputValue(fieldId);
        } catch {
          return '';
        }
      },
    };
    return withAcknowledged(modal) as ModalSubmitInteraction;
  }

  return null;
}

// True when the acting member has the Discord Administrator permission. Used as the
// /config bootstrap gate (server admins can open /config before the role allowlist
// is set). PREFER interaction.memberPermissions — discord.js resolves it to a
// PermissionsBitField on EVERY guild interaction, cached or not, so it avoids the
// brittle raw-permissions branches below. Falls back to member.permissions (a
// PermissionsBitField on a cached GuildMember, or a string bitfield on an uncached
// APIInteractionGuildMember). Any read error → false (never throw before the ack, or
// the interaction dies unacknowledged → "application did not respond"). DM → false.
function hasAdminPermission(interaction: Interaction): boolean {
  try {
    // memberPermissions is present on guild interactions (null in DMs); it is already
    // a resolved PermissionsBitField for both cached and uncached members.
    const memberPerms = (interaction as { memberPermissions?: { has?: (bit: bigint) => boolean } }).memberPermissions;
    if (memberPerms && typeof memberPerms.has === 'function') {
      return memberPerms.has(PermissionFlagsBits.Administrator);
    }
    const member = interaction.member;
    if (!member) return false;
    const perms = (member as { permissions?: unknown }).permissions;
    if (perms && typeof perms === 'object' && 'has' in perms) {
      return (perms as { has: (bit: bigint) => boolean }).has(PermissionFlagsBits.Administrator);
    }
    if (typeof perms === 'string') {
      return (BigInt(perms) & PermissionFlagsBits.Administrator) === PermissionFlagsBits.Administrator;
    }
    return false;
  } catch {
    return false;
  }
}

// The acting member's role ids, or null when unavailable (DMs). Discord may deliver
// member.roles as a GuildMemberRoleManager (has .cache) — normalize to the router's
// tiny { roles: { cache: { map } } } shape.
function adaptMember(
  interaction: Interaction,
): { roles: { cache: { map: (fn: (r: { id: string }) => string) => string[] } } } | null {
  const member = interaction.member;
  if (!member) return null;
  const roles = member.roles;
  // In a cached guild, roles is a GuildMemberRoleManager with a .cache Collection.
  if (roles && 'cache' in roles) {
    const cache = (roles as { cache: { map: (fn: (r: { id: string }) => string) => string[] } }).cache;
    return { roles: { cache } };
  }
  // Uncached (APIInteractionGuildMember): roles is a string[] of ids.
  const ids = Array.isArray(roles) ? (roles as string[]) : [];
  return { roles: { cache: { map: (fn) => ids.map((id) => fn({ id })) } } };
}

// interaction.options.getSubcommand() throws when the command has no subcommands;
// return null in that case so a flat command (/stop, /stop-all) is handled cleanly.
function safeSubcommand(interaction: ChatInputCommandInteraction): string | null {
  try {
    return interaction.options.getSubcommand(false);
  } catch {
    return null;
  }
}

// Re-export a small helper for ephemeral flags so the routers stay discord.js-free
// where possible. (The routers still import interaction types; this is a convenience.)
export const EPHEMERAL = MessageFlags.Ephemeral;
