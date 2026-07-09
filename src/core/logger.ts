import type { Logger } from './contracts.js';

// Redacting logger (§7.3, A7). Levels are gated by config logLevel; secrets are
// NEVER logged: Discord bot tokens, OAuth access/refresh tokens, and Authorization
// headers are redacted, and raw event payloads are not dumped at info level.

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LEVEL_ORDER: Record<LogLevel, number> = { debug: 10, info: 20, warn: 30, error: 40 };

const PLACEHOLDER = '[REDACTED]';

// Sensitive object keys whose values are replaced wholesale, regardless of shape.
const SENSITIVE_KEYS = new Set([
  'token',
  'authorization',
  'accesstoken',
  'refreshtoken',
  'apikey',
  'secret',
  'password',
  'credentials',
  'anthropic_auth_token',
  'anthropic_api_key',
]);

// Value-shape patterns for secrets that may appear inside free-form strings.
const VALUE_PATTERNS: RegExp[] = [
  // Discord bot token: <base64 userId>.<base64 timestamp>.<base64 hmac>. The real
  // shape is tight (~23-28 . ~6-7 . ~27-40 chars) with word boundaries, so benign
  // dotted strings (e.g. file hashes like "deadbeef.sig.0123456789") are not
  // clobbered.
  /\b[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6,7}\.[A-Za-z0-9_-]{27,40}\b/g,
  // Anthropic / OAuth style bearer tokens (sk-..., sk-ant-..., long opaque tokens).
  /\bsk-[A-Za-z0-9-]{16,}\b/g,
  // "Authorization: Bearer <token>" / "Bearer <token>" (allow multiple spaces).
  /(?<=Bearer\s{1,4})[A-Za-z0-9._-]{8,}/gi,
];

function redactString(input: string): string {
  let out = input;
  for (const pattern of VALUE_PATTERNS) {
    out = out.replace(pattern, PLACEHOLDER);
  }
  return out;
}

// Recursively redact a value: sensitive keys → placeholder, strings → pattern-scrubbed.
// Cycles are broken via a seen-set. Depth is bounded to avoid pathological payloads.
export function redact(value: unknown, seen = new WeakSet<object>(), depth = 0): unknown {
  if (typeof value === 'string') return redactString(value);
  if (value === null || typeof value !== 'object') return value;
  if (depth > 6) return '[…]';
  if (seen.has(value as object)) return '[Circular]';
  seen.add(value as object);

  if (Array.isArray(value)) {
    return value.map((item) => redact(item, seen, depth + 1));
  }

  const out: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(value as Record<string, unknown>)) {
    if (SENSITIVE_KEYS.has(key.toLowerCase())) {
      out[key] = PLACEHOLDER;
    } else {
      out[key] = redact(val, seen, depth + 1);
    }
  }
  return out;
}

// Sink for emitting a formatted line — injectable for tests. Defaults to console.
export interface LogSink {
  write(level: LogLevel, line: string): void;
}

const consoleSink: LogSink = {
  write(level, line) {
    if (level === 'error') console.error(line);
    else if (level === 'warn') console.warn(line);
    else console.log(line);
  },
};

export interface LoggerOptions {
  level?: LogLevel;
  sink?: LogSink;
}

function formatMeta(meta: unknown[]): string {
  if (meta.length === 0) return '';
  const parts = meta.map((m) => {
    const scrubbed = redact(m);
    if (typeof scrubbed === 'string') return scrubbed;
    try {
      return JSON.stringify(scrubbed);
    } catch {
      return String(scrubbed);
    }
  });
  return ' ' + parts.join(' ');
}

class RedactingLogger implements Logger {
  private readonly name: string;
  private readonly threshold: number;
  private readonly sink: LogSink;

  constructor(name: string, options: LoggerOptions) {
    this.name = name;
    this.threshold = LEVEL_ORDER[options.level ?? 'info'];
    this.sink = options.sink ?? consoleSink;
  }

  private log(level: LogLevel, message: string, meta: unknown[]): void {
    if (LEVEL_ORDER[level] < this.threshold) return;
    const line = `[${level.toUpperCase()}] ${this.name}: ${redactString(message)}${formatMeta(meta)}`;
    this.sink.write(level, line);
  }

  debug(message: string, ...meta: unknown[]): void {
    this.log('debug', message, meta);
  }

  info(message: string, ...meta: unknown[]): void {
    this.log('info', message, meta);
  }

  warn(message: string, ...meta: unknown[]): void {
    this.log('warn', message, meta);
  }

  error(message: string, ...meta: unknown[]): void {
    this.log('error', message, meta);
  }
}

export function createLogger(name: string, options: LoggerOptions = {}): Logger {
  return new RedactingLogger(name, options);
}
