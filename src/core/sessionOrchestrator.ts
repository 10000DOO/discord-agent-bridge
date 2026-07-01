import type { ModeSession, PermMode, TurnInput } from './contracts.js';

// TODO(Phase 1): turn lifecycle, per-channel queue, resume-on-boot, /stop kill switch (§7.5, §9).
export class SessionOrchestrator {
  start(_guildId: string, _channelId: string, _mode: string, _cwd: string, _ownerId: string, _permMode: PermMode, _profile: string | null): Promise<ModeSession> {
    throw new Error('not implemented');
  }

  enqueueTurn(_guildId: string, _channelId: string, _turn: TurnInput): Promise<void> {
    throw new Error('not implemented');
  }

  resumeAll(): Promise<void> {
    throw new Error('not implemented');
  }

  stop(_guildId: string, _channelId: string): Promise<void> {
    throw new Error('not implemented');
  }

  stopAll(): Promise<void> {
    throw new Error('not implemented');
  }
}
