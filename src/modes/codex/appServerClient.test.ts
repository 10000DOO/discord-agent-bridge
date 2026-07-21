import { describe, it, expect } from 'vitest';
import { EventEmitter } from 'node:events';
import type { Logger } from '../../core/contracts.js';
import {
  CodexAppServerClient,
  type AppServerSpawnFn,
  type AppServerSpawnedProcess,
  type CodexAppServerClientOptions,
} from './appServerClient.js';

function makeLogger(): Logger {
  return { debug: () => {}, info: () => {}, warn: () => {}, error: () => {} };
}

const flush = (): Promise<void> => new Promise<void>((resolve) => setImmediate(resolve));

class FakeChild extends EventEmitter {
  readonly stdout = new EventEmitter();
  readonly stderr = new EventEmitter();
  readonly writes: string[] = [];
  killed: NodeJS.Signals | undefined;

  readonly stdin = {
    write: (chunk: string | Buffer): boolean => {
      this.writes.push(typeof chunk === 'string' ? chunk : chunk.toString('utf8'));
      return true;
    },
    end: (): void => {},
  };

  kill(signal?: NodeJS.Signals): boolean {
    this.killed = signal;
    setImmediate(() => this.emit('close', null, signal ?? 'SIGTERM'));
    return true;
  }

  pushMessage(obj: unknown): void {
    this.stdout.emit('data', Buffer.from(JSON.stringify(obj) + '\n', 'utf8'));
  }

  pushRaw(text: string): void {
    this.stdout.emit('data', Buffer.from(text, 'utf8'));
  }

  lastWrite(): Record<string, unknown> {
    return JSON.parse(this.writes[this.writes.length - 1]) as Record<string, unknown>;
  }

  parsedWrites(): Record<string, unknown>[] {
    return this.writes.map((w) => JSON.parse(w) as Record<string, unknown>);
  }
}

function makeClient(opts: Partial<CodexAppServerClientOptions> = {}): {
  client: CodexAppServerClient;
  child: FakeChild;
  captured: { command?: string; args?: readonly string[]; env?: NodeJS.ProcessEnv };
} {
  const child = new FakeChild();
  const captured: { command?: string; args?: readonly string[]; env?: NodeJS.ProcessEnv } = {};
  const spawn: AppServerSpawnFn = (command, args, options) => {
    captured.command = command;
    captured.args = args;
    captured.env = options.env;
    return child as unknown as AppServerSpawnedProcess;
  };
  const client = new CodexAppServerClient({ logger: makeLogger(), spawn, ...opts });
  return { client, child, captured };
}

describe('CodexAppServerClient spawn', () => {
  it('spawns codex app-server with CODEX_HOME when set', () => {
    const { captured } = makeClient({ codexHome: '/tmp/codex-home', codexCommand: 'codex' });
    expect(captured.command).toBe('codex');
    expect(captured.args).toEqual(['app-server']);
    expect(captured.env?.CODEX_HOME).toBe('/tmp/codex-home');
  });
});

describe('CodexAppServerClient.initialize', () => {
  it('writes initialize and resolves when the response omits jsonrpc (spike wire)', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    const req = child.lastWrite();
    expect(req.method).toBe('initialize');
    expect(req.jsonrpc).toBe('2.0');
    expect((req.params as { capabilities?: { experimentalApi?: boolean } }).capabilities?.experimentalApi).toBe(true);

    // Spike: responses omit jsonrpc
    child.pushMessage({ id: req.id, result: { userAgent: 'codex', platformOs: 'macos' } });
    await expect(p).resolves.toEqual({ userAgent: 'codex', platformOs: 'macos' });
    expect(client.initializeResult).toEqual({ userAgent: 'codex', platformOs: 'macos' });
  });
});

describe('CodexAppServerClient thread/turn', () => {
  it('threadStart returns result.thread.id', async () => {
    const { client, child } = makeClient();
    const p = client.threadStart({
      cwd: '/ws',
      approvalPolicy: 'never',
      sandbox: 'read-only',
    });
    const req = child.lastWrite();
    expect(req.method).toBe('thread/start');
    child.pushMessage({ id: req.id, result: { thread: { id: 'thread-uuid-1' } } });
    await expect(p).resolves.toBe('thread-uuid-1');
  });

  it('threadResume sends threadId', async () => {
    const { client, child } = makeClient();
    const p = client.threadResume({ threadId: 't-resume' });
    const req = child.lastWrite();
    expect(req.method).toBe('thread/resume');
    expect(req.params).toEqual({ threadId: 't-resume' });
    child.pushMessage({ id: req.id, result: {} });
    await p;
  });

  it('turnStart returns result.turn.id', async () => {
    const { client, child } = makeClient();
    const p = client.turnStart({
      threadId: 't1',
      input: [{ type: 'text', text: 'hi' }],
    });
    const req = child.lastWrite();
    expect(req.method).toBe('turn/start');
    child.pushMessage({ id: req.id, result: { turn: { id: 'turn-9', status: 'inProgress' } } });
    await expect(p).resolves.toBe('turn-9');
  });

  it('turnInterrupt sends threadId + turnId', async () => {
    const { client, child } = makeClient();
    const p = client.turnInterrupt({ threadId: 't1', turnId: 'turn-1' });
    const req = child.lastWrite();
    expect(req.method).toBe('turn/interrupt');
    expect(req.params).toEqual({ threadId: 't1', turnId: 'turn-1' });
    child.pushMessage({ id: req.id, result: {} });
    await p;
  });
});

