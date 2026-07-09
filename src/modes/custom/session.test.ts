import { describe, it, expect } from 'vitest';
import type { ModeContext } from '../../core/contracts.js';
import type { QueryFn } from '../claude/session.js';
import { CustomEnvSession } from './session.js';

const nullLogger = { debug() {}, info() {}, warn() {}, error() {} };

function makeCtx(overrides: Partial<ModeContext> = {}): ModeContext {
  return {
    guildId: 'g1',
    channelId: 'c1',
    cwd: '/tmp/ws',
    ownerId: 'u1',
    permMode: 'default',
    emit: () => {},
    requestPermission: async () => ({ behavior: 'deny' }),
    config: {},
    logger: nullLogger,
    audit: () => {},
    ...overrides,
  };
}

describe('CustomEnvSession', () => {
  it('is a ClaudeSession that accepts an env override', async () => {
    let capturedOptions: unknown;
    const fakeQuery: QueryFn = ({ options }) => {
      capturedOptions = options;
      return {
        async *[Symbol.asyncIterator]() {},
        close() {},
        async getContextUsage() {
          return { totalTokens: 0, maxTokens: 0, percentage: 0 };
        },
      } as unknown as ReturnType<QueryFn>;
    };

    const session = new CustomEnvSession(makeCtx(), {
      queryFn: fakeQuery,
      env: { ANTHROPIC_BASE_URL: 'https://api.example.com', ANTHROPIC_MODEL: 'custom-model' },
    });

    const options = capturedOptions as { env?: Record<string, string> };
    expect(options.env).toBeDefined();
    expect(options.env?.ANTHROPIC_BASE_URL).toBe('https://api.example.com');
    expect(options.env?.ANTHROPIC_MODEL).toBe('custom-model');

    await session.stop();
  });
});
