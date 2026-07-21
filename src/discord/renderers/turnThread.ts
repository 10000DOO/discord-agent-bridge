import type { AgentEvent } from '../../core/contracts.js';
import type { MessageChannel, MessageThread } from '../ports.js';
import { THREAD_NAME_LIMIT, truncate } from '../format.js';

// The per-turn work thread shared by the tool-activity renderers (§6). One turn opens
// exactly ONE thread the first time any tool activity happens, and every later tool
// input/result/diff appends to that SAME thread — so a tool-heavy turn no longer floods
// the channel with a thread per tool.
//
// Concurrency: dispatch() invokes toolThread and diff synchronously back-to-back and
// both handlers are async, so their first accesses can race. get() caches the in-flight
// startThread PROMISE and hands the same one to every concurrent caller, so the thread
// is created exactly once. A failed open clears the cache so the next tool activity can
// retry rather than poisoning the whole turn.
//
// No discord.js: the sink is the MessageChannel port. Injected into both ToolThreadHandler
// and DiffViewHandler so they post into the identical thread.

export interface TurnThreadDeps {
  channel: MessageChannel;
  name: string;
}

export class TurnThreadHolder {
  private readonly channel: MessageChannel;
  private readonly name: string;
  // The in-flight-or-settled creation promise for this turn's thread; null until the
  // first get() and again after reset() (turn boundary).
  private creating: Promise<MessageThread> | null = null;

  constructor(deps: TurnThreadDeps) {
    this.channel = deps.channel;
    this.name = deps.name;
  }

  // Open (once) or return this turn's shared thread. Concurrent first callers share the
  // single in-flight promise, so exactly one thread is created.
  get(): Promise<MessageThread> {
    if (!this.creating) {
      const attempt: Promise<MessageThread> = this.channel.startThread(this.name).catch((err) => {
        // A failed open must not poison the turn: drop the cache so the next tool
        // activity retries, but rethrow so this caller still sees the failure. Guard on
        // identity — a late rejection from a PREVIOUS turn's attempt (reset() already
        // cleared it, a new turn set a live promise) must not clear the current turn's
        // creation, which would let it open twice.
        if (this.creating === attempt) this.creating = null;
        throw err;
      });
      this.creating = attempt;
    }
    return this.creating;
  }

  // Whether the thread has been opened (or started opening) this turn. ToolThreadHandler
  // reads this to decide whether an early tool_result can post now or must be buffered.
  get opened(): boolean {
    return this.creating !== null;
  }

  // Turn boundary: drop the reference so the next turn opens a fresh thread. An in-flight
  // fire-and-forget send from the old turn already captured its thread and completes
  // safely. A turn with no tool activity never called get(), so this is a no-op.
  reset(): void {
    this.creating = null;
  }
}

// ---- Multi-thread registry (main + one named thread per subagent spawn) ----

// Case-sensitive tool names that spawn a subagent (Claude Task/Agent, Grok spawn_subagent,
// Codex app-server spawnAgent).
export const SUBAGENT_SPAWN_TOOLS = new Set(['Task', 'Agent', 'spawn_subagent', 'spawnAgent']);

export function isSubagentSpawnTool(name: string): boolean {
  return SUBAGENT_SPAWN_TOOLS.has(name);
}

// Display name for a spawn tool's Discord thread. Prefers subagent_type / subagentType /
// agentRole / agentNickname / description, then the tool name. Capped to Discord's limit.
export function subagentThreadName(name: string, input: unknown): string {
  let raw = name;
  if (input !== null && typeof input === 'object' && !Array.isArray(input)) {
    const o = input as Record<string, unknown>;
    if (typeof o.subagent_type === 'string' && o.subagent_type.length > 0) raw = o.subagent_type;
    else if (typeof o.subagentType === 'string' && o.subagentType.length > 0) raw = o.subagentType;
    else if (typeof o.agentRole === 'string' && o.agentRole.length > 0) raw = o.agentRole;
    else if (typeof o.agentNickname === 'string' && o.agentNickname.length > 0) raw = o.agentNickname;
    else if (typeof o.nickname === 'string' && o.nickname.length > 0) raw = o.nickname;
    else if (typeof o.description === 'string' && o.description.length > 0) raw = o.description;
  }
  return truncate(raw, THREAD_NAME_LIMIT);
}

