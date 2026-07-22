import { describe, it, expect, afterEach } from 'vitest';
import * as fs from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import { startAttachGateway, type AttachGateway } from './attachGateway.js';

describe('AttachGateway', () => {
  let gateway: AttachGateway | undefined;

  afterEach(async () => {
    if (gateway) {
      await gateway.close();
      gateway = undefined;
    }
  });

  it('attaches a confined file via POST /attach', async () => {
    gateway = await startAttachGateway();
    expect(gateway.baseUrl).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/);

    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'dab-ag-'));
    const filePath = path.join(dir, 'hello.txt');
    await fs.writeFile(filePath, 'hi', 'utf8');

    const sent: string[] = [];
    gateway.register('tok-1', {
      workspaceRoot: dir,
      sendFile: async (abs) => {
        sent.push(abs);
        return `uploaded ${path.basename(abs)}`;
      },
    });

    const res = await fetch(`${gateway.baseUrl}/attach`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'tok-1', path: 'hello.txt' }),
    });
    const body = (await res.json()) as { ok: boolean; text: string };
    expect(res.status).toBe(200);
    expect(body.ok).toBe(true);
    expect(body.text).toContain('uploaded');
    expect(sent).toHaveLength(1);
  });

  it('rejects unknown tokens and path escapes', async () => {
    gateway = await startAttachGateway();
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'dab-ag-'));
    gateway.register('tok-2', {
      workspaceRoot: dir,
      sendFile: async () => 'ok',
    });

    const badToken = await fetch(`${gateway.baseUrl}/attach`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'nope', path: 'x' }),
    });
    expect(badToken.status).toBe(401);

    const escape = await fetch(`${gateway.baseUrl}/attach`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'tok-2', path: '../outside.txt' }),
    });
    const escapeBody = (await escape.json()) as { ok: boolean; text: string };
    expect(escapeBody.ok).toBe(false);
    expect(escapeBody.text).toMatch(/outside|Refused/i);
  });

  it('unregister removes the token', async () => {
    gateway = await startAttachGateway();
    gateway.register('tok-3', {
      workspaceRoot: os.tmpdir(),
      sendFile: async () => 'ok',
    });
    gateway.unregister('tok-3');
    const res = await fetch(`${gateway.baseUrl}/attach`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'tok-3', path: 'a' }),
    });
    expect(res.status).toBe(401);
  });

  it('shares a document via POST /share (path-only, confirmation only)', async () => {
    gateway = await startAttachGateway();

    const shared: string[] = [];
    gateway.register('tok-4', {
      workspaceRoot: os.tmpdir(),
      sendFile: async () => 'ok',
      shareDocument: async (p) => {
        shared.push(p);
        return { ok: true, threadName: '📄 notes.md', path: p };
      },
    });

    const res = await fetch(`${gateway.baseUrl}/share`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'tok-4', path: 'notes.md' }),
    });
    const body = (await res.json()) as { ok: boolean; text: string };
    expect(res.status).toBe(200);
    expect(body.ok).toBe(true);
    // Confirmation string only — the document body is never returned over the wire (D2).
    expect(body.text).toContain('Shared');
    expect(body.text).toContain('📄 notes.md');
    expect(shared).toEqual(['notes.md']);
  });

  it('maps a coded share rejection to an error confirmation', async () => {
    gateway = await startAttachGateway();
    gateway.register('tok-5', {
      workspaceRoot: os.tmpdir(),
      sendFile: async () => 'ok',
      shareDocument: async () => ({ ok: false, code: 'notFound' }),
    });

    const res = await fetch(`${gateway.baseUrl}/share`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'tok-5', path: 'missing.md' }),
    });
    const body = (await res.json()) as { ok: boolean; text: string };
    expect(res.status).toBe(400);
    expect(body.ok).toBe(false);
    expect(body.text).toContain('file not found');
  });

  it('refuses /share when the session has no shareDocument sink', async () => {
    gateway = await startAttachGateway();
    gateway.register('tok-6', {
      workspaceRoot: os.tmpdir(),
      sendFile: async () => 'ok',
    });

    const res = await fetch(`${gateway.baseUrl}/share`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'tok-6', path: 'x.md' }),
    });
    const body = (await res.json()) as { ok: boolean; text: string };
    expect(res.status).toBe(400);
    expect(body.ok).toBe(false);
    expect(body.text).toMatch(/not available/i);
  });

  it('rejects unknown tokens on /share too', async () => {
    gateway = await startAttachGateway();
    const res = await fetch(`${gateway.baseUrl}/share`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: 'nope', path: 'x.md' }),
    });
    expect(res.status).toBe(401);
  });
});
