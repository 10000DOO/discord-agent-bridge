import Foundation
import Testing
@testable import DiscordAgentBridge

// C14 mirror of TS `wiring.test.ts:538-755` ("SessionWiring attach outcome + finite retry"),
// adapted to Swift's send-call-site retry (see SendRetry.swift doc comment for why there's no
// separate "attach" stage to mirror 1:1). `recordingSleep` records requested delays without
// ever waiting, exactly like the TS test's `recordingSleep`.

/// Records requested delays (ns) and resolves immediately — proves the backoff schedule
/// without the test ever actually waiting.
actor DelayRecorder {
    private(set) var delaysNs: [UInt64] = []

    func record(_ ns: UInt64) {
        delaysNs.append(ns)
    }
}

@Suite("SendRetry")
struct SendRetryTests {
    @Test("succeeds on the first attempt (no delay)")
    func succeedsFirstAttemptNoDelay() async {
        let recorder = DelayRecorder()
        let calls = LockedBox(0)
        let outcome: SendRetryOutcome<Int> = await sendWithRetry(sleep: { await recorder.record($0) }) {
            calls.withLock { $0 += 1 }
            return .success(1)
        }
        #expect(outcome == .sent(1))
        #expect(calls.withLock { $0 } == 1)
        #expect(await recorder.delaysNs.isEmpty)
    }

    @Test("recovers on the 3rd attempt after 2 transient failures (delays 300/600)")
    func recoversOnThirdAttempt() async {
        let recorder = DelayRecorder()
        let calls = LockedBox(0)
        let outcome: SendRetryOutcome<Int> = await sendWithRetry(sleep: { await recorder.record($0) }) {
            let n = calls.withLock { $0 += 1; return $0 }
            return n < 3 ? .transientFailure : .success(3)
        }
        #expect(outcome == .sent(3))
        #expect(calls.withLock { $0 } == 3)
        #expect(await recorder.delaysNs == [300_000_000, 600_000_000])
    }

    @Test("exhausts at exactly 5 attempts -> unavailable (backoff 300/600/1200/2400)")
    func exhaustsAtFiveAttempts() async {
        let recorder = DelayRecorder()
        let calls = LockedBox(0)
        let outcome: SendRetryOutcome<Int> = await sendWithRetry(sleep: { await recorder.record($0) }) {
            calls.withLock { $0 += 1 }
            return .transientFailure
        }
        #expect(outcome == .unavailable)
        #expect(calls.withLock { $0 } == sendRetryMaxAttempts)
        #expect(await recorder.delaysNs == [300_000_000, 600_000_000, 1_200_000_000, 2_400_000_000])
    }

    @Test("gone stops immediately (no retry, no delay)")
    func goneStopsImmediately() async {
        let recorder = DelayRecorder()
        let calls = LockedBox(0)
        let outcome: SendRetryOutcome<Int> = await sendWithRetry(sleep: { await recorder.record($0) }) {
            calls.withLock { $0 += 1 }
            return .gone
        }
        #expect(outcome == .gone)
        #expect(calls.withLock { $0 } == 1)
        #expect(await recorder.delaysNs.isEmpty)
    }

    @Test("a transient run stops the moment it turns gone")
    func stopsTheMomentItTurnsGone() async {
        let recorder = DelayRecorder()
        let calls = LockedBox(0)
        let outcome: SendRetryOutcome<Int> = await sendWithRetry(sleep: { await recorder.record($0) }) {
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1 ? .transientFailure : .gone
        }
        #expect(outcome == .gone)
        #expect(calls.withLock { $0 } == 2) // stopped at gone; did not spend the full budget
        #expect(await recorder.delaysNs == [300_000_000]) // one gap before the 2nd attempt, none after
    }
}
