import Testing
import Foundation
@testable import DiscordAgentBridge

private final class FakeSink: LogSink, @unchecked Sendable {
    let lines = LockedBox<[(LogLevel, String)]>([])

    func write(level: LogLevel, line: String) {
        lines.withLock { $0.append((level, line)) }
    }
}

// .serialized: two tests below mutate the shared `currentLogLevel` box.
@Suite("Logger", .serialized)
struct LogTests {
    @Test func belowThresholdMessagesAreSuppressed() {
        let sink = FakeSink()
        let log = Logger(name: "test", level: .warn, sink: sink)

        log.debug("debug msg")
        log.info("info msg")
        log.warn("warn msg")
        log.error("error msg")

        let captured = sink.lines.withLock { $0 }
        #expect(captured.map(\.0) == [.warn, .error])
    }

    @Test func atOrAboveThresholdMessagesPass() {
        let sink = FakeSink()
        let log = Logger(name: "test", level: .info, sink: sink, now: { fixedLogInstant })

        log.info("hello")

        let captured = sink.lines.withLock { $0 }
        #expect(captured.count == 1)
        #expect(captured[0].1 == "\(fixedLogStamp) [INFO] test: hello")
    }

    @Test func formatsLevelAndNamePrefix() {
        let sink = FakeSink()
        let log = Logger(name: "myname", level: .debug, sink: sink, now: { fixedLogInstant })

        log.error("boom")

        let line = sink.lines.withLock { $0 }[0].1
        #expect(line == "\(fixedLogStamp) [ERROR] myname: boom")
    }

    @Test func redactsSecretsInMessage() {
        let sink = FakeSink()
        let log = Logger(name: "test", level: .info, sink: sink)

        log.info("token leaked: xai-abcdefghijklmnop1234 in the wild")

        let line = sink.lines.withLock { $0 }[0].1
        #expect(line.contains("[REDACTED]"))
        #expect(!line.contains("xai-abcdefghijklmnop1234"))
    }

    @Test func noExplicitLevelFallsBackToCurrentLogLevelBox() {
        let sink = FakeSink()
        let log = Logger(name: "test", sink: sink) // no `level:` → reads currentLogLevel

        currentLogLevel.withLock { $0 = .error }
        defer { currentLogLevel.withLock { $0 = .info } } // restore default for other tests

        log.warn("should be suppressed")
        log.error("should pass")

        let captured = sink.lines.withLock { $0 }
        #expect(captured.map(\.0) == [.error])
    }

    @Test func explicitLevelIgnoresCurrentLogLevelBox() {
        let sink = FakeSink()
        let log = Logger(name: "test", level: .debug, sink: sink)

        currentLogLevel.withLock { $0 = .error }
        defer { currentLogLevel.withLock { $0 = .info } }

        log.debug("still shows up")

        let captured = sink.lines.withLock { $0 }
        #expect(captured.count == 1)
    }

    @Test func levelOrderingIsDebugLtInfoLtWarnLtError() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .warn)
        #expect(LogLevel.warn < .error)
        #expect(!(LogLevel.error < .debug))
    }
}

/// Pinned clock for the two format assertions above: the line now carries a timestamp, so the
/// expectation has to be reproducible rather than wall-clock dependent.
let fixedLogInstant = Date(timeIntervalSince1970: 1_700_000_000)
var fixedLogStamp: String { logTimestamp(fixedLogInstant) }
