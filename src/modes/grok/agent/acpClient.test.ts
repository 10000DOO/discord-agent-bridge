import { describe, it, expect } from 'vitest';
import { EventEmitter } from 'node:events';
import type { Logger } from '../../../core/contracts.js';
import { GrokAcpClient, type AcpSpawnFn, type AcpSpawnedProcess, type AcpPermissionRequest, type AcpUpdate, type GrokAcpClientOptions } from './acpClient.js';

// ---- Test doubles ----------------------------------------------------------------------------

function makeLogger(): Logger {
  return { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} };
}

// Let queued microtasks/immediates run (async permission handler, promise chains).
const flush = (): Promise<void> => new Promise<void>((resolve) => setImmediate(resolve));

// A fake `grok agent stdio` child: capture stdin writes, drive stdout/stderr, script exit.
class FakeAcpChild extends EventEmitter {
  readonly stdout = new EventEmitter();
  readonly stderr = new EventEmitter();
  readonly writes: string[] = [];
  killed: NodeJS.Signals | undefined;

  readonly stdin = {
    write: (chunk: string | Buffer): boolean => {
      this.writes.push(typeof chunk === 'string' ? chunk : chunk.toString('utf8'));
      return true;
    },
  };

  kill(signal?: NodeJS.Signals): boolean {
    this.killed = signal;
    setImmediate(() => this.emit('close', null, signal ?? 'SIGTERM'));
    return true;
  }

  // Push one complete JSON message line onto stdout.
  pushMessage(obj: unknown): void {
    this.stdout.emit('data', Buffer.from(JSON.stringify(obj) + '\n', 'utf8'));
  }

  // Push a raw string fragment (for partial-chunk / malformed-line tests).
  pushRaw(text: string): void {
    this.stdout.emit('data', Buffer.from(text, 'utf8'));
  }

  pushStderr(text: string): void {
    this.stderr.emit('data', Buffer.from(text, 'utf8'));
  }

  // The most recent stdin write, parsed as JSON.
  lastWrite(): Record<string, unknown> {
    return JSON.parse(this.writes[this.writes.length - 1]) as Record<string, unknown>;
  }

  parsedWrites(): Record<string, unknown>[] {
    return this.writes.map((w) => JSON.parse(w) as Record<string, unknown>);
  }
}

function makeClient(opts: Partial<GrokAcpClientOptions> = {}): {
  client: GrokAcpClient;
  child: FakeAcpChild;
  captured: { command?: string; args?: readonly string[]; cwd?: string };
} {
  const child = new FakeAcpChild();
  const captured: { command?: string; args?: readonly string[]; cwd?: string } = {};
  const spawn: AcpSpawnFn = (command, args, options) => {
    captured.command = command;
    captured.args = args;
    captured.cwd = options.cwd;
    return child as unknown as AcpSpawnedProcess;
  };
  const client = new GrokAcpClient({ logger: makeLogger(), spawn, isGrokModel: () => true, ...opts });
  return { client, child, captured };
}

function updateNotification(sessionUpdate: string, extra: Record<string, unknown> = {}): unknown {
  return { jsonrpc: '2.0', method: 'session/update', params: { update: { sessionUpdate, ...extra } } };
}

// ---- spawn argv ------------------------------------------------------------------------------

describe('GrokAcpClient spawn', () => {
  it('places agent-wide options BEFORE the stdio subcommand', () => {
    const { captured } = makeClient({ model: 'grok-4.5', effort: 'high', bypassPermissions: true, isGrokModel: () => true });
    expect(captured.command).toBe('grok');
    expect(captured.args).toEqual(['agent', '-m', 'grok-4.5', '--reasoning-effort', 'high', '--always-approve', 'stdio']);
  });

  it('omits -m when the model is not a grok model, and omits effort/always-approve when unset', () => {
    const { captured } = makeClient({ model: 'opus', isGrokModel: () => false });
    expect(captured.args).toEqual(['agent', 'stdio']);
  });
});

// ---- initialize / session lifecycle ----------------------------------------------------------

describe('GrokAcpClient.initialize', () => {
  it('writes the minimal-capabilities initialize and resolves on the response', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();

    const req = child.lastWrite();
    expect(req.method).toBe('initialize');
    expect(req.params).toEqual({
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
    });

    child.pushMessage({ jsonrpc: '2.0', id: req.id, result: { protocolVersion: 1, agentCapabilities: {} } });
    await expect(p).resolves.toBeUndefined();
    expect(client.initializeResult).toEqual({ protocolVersion: 1, agentCapabilities: {} });
  });
});

