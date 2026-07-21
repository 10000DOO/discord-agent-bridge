#!/usr/bin/env node
// Minimal stdio MCP server: tools/list + tools/call for attach_file.
// Spawns by Grok (and optionally other subprocess backends). Talks to the bridge
// AttachGateway over loopback HTTP. Node builtins only — no SDK.
//
// Env (set by the bridge when spawning):
//   DAB_ATTACH_URL   — gateway base URL, e.g. http://127.0.0.1:PORT
//   DAB_ATTACH_TOKEN — per-session token (never log)
//   DAB_WORKSPACE    — workspace root (informational; confinement is on the gateway)

import * as readline from 'node:readline';

const ATTACH_URL = process.env.DAB_ATTACH_URL ?? '';
const ATTACH_TOKEN = process.env.DAB_ATTACH_TOKEN ?? '';

const TOOLS = [
  {
    name: 'attach_file',
    description:
      'Send a file from the workspace to the Discord channel for this session. Path must be inside the workspace. Create the file first if needed.',
    inputSchema: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Workspace-relative or absolute path inside workspace',
        },
        filename: {
          type: 'string',
          description: 'Optional display name',
        },
      },
      required: ['path'],
    },
  },
];

function write(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function respond(id, result) {
  write({ jsonrpc: '2.0', id, result });
}

function respondError(id, code, message) {
  write({ jsonrpc: '2.0', id, error: { code, message } });
}

async function postAttach(path, filename) {
  if (!ATTACH_URL || !ATTACH_TOKEN) {
    return { ok: false, text: 'Attach gateway is not configured (missing DAB_ATTACH_URL/TOKEN).' };
  }
  const url = ATTACH_URL.replace(/\/$/, '') + '/attach';
  const body = { token: ATTACH_TOKEN, path };
  if (filename !== undefined && filename !== null && String(filename).length > 0) {
    body.filename = String(filename);
  }
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  let data;
  try {
    data = await res.json();
  } catch {
    return { ok: false, text: `Attach gateway returned non-JSON (HTTP ${res.status}).` };
  }
  const text = typeof data?.text === 'string' ? data.text : res.ok ? 'ok' : 'failed';
  return { ok: data?.ok === true || (res.ok && data?.ok !== false), text };
}

async function handleRequest(msg) {
  const { id, method, params } = msg;
  if (method === 'initialize') {
    respond(id, {
      protocolVersion: params?.protocolVersion ?? '2024-11-05',
      capabilities: { tools: {} },
      serverInfo: { name: 'discord', version: '1.0.0' },
    });
    return;
  }
  if (method === 'notifications/initialized' || method === 'initialized') {
    // notification — no response
    return;
  }
  if (method === 'ping') {
    respond(id, {});
    return;
  }
  if (method === 'tools/list') {
    respond(id, { tools: TOOLS });
    return;
  }
  if (method === 'tools/call') {
    const name = params?.name;
    const args = params?.arguments ?? {};
    if (name !== 'attach_file') {
      respond(id, {
        content: [{ type: 'text', text: `Unknown tool: ${name}` }],
        isError: true,
      });
      return;
    }
    const path = typeof args.path === 'string' ? args.path : '';
    if (!path) {
      respond(id, {
        content: [{ type: 'text', text: 'attach_file requires a path.' }],
        isError: true,
      });
      return;
    }
    try {
      const result = await postAttach(path, args.filename);
      respond(id, {
        content: [{ type: 'text', text: result.text }],
        isError: !result.ok,
      });
    } catch (err) {
      respond(id, {
        content: [
          {
            type: 'text',
            text: `Failed to attach file: ${err instanceof Error ? err.message : String(err)}`,
          },
        ],
        isError: true,
      });
    }
    return;
  }
  if (id !== undefined && id !== null) {
    respondError(id, -32601, `Method not found: ${method}`);
  }
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch {
    return;
  }
  if (!msg || typeof msg !== 'object') return;
  // Notifications have no id — handle without response when appropriate.
  void handleRequest(msg).catch(() => {
    // swallow — never crash the MCP child on a single bad message
  });
});
