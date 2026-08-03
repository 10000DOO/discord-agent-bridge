import { describe, it, expect } from 'vitest';
import type { ModeContext, ModeSession } from '../../core/contracts.js';
import type { ClaudeSessionDeps } from '../../modes/claude/session.js';
import { SessionBridge } from './sessionBridge.js';

describe('SessionBridge buildContext', () => {
  it('passes projectRagEnabled through to ModeContext when set', async () => {
    const captured: ModeContext[] = [];
    const createSession = (ctx: ModeContext, _deps: ClaudeSessionDeps): ModeSession => {
      captured.push(ctx);
      return {
        sessionId: null,
        async send() {},
        async stop() {},
      };
    };
    const bridge = new SessionBridge({ write: () => {}, createSession });

    await bridge.start({
      cwd: '/tmp/ws',
      guildId: 'g1',
      channelId: 'c1',
      permMode: 'default',
      projectRagEnabled: true,
    });

    expect(captured[0]!.projectRagEnabled).toBe(true);
  });

  it('omits projectRagEnabled from ModeContext when not set', async () => {
    const captured: ModeContext[] = [];
    const createSession = (ctx: ModeContext, _deps: ClaudeSessionDeps): ModeSession => {
      captured.push(ctx);
      return {
        sessionId: null,
        async send() {},
        async stop() {},
      };
    };
    const bridge = new SessionBridge({ write: () => {}, createSession });

    await bridge.start({
      cwd: '/tmp/ws',
      guildId: 'g1',
      channelId: 'c1',
      permMode: 'default',
    });

    expect(captured[0]!.projectRagEnabled).toBeUndefined();
  });
});