describe('GrokAcpClient.sessionNew / sessionLoad', () => {
  it('returns the sessionId from the session/new response and stores it', async () => {
    const { client, child } = makeClient();
    const p = client.sessionNew('/tmp/ws');
    const req = child.lastWrite();
    expect(req.method).toBe('session/new');
    expect(req.params).toEqual({ cwd: '/tmp/ws', mcpServers: [] });

    child.pushMessage({ jsonrpc: '2.0', id: req.id, result: { sessionId: 'sess-42' } });
    await expect(p).resolves.toBe('sess-42');
    expect(client.sessionId).toBe('sess-42');
  });

  it('attaches _meta only when provided', async () => {
    const { client, child } = makeClient();
    const p = client.sessionNew('/ws', { rules: 'be terse', systemPromptOverride: 'X' });
    const req = child.lastWrite();
    expect(req.params).toEqual({ cwd: '/ws', mcpServers: [], _meta: { rules: 'be terse', systemPromptOverride: 'X' } });
    child.pushMessage({ jsonrpc: '2.0', id: req.id, result: { sessionId: 's' } });
    await p;
  });

  it('rejects when session/new returns no sessionId', async () => {
    const { client, child } = makeClient();
    const p = client.sessionNew('/ws');
    child.pushMessage({ jsonrpc: '2.0', id: child.lastWrite().id, result: {} });
    await expect(p).rejects.toThrow(/no sessionId/);
  });

  it('session/load sends the resume params and stores the sessionId', async () => {
    const { client, child } = makeClient();
    const p = client.sessionLoad('sess-9', '/ws');
    const req = child.lastWrite();
    expect(req.method).toBe('session/load');
    expect(req.params).toEqual({ sessionId: 'sess-9', cwd: '/ws', mcpServers: [] });
    child.pushMessage({ jsonrpc: '2.0', id: req.id, result: {} });
    await p;
    expect(client.sessionId).toBe('sess-9');
  });

  it('forwards mcpServers with env as {name,value}[] (Grok wire format, not a string map)', async () => {
    const mcpServers = [
      {
        name: 'discord',
        command: '/usr/bin/node',
        args: ['/tmp/attach.mjs'],
        env: [
          { name: 'DAB_ATTACH_URL', value: 'http://127.0.0.1:9' },
          { name: 'DAB_ATTACH_TOKEN', value: 'tok' },
          { name: 'DAB_WORKSPACE', value: '/ws' },
        ],
      },
    ];
    const { client, child } = makeClient({ mcpServers });
    const p = client.sessionNew('/ws');
    const req = child.lastWrite();
    expect(req.params).toEqual({ cwd: '/ws', mcpServers });
    // env entries must be array objects — a Record map causes grok -32602 Invalid params
    expect(Array.isArray((req.params as { mcpServers: { env: unknown }[] }).mcpServers[0]?.env)).toBe(true);
    child.pushMessage({ jsonrpc: '2.0', id: req.id, result: { sessionId: 's-mcp' } });
    await expect(p).resolves.toBe('s-mcp');
  });
});

// ---- request-id correlation + partial chunks -------------------------------------------------

describe('GrokAcpClient request-id correlation', () => {
  it('resolves two outstanding requests to their correct responses (ids not confused)', async () => {
    const { client, child } = makeClient();
    const pInit = client.initialize();
    const pNew = client.sessionNew('/ws');
    const [initReq, newReq] = child.parsedWrites();
    expect(initReq.method).toBe('initialize');
    expect(newReq.method).toBe('session/new');
    expect(initReq.id).not.toBe(newReq.id);

    // Respond OUT OF ORDER: session/new first, then initialize.
    child.pushMessage({ jsonrpc: '2.0', id: newReq.id, result: { sessionId: 'sid-B' } });
    child.pushMessage({ jsonrpc: '2.0', id: initReq.id, result: { ok: true } });

    await expect(pNew).resolves.toBe('sid-B');
    await expect(pInit).resolves.toBeUndefined();
  });

  it('buffers a response split mid-JSON across two stdout chunks', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    const id = child.lastWrite().id;
    const line = JSON.stringify({ jsonrpc: '2.0', id, result: { protocolVersion: 1 } }) + '\n';
    const mid = Math.floor(line.length / 2);
    child.pushRaw(line.slice(0, mid));
    child.pushRaw(line.slice(mid));
    await expect(p).resolves.toBeUndefined();
  });

  it('skips a malformed / non-JSON stdout line without throwing, and still processes later lines', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    const id = child.lastWrite().id;
    expect(() => child.pushRaw('this is not json at all\n')).not.toThrow();
    expect(() => child.pushRaw('{ broken json\n')).not.toThrow();
    child.pushMessage({ jsonrpc: '2.0', id, result: {} });
    await expect(p).resolves.toBeUndefined();
  });
});