/** Registry key for the main work thread. */
export const MAIN_THREAD_KEY = 'main';

export interface TurnThreadRegistryDeps {
  channel: MessageChannel;
  /** Display name for the main work thread (callers pass `t('thread.work')`). */
  mainName: string;
}

// Routes tool_use / tool_result events to the correct per-turn Discord thread:
//   - parent-less ordinary tools → main ("작업 내역")
//   - Task / Agent / spawn_subagent → named thread (subagent type/description)
//   - nested tools with parentToolUseId → that spawn's thread
// Lazy-creates a TurnThreadHolder per key; reset() clears everything at turn end.
export class TurnThreadRegistry {
  private readonly channel: MessageChannel;
  private readonly mainName: string;
  private readonly holders = new Map<string, TurnThreadHolder>();
  // toolUseId → thread key (so a tool_result can find its thread without re-deriving).
  private readonly toolIdToKey = new Map<string, string>();
  // spawn tool id → display name for its thread.
  private readonly keyNames = new Map<string, string>();

  constructor(deps: TurnThreadRegistryDeps) {
    this.channel = deps.channel;
    this.mainName = deps.mainName;
  }

  // Bind a tool_use to its thread key (and spawn display name), open that thread, return it.
  async getForToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): Promise<MessageThread> {
    const key = this.bindToolUse(ev);
    return this.get(key);
  }

  // Resolve the thread for a tool_result. Returns null when the target thread has not
  // been opened yet (caller should buffer — same posture as the old single-holder path).
  async getForToolResult(ev: Extract<AgentEvent, { kind: 'tool_result' }>): Promise<MessageThread | null> {
    const key = this.resolveResultKey(ev);
    if (!this.hasOpened(key)) return null;
    return this.get(key);
  }

  // Open (or return) the holder for `key`. Used by DiffView which always posts on result
  // (and by ToolThreadHandler after hasOpened is true).
  get(key: string): Promise<MessageThread> {
    return this.holderFor(key).get();
  }

  hasOpened(key: string): boolean {
    return this.holders.get(key)?.opened ?? false;
  }

  // Record tool id → key (and spawn name). Safe to call from DiffView.noteToolUse without
  // opening a thread. Returns the resolved key.
  bindToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): string {
    const key = this.keyForToolUse(ev);
    this.toolIdToKey.set(ev.id, key);
    if (isSubagentSpawnTool(ev.name) && key !== MAIN_THREAD_KEY && !this.keyNames.has(key)) {
      this.keyNames.set(key, subagentThreadName(ev.name, ev.input));
    }
    return key;
  }

  resolveResultKey(ev: Extract<AgentEvent, { kind: 'tool_result' }>): string {
    const remembered = this.toolIdToKey.get(ev.id);
    if (remembered !== undefined) return remembered;
    if (typeof ev.parentToolUseId === 'string' && ev.parentToolUseId.length > 0) {
      return ev.parentToolUseId;
    }
    return MAIN_THREAD_KEY;
  }

  // Turn boundary: drop all holders and maps so the next turn opens fresh threads.
  reset(): void {
    for (const h of this.holders.values()) h.reset();
    this.holders.clear();
    this.toolIdToKey.clear();
    this.keyNames.clear();
  }

  private keyForToolUse(ev: Extract<AgentEvent, { kind: 'tool_use' }>): string {
    if (typeof ev.parentToolUseId === 'string' && ev.parentToolUseId.length > 0) {
      return ev.parentToolUseId;
    }
    if (isSubagentSpawnTool(ev.name)) return ev.id;
    return MAIN_THREAD_KEY;
  }

  private holderFor(key: string): TurnThreadHolder {
    let holder = this.holders.get(key);
    if (!holder) {
      const name =
        key === MAIN_THREAD_KEY ? this.mainName : (this.keyNames.get(key) ?? truncate(key, THREAD_NAME_LIMIT));
      holder = new TurnThreadHolder({ channel: this.channel, name });
      this.holders.set(key, holder);
    }
    return holder;
  }
}