describe('CodexAppServerClient notifications', () => {
  it('dispatches notifications without id to all listeners', async () => {
    const { client, child } = makeClient();
    const seen: Array<{ method: string; params: unknown }> = [];
    client.onNotification((method, params) => seen.push({ method, params }));

    child.pushMessage({
      method: 'item/agentMessage/delta',
      params: { threadId: 't', turnId: 'u', delta: 'Hello' },
    });
    await flush();
    expect(seen).toEqual([
      { method: 'item/agentMessage/delta', params: { threadId: 't', turnId: 'u', delta: 'Hello' } },
    ]);
  });

  it('buffers a response split across two stdout chunks', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    const id = child.lastWrite().id;
    const line = JSON.stringify({ id, result: { ok: true } }) + '\n';
    const mid = Math.floor(line.length / 2);
    child.pushRaw(line.slice(0, mid));
    child.pushRaw(line.slice(mid));
    await expect(p).resolves.toEqual({ ok: true });
  });

  it('skips non-JSON lines without throwing', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    const id = child.lastWrite().id;
    expect(() => child.pushRaw('not json\n')).not.toThrow();
    child.pushMessage({ id, result: {} });
    await expect(p).resolves.toEqual({});
  });
});

describe('CodexAppServerClient approvals', () => {
  it('auto-accepts approval requests when no handler is set', async () => {
    const { child } = makeClient();
    child.pushMessage({
      id: 99,
      method: 'item/commandExecution/requestApproval',
      params: { command: 'ls' },
    });
    await flush();
    await flush();
    const resp = child.parsedWrites().find((w) => w.id === 99);
    expect(resp).toEqual({ id: 99, result: { decision: 'accept' } });
  });

  it('forwards approval to onApproval and maps the decision', async () => {
    const { child } = makeClient({
      onApproval: async () => 'decline',
    });
    child.pushMessage({
      id: 7,
      method: 'item/fileChange/requestApproval',
      params: { path: 'a.ts' },
    });
    await flush();
    await flush();
    const resp = child.parsedWrites().find((w) => w.id === 7);
    expect(resp).toEqual({ id: 7, result: { decision: 'decline' } });
  });

  it('routes item/tool/call to onDynamicToolCall and responds with contentItems', async () => {
    const { child } = makeClient({
      onDynamicToolCall: async (params) => {
        expect(params.tool).toBe('attach_file');
        expect(params.callId).toBe('call-1');
        return {
          success: true,
          contentItems: [{ type: 'inputText', text: 'attached ok' }],
        };
      },
    });
    child.pushMessage({
      id: 42,
      method: 'item/tool/call',
      params: {
        tool: 'attach_file',
        arguments: { path: 'out.txt' },
        callId: 'call-1',
        threadId: 't1',
        turnId: 'u1',
      },
    });
    await flush();
    await flush();
    const resp = child.parsedWrites().find((w) => w.id === 42);
    expect(resp).toEqual({
      id: 42,
      result: {
        success: true,
        contentItems: [{ type: 'inputText', text: 'attached ok' }],
      },
    });
  });

  it('responds -32601 for unknown server requests', async () => {
    const { child } = makeClient();
    child.pushMessage({ id: 11, method: 'future/unknown', params: {} });
    await flush();
    await flush();
    const resp = child.parsedWrites().find((w) => w.id === 11);
    expect(resp).toMatchObject({
      id: 11,
      error: { code: -32601 },
    });
  });
});

describe('CodexAppServerClient.close', () => {
  it('kills the child and rejects in-flight requests', async () => {
    const { client, child } = makeClient();
    const p = client.initialize();
    await client.close();
    expect(child.killed).toBe('SIGTERM');
    await expect(p).rejects.toThrow(/closed/);
  });
});