// ---- prompt streaming ------------------------------------------------------------------------

describe('GrokAcpClient.prompt', () => {
  async function startedClient(): Promise<{ client: GrokAcpClient; child: FakeAcpChild }> {
    const { client, child } = makeClient();
    const p = client.sessionNew('/ws');
    child.pushMessage({ jsonrpc: '2.0', id: child.lastWrite().id, result: { sessionId: 's1' } });
    await p;
    return { client, child };
  }

  it('yields each session/update and completes when the session/prompt response arrives', async () => {
    const { client, child } = await startedClient();
    const iter = client.prompt('list files');

    const promptReq = child.lastWrite();
    expect(promptReq.method).toBe('session/prompt');
    expect(promptReq.params).toEqual({ sessionId: 's1', prompt: [{ type: 'text', text: 'list files' }] });

    // Inject updates + the terminating response (buffered by the iterator's queue).
    child.pushMessage(updateNotification('agent_thought_chunk', { content: { type: 'text', text: 'thinking' } }));
    child.pushMessage(updateNotification('agent_message_chunk', { content: { type: 'text', text: 'hello' } }));
    child.pushMessage(updateNotification('tool_call', { toolCallId: 't1', title: 'ls', kind: 'execute' }));
    child.pushMessage({ jsonrpc: '2.0', id: promptReq.id, result: { stopReason: 'end_turn', usage: { total_tokens: 42 } } });

    const updates: AcpUpdate[] = [];
    for await (const u of iter) updates.push(u);

    expect(updates.map((u) => u.sessionUpdate)).toEqual(['agent_thought_chunk', 'agent_message_chunk', 'tool_call']);
    expect((updates[1] as { content?: { text?: string } }).content?.text).toBe('hello');
    expect(client.lastPromptResult).toEqual({ stopReason: 'end_turn', usage: { total_tokens: 42 } });
  });

  it('rejects a second prompt while one is in flight', async () => {
    const { client } = await startedClient();
    client.prompt('one');
    expect(() => client.prompt('two')).toThrow(/already in flight/);
  });

  it('throws when prompting before a session exists', () => {
    const { client } = makeClient();
    expect(() => client.prompt('hi')).toThrow(/No grok session/);
  });

  it('redacts a secret in a session/prompt JSON-RPC error surfaced from the iterator (R10)', async () => {
    const { client, child } = await startedClient();
    const iter = client.prompt('go');
    const promptReq = child.lastWrite();
    child.pushMessage({
      jsonrpc: '2.0',
      id: promptReq.id,
      error: { code: -32000, message: 'auth failed for key xai-ABCDEF0123456789xyz' },
    });

    const seen: AcpUpdate[] = [];
    let caught: Error | null = null;
    try {
      for await (const u of iter) seen.push(u);
    } catch (err) {
      caught = err as Error;
    }
    expect(caught).not.toBeNull();
    expect(caught!.message).toContain('[REDACTED]');
    expect(caught!.message).not.toContain('xai-ABCDEF0123456789xyz');
  });

  it('extracts cost/totalTokens/modelId/tokens from the prompt response _meta (grok 0.2.103)', async () => {
    const { client, child } = await startedClient();
    const iter = client.prompt('go');
    const promptReq = child.lastWrite();
    child.pushMessage(updateNotification('agent_message_chunk', { content: { type: 'text', text: 'DONE' } }));
    // Real grok puts usage/cost under result._meta (NOT a top-level result.usage).
    child.pushMessage({
      jsonrpc: '2.0',
      id: promptReq.id,
      result: {
        stopReason: 'end_turn',
        _meta: {
          totalTokens: 17742,
          modelId: 'grok-4.5',
          usage: { inputTokens: 35010, outputTokens: 136, costUsdTicks: 547336000 },
        },
      },
    });

    const seen: AcpUpdate[] = [];
    for await (const u of iter) seen.push(u);

    expect(client.lastPromptResult).toEqual({
      stopReason: 'end_turn',
      modelId: 'grok-4.5',
      totalTokens: 17742,
      costUsd: 547336000 / 1e10, // 1 USD = 1e10 ticks
      tokensIn: 35010,
      tokensOut: 136,
    });
  });
});

// ---- server→client requests (permission asks) ------------------------------------------------

