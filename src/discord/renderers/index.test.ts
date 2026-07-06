import { describe, it, expect, vi } from 'vitest';
import { RendererDispatcher, type RendererSet } from './index.js';
import type { AgentEvent, Capabilities } from '../../core/contracts.js';

// A spy renderer set: every action is a vi.fn() so a test asserts exactly which
// renderer fired for a given event × capability combination.
function spySet(): RendererSet {
  return {
    stream: vi.fn(),
    plainText: vi.fn(),
    toolThread: vi.fn(),
    diff: vi.fn(),
    permission: vi.fn(),
    transcript: vi.fn(),
    result: vi.fn(),
    usage: vi.fn(),
    mention: vi.fn(),
    error: vi.fn(),
    rateLimit: vi.fn(),
  };
}

const claudeCaps: Capabilities = {
  streaming: true,
  thinking: true,
  toolThreads: true,
  permissionPrompts: true,
  progress: false,
  transcript: false,
  sessionResume: true,
  fileAttach: true,
  fileDiff: true,
  usagePanel: true,
  permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
};

const codexCaps: Capabilities = {
  streaming: false,
  thinking: false,
  toolThreads: false,
  permissionPrompts: false,
  progress: true,
  transcript: true,
  sessionResume: true,
  fileAttach: false,
  fileDiff: false,
  usagePanel: false,
  permissionModes: ['default', 'acceptEdits', 'bypassPermissions', 'plan'],
};

const toolUse: AgentEvent = { kind: 'tool_use', id: 't1', name: 'Edit', input: { file_path: '/ws/a' } };
const permReq: AgentEvent = { kind: 'permission_request', id: 'p1', toolName: 'Bash', input: {} };
const textEv: AgentEvent = { kind: 'text', text: 'hello', delta: true };
const progressEv: AgentEvent = { kind: 'progress', label: 'editing' };
const ctxUsage: AgentEvent = { kind: 'context_usage', totalTokens: 10, maxTokens: 100, percentage: 10 };

describe('RendererDispatcher capability dispatch', () => {
  it('fires toolThread for tool_use only when toolThreads is set', () => {
    const set = spySet();
    new RendererDispatcher(set, claudeCaps).dispatch(toolUse);
    expect(set.toolThread).toHaveBeenCalledWith(toolUse);

    const set2 = spySet();
    new RendererDispatcher(set2, codexCaps).dispatch(toolUse);
    expect(set2.toolThread).not.toHaveBeenCalled();
  });

  it('fires the diff renderer for tool_use only when fileDiff is set', () => {
    const set = spySet();
    new RendererDispatcher(set, claudeCaps).dispatch(toolUse);
    expect(set.diff).toHaveBeenCalledWith(toolUse);

    const set2 = spySet();
    new RendererDispatcher(set2, codexCaps).dispatch(toolUse);
    expect(set2.diff).not.toHaveBeenCalled();
  });

  it('fires permission buttons for permission_request only when permissionPrompts is set', () => {
    const set = spySet();
    new RendererDispatcher(set, claudeCaps).dispatch(permReq);
    expect(set.permission).toHaveBeenCalledWith(permReq);

    const set2 = spySet();
    new RendererDispatcher(set2, codexCaps).dispatch(permReq);
    expect(set2.permission).not.toHaveBeenCalled();
  });

  it('routes text to the stream embed when streaming is set', () => {
    const set = spySet();
    new RendererDispatcher(set, claudeCaps).dispatch(textEv);
    expect(set.stream).toHaveBeenCalledWith(textEv);
    expect(set.plainText).not.toHaveBeenCalled();
  });

  it('routes text to a plain message when streaming is NOT set (Codex-like)', () => {
    const set = spySet();
    new RendererDispatcher(set, codexCaps).dispatch(textEv);
    expect(set.plainText).toHaveBeenCalledWith(textEv);
    expect(set.stream).not.toHaveBeenCalled();
  });

  it('routes progress to the transcript feed for a transcript/progress backend', () => {
    const set = spySet();
    new RendererDispatcher(set, codexCaps).dispatch(progressEv);
    expect(set.transcript).toHaveBeenCalledWith(progressEv);

    // Claude (no progress/transcript) skips it.
    const set2 = spySet();
    new RendererDispatcher(set2, claudeCaps).dispatch(progressEv);
    expect(set2.transcript).not.toHaveBeenCalled();
  });

  it('fires the usage panel for context_usage only when usagePanel is set', () => {
    const set = spySet();
    new RendererDispatcher(set, claudeCaps).dispatch(ctxUsage);
    expect(set.usage).toHaveBeenCalledWith(ctxUsage);

    const set2 = spySet();
    new RendererDispatcher(set2, codexCaps).dispatch(ctxUsage);
    expect(set2.usage).not.toHaveBeenCalled();
  });

  it('always fires result + mention on result; Codex additionally feeds final text to transcript', () => {
    const resultEv: AgentEvent = { kind: 'result', text: 'final', costUsd: 0.01 };
    const claude = spySet();
    new RendererDispatcher(claude, claudeCaps).dispatch(resultEv);
    expect(claude.result).toHaveBeenCalledWith(resultEv);
    expect(claude.mention).toHaveBeenCalledWith(resultEv);
    expect(claude.transcript).not.toHaveBeenCalled();

    const codex = spySet();
    new RendererDispatcher(codex, codexCaps).dispatch(resultEv);
    expect(codex.result).toHaveBeenCalledWith(resultEv);
    expect(codex.mention).toHaveBeenCalledWith(resultEv);
    expect(codex.transcript).toHaveBeenCalledWith(resultEv);
  });

  it('always surfaces errors regardless of capabilities', () => {
    const errEv: AgentEvent = { kind: 'error', message: 'boom', retryable: false };
    const set = spySet();
    new RendererDispatcher(set, codexCaps).dispatch(errEv);
    expect(set.error).toHaveBeenCalledWith(errEv);
  });

  it('always surfaces rate_limit updates regardless of capabilities and never as an error', () => {
    const rlEv: AgentEvent = { kind: 'rate_limit', utilization: 87, rateLimitType: 'five_hour' };
    const set = spySet();
    new RendererDispatcher(set, codexCaps).dispatch(rlEv);
    expect(set.rateLimit).toHaveBeenCalledWith(rlEv);
    expect(set.error).not.toHaveBeenCalled();

    const set2 = spySet();
    new RendererDispatcher(set2, claudeCaps).dispatch(rlEv);
    expect(set2.rateLimit).toHaveBeenCalledWith(rlEv);
    expect(set2.error).not.toHaveBeenCalled();
  });
});
