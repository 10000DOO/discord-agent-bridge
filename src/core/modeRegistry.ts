import type { AgentMode } from './contracts.js';

// name → AgentMode; the single place modes are registered and looked up (§4, §10).
// This is the extensibility seam: adding a backend is register(mode) + nothing
// else in core changes. Modes self-identify via their readonly `name`, so the
// registry keys on mode.name rather than a separately-passed string.
export class ModeRegistry {
  private readonly modes = new Map<string, AgentMode>();

  // Register a mode instance. Throws on a duplicate name so a mis-wired double
  // registration surfaces at boot rather than silently shadowing.
  register(mode: AgentMode): void {
    if (this.modes.has(mode.name)) {
      throw new Error(`Mode '${mode.name}' is already registered.`);
    }
    this.modes.set(mode.name, mode);
  }

  // Look up a registered mode by name; throws if unknown so callers get a clear
  // error instead of an undefined dereference.
  get(name: string): AgentMode {
    const mode = this.modes.get(name);
    if (!mode) {
      throw new Error(`Unknown mode '${name}'. Registered: ${this.list().join(', ') || '(none)'}.`);
    }
    return mode;
  }

  // Non-throwing lookup for callers that want to test presence.
  has(name: string): boolean {
    return this.modes.has(name);
  }

  // Names of all registered modes, in registration order.
  list(): string[] {
    return [...this.modes.keys()];
  }
}
