import {
  ActionRowBuilder,
  AttachmentBuilder,
  ButtonBuilder,
  ButtonStyle,
  Client,
  EmbedBuilder,
  Events,
  GatewayIntentBits,
  MessageFlags,
  REST,
  Routes,
  SlashCommandBuilder,
  StringSelectMenuBuilder,
  type ChatInputCommandInteraction,
  type Interaction,
  type Message,
  type MessageActionRowComponentBuilder,
  type MessageComponentInteraction,
  type MessageCreateOptions,
  type RESTPostAPIApplicationCommandsJSONBody,
  type SendableChannels,
  type TextBasedChannel,
} from 'discord.js';
import type { Logger } from '../core/contracts.js';
import type {
  ButtonSpec,
  ComponentRow,
  EditableMessage,
  EmbedSpec,
  MessageChannel,
  MessageThread,
  OutgoingMessage,
  SelectSpec,
} from './ports.js';
import type { MessageRouter } from './messageRouter.js';
import type {
  ComponentInteraction,
  InteractionRouter,
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
// its raw id, so a newly registered backend still appears (just un-prettified).
const BACKEND_LABELS: Record<string, string> = {
  claude: 'Claude Code',
  codex: 'Codex',
};

// Build the slash commands. `backends` is the list of REGISTERED backend ids
// (modeRegistry.list()): only these appear as `/mode backend` choices, so a backend
// that is not yet registered (e.g. Codex before Phase 2) is not offered. Generic —
// a backend registered later automatically becomes a choice.
export function buildSlashCommands(backends: string[]): RESTPostAPIApplicationCommandsJSONBody[] {
  const agent = new SlashCommandBuilder()
    .setName('agent')
    .setDescription('Manage the agent session in this channel')
    .addSubcommand((s) => s.setName('start').setDescription('Start a new agent session (wizard)'))
    .addSubcommand((s) => s.setName('resume').setDescription('Resume a prior session in this channel'))
    .addSubcommand((s) => s.setName('close').setDescription('Stop and archive this channel’s session'));

  const backendChoices = backends.map((b) => ({ name: BACKEND_LABELS[b] ?? b, value: b }));
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

  const stop = new SlashCommandBuilder()
    .setName('stop')
    .setDescription('Stop this channel’s session');

  const stopAll = new SlashCommandBuilder()
    .setName('stop-all')
    .setDescription('Stop every active session (admin)');

  return [agent.toJSON(), mode.toJSON(), stop.toJSON(), stopAll.toJSON()];
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
    builder.addComponents(c.type === 'button' ? toButton(c) : toSelect(c));
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

  constructor(deps: DiscordClientDeps) {
    this.client = deps.client ?? new Client({ intents: INTENTS });
    this.clientId = deps.clientId;
    this.logger = deps.logger;
    this.messageRouter = deps.messageRouter;
    this.interactionRouter = deps.interactionRouter;
    this.backends = deps.backends;
    this.onReady = deps.onReady;
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

    // Register commands for a guild the bot joins after startup, too.
    this.client.on(Events.GuildCreate, (guild) => {
      void this.registerCommands(guild.id).catch((err) => {
        this.logger.error('guild-join command registration failed', { guildId: guild.id, err: String(err) });
      });
    });

    this.client.on(Events.MessageCreate, (message) => {
      if (message.author.bot) return; // never react to our own / other bots' messages
      void this.messageRouter.handle(message).catch((err) => {
        this.logger.error('message router failed', { err: String(err) });
      });
    });

    this.client.on(Events.InteractionCreate, (interaction: Interaction) => {
      const adapted = adaptInteraction(interaction);
      if (!adapted) return; // modal / autocomplete / unsupported: ignored
      void this.interactionRouter.handle(adapted).catch((err) => {
        this.logger.error('interaction router failed', { err: String(err) });
      });
    });
  }

  private async handleReady(ready: Client<true>): Promise<void> {
    this.logger.info('gateway ready', { tag: ready.user.tag, guilds: ready.guilds.cache.size });
    for (const [guildId] of ready.guilds.cache) {
      await this.registerCommands(guildId).catch((err) => {
        this.logger.error('command registration failed', { guildId, err: String(err) });
      });
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

// Adapt a raw discord.js Interaction onto the router's narrow RouterInteraction, so
// the router never imports discord.js as a value. Returns null for interactions the
// router does not handle (modals, autocomplete). The `ephemeral` flag on reply is
// translated to MessageFlags.Ephemeral here — the single discord.js-aware boundary.
export function adaptInteraction(interaction: Interaction): RouterInteraction | null {
  const base = {
    guildId: interaction.guildId,
    channelId: interaction.channelId ?? '',
    user: { id: interaction.user.id },
    member: adaptMember(interaction),
    reply: (options: { content: string; ephemeral?: boolean }) => {
      const replyable = interaction as ChatInputCommandInteraction | MessageComponentInteraction;
      return replyable.reply({
        content: options.content,
        ...(options.ephemeral ? { flags: MessageFlags.Ephemeral } : {}),
      });
    },
  };

  if (interaction.isChatInputCommand()) {
    const slash: SlashInteraction = {
      ...base,
      kind: 'slash',
      commandName: interaction.commandName,
      subcommand: safeSubcommand(interaction),
      getString: (name: string) => interaction.options.getString(name),
    };
    return slash;
  }

  if (interaction.isButton() || interaction.isStringSelectMenu()) {
    const value = interaction.isStringSelectMenu() ? interaction.values[0] : undefined;
    const component: ComponentInteraction = {
      ...base,
      kind: 'component',
      customId: interaction.customId,
      ...(value !== undefined ? { value } : {}),
      deferUpdate: () => interaction.deferUpdate(),
    };
    return component;
  }

  return null;
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
