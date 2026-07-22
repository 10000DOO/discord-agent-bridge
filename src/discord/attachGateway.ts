import * as http from 'node:http';
import type { AddressInfo } from 'node:net';
import { attachFileConfined, shareDocumentResult, type SendFileCallback, type ShareDocumentCallback } from '../modes/claude/mcpFileTool.js';

// Loopback HTTP gateway so subprocess MCP servers (Grok) can call attach_file /
// share_document without an in-process callback. Tokens map to a per-session
// workspace + sendFile (+ optional shareDocument sink). Never log tokens.

export interface AttachRegistration {
  workspaceRoot: string;
  sendFile: SendFileCallback;
  // Present only when the session also wired a share_document sink (via
  // SessionWiring.shareDocumentFor): lets POST /share post a workspace markdown file
  // into a Discord thread. Absent → POST /share is refused for this token.
  shareDocument?: ShareDocumentCallback;
}

export interface AttachGateway {
  readonly baseUrl: string;
  /** Resolves once the server is listening (port assigned). */
  whenReady(): Promise<void>;
  register(token: string, reg: AttachRegistration): void;
  unregister(token: string): void;
  close(): Promise<void>;
}

interface AttachBody {
  token?: unknown;
  path?: unknown;
  filename?: unknown;
}

// Sync-friendly constructor for createApp(); `baseUrl` is set once listen completes.
// Sessions start after Discord login, so the port is always ready by first use.
export function createAttachGateway(): AttachGateway {
  const registry = new Map<string, AttachRegistration>();
  let baseUrl = '';
  let readyResolve: (() => void) | undefined;
  const ready = new Promise<void>((resolve) => {
    readyResolve = resolve;
  });

  const server = http.createServer((req, res) => {
    void handleRequest(req, res, registry);
  });

  server.listen(0, '127.0.0.1', () => {
    const addr = server.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${addr.port}`;
    readyResolve?.();
  });

  return {
    get baseUrl(): string {
      return baseUrl;
    },
    whenReady(): Promise<void> {
      return ready;
    },
    register(token: string, reg: AttachRegistration): void {
      registry.set(token, reg);
    },
    unregister(token: string): void {
      registry.delete(token);
    },
    close(): Promise<void> {
      return new Promise((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
    },
  };
}

/** Async helper for tests that need a listening gateway with a known baseUrl. */
export async function startAttachGateway(): Promise<AttachGateway> {
  const g = createAttachGateway();
  await g.whenReady();
  return g;
}

async function handleRequest(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  registry: Map<string, AttachRegistration>,
): Promise<void> {
  try {
    if (req.method === 'GET' && (req.url === '/' || req.url === '/health')) {
      json(res, 200, { ok: true });
      return;
    }
    const isShare = req.method === 'POST' && req.url === '/share';
    if (req.method !== 'POST' || (req.url !== '/attach' && !isShare)) {
      json(res, 404, { ok: false, text: 'Not found' });
      return;
    }
    const raw = await readBody(req);
    let body: AttachBody;
    try {
      body = JSON.parse(raw) as AttachBody;
    } catch {
      json(res, 400, { ok: false, text: 'Invalid JSON body' });
      return;
    }
    const token = typeof body.token === 'string' ? body.token : '';
    const requestedPath = typeof body.path === 'string' ? body.path : '';
    const filename = typeof body.filename === 'string' ? body.filename : undefined;
    if (token.length === 0 || requestedPath.length === 0) {
      json(res, 400, { ok: false, text: 'token and path are required' });
      return;
    }
    const reg = registry.get(token);
    if (!reg) {
      json(res, 401, { ok: false, text: 'Unknown or expired attach token' });
      return;
    }
    // Share endpoint: same loopback token/auth as /attach. The bot process reads the file
    // and posts it into a thread via the injected shareDocument callback; the subprocess only
    // relays the confirmation string (PATH-ONLY — never the document body, D2). Reuses the
    // shared shareDocumentResult mapper so the model-facing strings match every other backend.
    if (isShare) {
      if (!reg.shareDocument) {
        json(res, 400, { ok: false, text: 'share_document is not available for this session' });
        return;
      }
      const shareRes = await shareDocumentResult(reg.shareDocument, requestedPath);
      const shareText = shareRes.content.map((c) => c.text).join('\n') || (shareRes.isError ? 'failed' : 'ok');
      json(res, shareRes.isError ? 400 : 200, { ok: !shareRes.isError, text: shareText });
      return;
    }
    const result = await attachFileConfined(reg.workspaceRoot, reg.sendFile, requestedPath, filename);
    const text = result.content.map((c) => c.text).join('\n') || (result.isError ? 'failed' : 'ok');
    json(res, result.isError ? 400 : 200, { ok: !result.isError, text });
  } catch (err) {
    json(res, 500, {
      ok: false,
      text: `Attach gateway error: ${err instanceof Error ? err.message : String(err)}`,
    });
  }
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function json(res: http.ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
  });
  res.end(payload);
}
