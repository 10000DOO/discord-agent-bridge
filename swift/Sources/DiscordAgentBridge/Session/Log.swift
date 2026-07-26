import Foundation

// Swift port of `src/core/logger.ts` (C11). Level-gated, secret-redacting logger.
//
// TS's `RedactingLogger` captures its threshold once at construction, from an already-loaded
// config passed in explicitly (`createLogger('app', { level: config.logLevel })` in `app.ts`,
// called once at boot after config load — no DI container, `logger` is then threaded through
// every module by hand). Swift has no such single call site: operational logging is scattered
// across many files as lazily-created `private let log = Logger(name: "...")` globals, each
// first touched at an unpredictable point relative to boot's config load. Pinning a threshold
// at construction here could freeze a logger on the "info" default if its first message fires
// before config finishes loading. Instead: when no explicit `level` is given, `log()` reads
// `currentLogLevel` fresh on every call — a process-wide box set once at boot from
// `config.logLevel` (see `DabMain.swift`'s onReady). Passing an explicit `level` (as tests do)
// pins the threshold and bypasses the box entirely, for deterministic gating independent of
// process state.
//
// TS's `redact()` (recursive object redaction for structured `...meta: unknown[]` args) is not
// ported: every Swift call site logs a single already-interpolated string, never a separate meta
// object, so only the string-level `redactString` port matters — and that already exists as
// `redactSecrets` (`Session/AuditLog.swift`), reused here rather than duplicated.

/// Mirrors TS `LogLevel` (`logger.ts:7`) and `LEVEL_ORDER` (`logger.ts:9`).
public enum LogLevel: String, Sendable, Comparable {
    case debug, info, warn, error

    private var order: Int {
        switch self {
        case .debug: return 10
        case .info: return 20
        case .warn: return 30
        case .error: return 40
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.order < rhs.order }
}

/// Process-wide log level, set once at boot from `config.logLevel` (TS reads config once before
/// creating its single `app` logger; Swift's many lazily-created per-file loggers read this
/// instead). Defaults to "info", matching `ConfigSchema.swift`'s `logLevel` default.
public let currentLogLevel = LockedBox<LogLevel>(.info)

/// Emits one formatted line — injectable for tests. Default mirrors TS `consoleSink`
/// (`logger.ts:85-91`): error/warn → stderr, everything else → stdout (Node's
/// `console.error`/`console.warn` go to stderr, `console.log` to stdout).
public protocol LogSink: Sendable {
    func write(level: LogLevel, line: String)
}

public struct ConsoleSink: LogSink {
    public init() {}

    public func write(level: LogLevel, line: String) {
        switch level {
        case .error, .warn:
            // Matches the existing `fputs(..., stderr)` convention used across the codebase
            // for stderr writes (e.g. `ConfigStore.swift`, `DabMain.swift`).
            fputs(line + "\n", stderr)
        case .debug, .info:
            print(line)
        }
    }
}

/// Swift port of TS `RedactingLogger` (`logger.ts:112-144`). A plain `Sendable` value (not an
/// actor, unlike `AuditLog`): its state (name/level/sink) is immutable after init, and unlike
/// `AuditLog`'s append-only file it has no ordering guarantee to protect.
public struct Logger: Sendable {
    private let name: String
    private let fixedLevel: LogLevel?
    private let sink: any LogSink

    /// - Parameter level: pins the gating threshold, bypassing `currentLogLevel` (tests use
    ///   this for deterministic behavior). Nil (default) reads `currentLogLevel` on every call.
    public init(name: String, level: LogLevel? = nil, sink: any LogSink = ConsoleSink()) {
        self.name = name
        self.fixedLevel = level
        self.sink = sink
    }

    private var threshold: LogLevel { fixedLevel ?? currentLogLevel.withLock { $0 } }

    private func log(_ level: LogLevel, _ message: String) {
        guard level >= threshold else { return }
        let line = "[\(level.rawValue.uppercased())] \(name): \(redactSecrets(message))"
        sink.write(level: level, line: line)
    }

    public func debug(_ message: String) { log(.debug, message) }
    public func info(_ message: String) { log(.info, message) }
    public func warn(_ message: String) { log(.warn, message) }
    public func error(_ message: String) { log(.error, message) }
}