describe('GrokAcpClient permission requests (Q4 adapter)', () => {
  it('routes a permission ask to onPermissionRequest and writes the outcome with the SAME id', async () => {
    const { client, child } = makeClient();
    let seen: AcpPermissionRequest | null = null;
    client.onPermissionRequest(async (req) => {
      seen = req;
      return { behavior: 'allow' };
    });

    child.pushMessage({
      jsonrpc: '2.0',
      id: 'perm-1',
      method: 'session/request_permission',
      params: {
        sessionId: 's1',
        toolCall: { title: 'write file', kind: 'edit', rawInput: { path: 'a.txt' } },
        options: [
          { optionId: 'allow-once', name: 'Allow', kind: 'allow_once' },
          { optionId: 'reject-once', name: 'Reject', kind: 'reject_once' },
        ],
      },
    });
    await flush();

    expect(seen).not.toBeNull();
    expect(seen!.toolName).toBe('write file');
    expect(seen!.input).toEqual({ path: 'a.txt' });
    expect(seen!.options).toHaveLength(2);

    const resp = child.lastWrite();
    expect(resp.id).toBe('perm-1');
    expect(resp.result).toEqual({ outcome: { outcome: 'selected', optionId: 'allow-once' } });
  });

  it('selects a reject-kind option when the handler denies', async () => {
    const { client, child } = makeClient();
    client.onPermissionRequest(async () => ({ behavior: 'deny' }));
    child.pushMessage({
      jsonrpc: '2.0',
      id: 'perm-2',
      method: 'session/request_permission',
      params: { options: [{ optionId: 'allow-once', kind: 'allow_once' }, { optionId: 'reject-once', kind: 'reject_once' }] },
    });
    await flush();
    expect(child.lastWrite().result).toEqual({ outcome: { outcome: 'selected', optionId: 'reject-once' } });
  });

  it('answers with a safe default (cancelled) when NO permission handler is wired (no hang)', async () => {
    const { child } = makeClient();
    child.pushMessage({ jsonrpc: '2.0', id: 'perm-3', method: 'session/request_permission', params: { options: [] } });
    await flush();
    const resp = child.lastWrite();
    expect(resp.id).toBe('perm-3');
    expect(resp.result).toEqual({ outcome: { outcome: 'cancelled' } });
  });

  it('answers an UNKNOWN server request with a JSON-RPC method-not-found error (agent not left hanging)', async () => {
    const { child } = makeClient();
    child.pushMessage({ jsonrpc: '2.0', id: 'req-9', method: 'x.ai/fs/read_file', params: { path: 'a' } });
    await flush();
    const resp = child.lastWrite();
    expect(resp.id).toBe('req-9');
    expect(resp.error).toMatchObject({ code: -32601 });
  });
});

// ---- unexpected exit / close -----------------------------------------------------------------

describe('GrokAcpClient lifecycle failures', () => {
  it('rejects an in-flight request when the child exits unexpectedly (no hang)', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    child.emit('close', 1, null);
    await expect(p).rejects.toThrow(/exited unexpectedly/);
  });

  it('ends an in-flight prompt stream with an error on unexpected exit, after surfacing buffered updates', async () => {
    const { client, child } = makeClient();
    const pNew = client.sessionNew('/ws');
    child.pushMessage({ jsonrpc: '2.0', id: child.lastWrite().id, result: { sessionId: 's1' } });
    await pNew;

    const iter = client.prompt('go');
    child.pushMessage(updateNotification('agent_message_chunk', { content: { type: 'text', text: 'partial' } }));
    child.emit('close', 1, null);

    const seen: AcpUpdate[] = [];
    await expect(
      (async () => {
        for await (const u of iter) seen.push(u);
      })(),
    ).rejects.toThrow(/exited unexpectedly/);
    expect(seen.map((u) => u.sessionUpdate)).toEqual(['agent_message_chunk']);
  });

  it('surfaces a `grok login` hint when the child dies with an auth failure on stderr', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    child.pushStderr('Error: not authenticated. Run `grok login`.\n');
    child.emit('close', 1, null);
    await expect(p).rejects.toThrow(/grok login/);
  });

  it('redacts a secret in the stderr tail of the generic exit error (R10)', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    child.pushStderr('request failed with key xai-abcdef0123456789ABCDEF\n');
    child.emit('close', 3, null);
    await expect(p).rejects.toThrow(/\[REDACTED\]/);
    await p.catch((err: Error) => {
      expect(err.message).not.toContain('xai-abcdef0123456789ABCDEF');
    });
  });

  it('close() kills the child (SIGTERM) and rejects pending requests', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    await client.close();
    expect(child.killed).toBe('SIGTERM');
    await expect(p).rejects.toThrow(/closed/);
  });

  it('a pre-aborted signal closes the client on the next tick', async () => {
    const controller = new AbortController();
    controller.abort();
    const { child } = makeClient({ signal: controller.signal });
    await flush();
    expect(child.killed).toBe('SIGTERM');
  });
});
