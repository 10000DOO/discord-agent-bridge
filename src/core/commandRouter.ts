// TODO(Phase 1): slash + `!`-prefixed message command parsing/dispatch, incl. /mode /stop (§4, §9).
export interface ParsedCommand {
  name: string;
  args: string[];
  raw: string;
}

export class CommandRouter {
  parse(_raw: string): ParsedCommand | null {
    throw new Error('not implemented');
  }

  dispatch(_command: ParsedCommand): Promise<void> {
    throw new Error('not implemented');
  }
}
