// Minimal Discord "ports" — the narrow surface the presentation layer (renderers,
// wizard, browsers) actually uses, decoupled from discord.js. 7b adapts real
// discord.js objects (TextChannel, Message, ThreadChannel, interactions) onto
// these interfaces; unit tests supply fakes. Keeping the surface tiny means the
// renderers stay pure UX logic with no gateway I/O and no discord.js import.
//
// These types are LOCAL to the discord layer (contracts.ts stays authoritative
// for the core seam). See docs/DESIGN.md §6 (rendering layer) and §2 (the Discord
// layer depends on core contracts only, never the SDK/CLI — here, additionally,
// not on discord.js directly, so the logic is testable without a live client).

// A rendered message payload. Mirrors the subset of discord.js MessageOptions we
// use: plain content and/or embeds and/or interactive component rows. All fields
// are plain data so a fake sink can assert on them without discord.js.
export interface OutgoingMessage {
  content?: string;
  embeds?: EmbedSpec[];
  components?: ComponentRow[];
  // Files to attach (already path-confined by the caller). Rendered by the 7b
  // adapter into discord.js AttachmentBuilder instances.
  files?: OutgoingFile[];
  // When true, the message is only visible to the acting user (ephemeral). Used
  // by the wizard and permission notices. Ignored on channel.send (no-op).
  ephemeral?: boolean;
  // Users to ping (owner @mention on completion). Rendered into allowedMentions.
  mentionUserIds?: string[];
}

export interface OutgoingFile {
  path: string;
  name?: string;
}

// A structured embed — the fields the layer sets. The 7b adapter maps this onto
// discord.js EmbedBuilder. Plain data keeps it assertable in tests.
export interface EmbedSpec {
  title?: string;
  description?: string;
  color?: number;
  fields?: { name: string; value: string; inline?: boolean }[];
  footer?: string;
}

// One action row of interactive components. Only buttons and string-selects are
// used by this layer (permission buttons; wizard/browser selects).
export interface ComponentRow {
  components: (ButtonSpec | SelectSpec)[];
}

export interface ButtonSpec {
  type: 'button';
  customId: string;
  label: string;
  style: 'primary' | 'secondary' | 'success' | 'danger';
  disabled?: boolean;
}

export interface SelectSpec {
  type: 'select';
  customId: string;
  placeholder?: string;
  options: { label: string; value: string; description?: string; default?: boolean }[];
}

// A message already posted to a channel that the layer can edit in place (used
// by the debounced stream embed and by disabling buttons after a decision).
export interface EditableMessage {
  readonly id: string;
  edit(message: OutgoingMessage): Promise<void>;
}

// A thread opened off a channel (per-tool threads). Posts land inside it.
export interface MessageThread {
  readonly id: string;
  send(message: OutgoingMessage): Promise<EditableMessage>;
}

// A channel the layer can post into and open threads on. The single sink every
// renderer receives; a fake implementation drives the unit tests.
export interface MessageChannel {
  send(message: OutgoingMessage): Promise<EditableMessage>;
  // Open a thread for a tool call. `startFromMessageId`, when given, threads off
  // that message (discord.js message.startThread); otherwise a standalone thread.
  startThread(name: string, startFromMessageId?: string): Promise<MessageThread>;
}
