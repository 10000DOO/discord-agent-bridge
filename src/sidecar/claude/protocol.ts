// Claude sidecar protocol v1 (see CLAUDE_SIDECAR_PROTOCOL.md).
// NDJSON envelopes over stdio — one JSON object per line, no pretty-print.

import type { AgentEvent } from '../../core/contracts.js';

export const PROTOCOL_VERSION = 1 as const;

export type EnvelopeType = 'req' | 'res' | 'event' | 'notify';

export type ErrorCode =
  | 'invalid_request'
  | 'unknown_session'
  | 'unsupported'
  | 'sdk_error'
  | 'permission_timeout'
  | 'internal';

export interface SidecarError {
  code: ErrorCode | string;
  message: string;
  retryable: boolean;
}

// Common envelope. Field names are fixed by the protocol document.
export interface Envelope {
  v: typeof PROTOCOL_VERSION | number;
  id?: string;
  type: EnvelopeType;
  method?: string;
  session?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: SidecarError;
  event?: AgentEvent;
}

// ---- Method param/result shapes (v1) ----------------------------------------

export interface SessionStartParams {
  cwd: string;
  guildId: string;
  channelId: string;
  ownerId?: string;
  model?: string;
  effort?: string;
  permMode: string;
  config?: {
    allowedTools?: string[];
    autoAllowClaudeTools?: string[];
    permissionTimeoutSec?: number;
  };
  env?: Record<string, string | undefined>;
}

export interface SessionResumeParams extends SessionStartParams {
  backendSessionId: string;
}

export interface SessionSendParams {
  session?: string;
  text: string;
  files?: { path: string; mime?: string }[];
}

export interface SessionPermissionParams {
  session?: string;
  requestId: string;
  behavior: 'allow' | 'deny';
  message?: string;
}

export interface SessionHandleParams {
  session?: string;
}

export interface SessionSetModelParams {
  session?: string;
  model?: string;
}

export interface SessionSetEffortParams {
  session?: string;
  effort?: string;
}

export interface SessionsListParams {
  cwd: string;
  limit?: number;
}

export interface SessionStartResult {
  session: string;
  backendSessionId: string | null;
}

export interface SessionsListResult {
  sessions: Array<{
    sessionId: string;
    cwd: string;
    label?: string;
    updatedAt?: string;
  }>;
}

// ---- Parse / serialize ------------------------------------------------------

export class ProtocolParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ProtocolParseError';
  }
}

/** Parse one NDJSON line into an Envelope. Throws ProtocolParseError on bad input. */
export function parseEnvelope(line: string): Envelope {
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    throw new ProtocolParseError('empty line');
  }
  let raw: unknown;
  try {
    raw = JSON.parse(trimmed);
  } catch {
    throw new ProtocolParseError('invalid JSON');
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new ProtocolParseError('envelope must be a JSON object');
  }
  const obj = raw as Record<string, unknown>;
  if (obj.v !== PROTOCOL_VERSION && obj.v !== 1) {
    throw new ProtocolParseError(`unsupported protocol version: ${String(obj.v)}`);
  }
  if (
    obj.type !== 'req' &&
    obj.type !== 'res' &&
    obj.type !== 'event' &&
    obj.type !== 'notify'
  ) {
    throw new ProtocolParseError(`invalid envelope type: ${String(obj.type)}`);
  }
  return obj as unknown as Envelope;
}

/** Serialize an Envelope to a single NDJSON line (no trailing newline). */
export function serializeEnvelope(env: Envelope): string {
  return JSON.stringify(env);
}

// ---- Builders ---------------------------------------------------------------

export function req(
  id: string,
  method: string,
  params?: Record<string, unknown>,
  session?: string,
): Envelope {
  return {
    v: PROTOCOL_VERSION,
    type: 'req',
    id,
    method,
    ...(session !== undefined ? { session } : {}),
    ...(params !== undefined ? { params } : {}),
  };
}

export function res(
  id: string,
  method: string,
  result: unknown,
  session?: string,
): Envelope {
  return {
    v: PROTOCOL_VERSION,
    type: 'res',
    id,
    method,
    ...(session !== undefined ? { session } : {}),
    result,
  };
}

export function resError(
  id: string,
  method: string,
  error: SidecarError,
  session?: string,
): Envelope {
  return {
    v: PROTOCOL_VERSION,
    type: 'res',
    id,
    method,
    ...(session !== undefined ? { session } : {}),
    error,
  };
}

export function event(session: string, agentEvent: AgentEvent): Envelope {
  return {
    v: PROTOCOL_VERSION,
    type: 'event',
    session,
    event: agentEvent,
  };
}

export function notify(
  method: string,
  params?: Record<string, unknown>,
  session?: string,
): Envelope {
  return {
    v: PROTOCOL_VERSION,
    type: 'notify',
    method,
    ...(session !== undefined ? { session } : {}),
    ...(params !== undefined ? { params } : {}),
  };
}

export function makeError(
  code: ErrorCode | string,
  message: string,
  retryable = false,
): SidecarError {
  return { code, message, retryable };
}
