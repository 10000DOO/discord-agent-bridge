import Foundation
import Testing
@testable import DiscordAgentBridge

// Manual timer harness (TS idleWatchdog.test.ts pattern): capture the pending
// callback and fire it explicitly so no real wall-clock time passes.

/// Collect posted (channelId, content) pairs from the watchdog poster.
actor PostSink {
    private(set) var posts: [(channelId: String, content: String)] = []

    func record(channelId: String, content: String) {
        posts.append((channelId, content))
    }

    func count() -> Int { posts.count }

    func lastContent() -> String? { posts.last?.content }
}

/// Single pending callback — enough for per-channel unit tests (no wall clock).
final class SingleShotManualTimer: @unchecked Sendable {
    private let state = LockedBox<(pending: (@Sendable () -> Void)?, lastMs: Int?, scheduleCount: Int)>(
        (pending: nil, lastMs: nil, scheduleCount: 0)
    )

    var hasPending: Bool {
        state.withLock { $0.pending != nil }
    }

    var lastMs: Int? {
        state.withLock { $0.lastMs }
    }

    var scheduleCount: Int {
        state.withLock { $0.scheduleCount }
    }

    func schedule(ms: Int, fire: @escaping @Sendable () -> Void) -> IdleTimerHandle {
        state.withLock {
            $0.pending = fire
            $0.lastMs = ms
            $0.scheduleCount += 1
        }
        return IdleTimerHandle { [state] in
            state.withLock { $0.pending = nil }
        }
    }

    func cancel(_ handle: IdleTimerHandle) {
        handle.cancel()
    }

    func fire() {
        let fn: (@Sendable () -> Void)? = state.withLock {
            let f = $0.pending
            $0.pending = nil
            return f
        }
        fn?()
    }
}

/// Captures every scheduled fire so a stale callback can be re-invoked (once-only test).
final class CapturingTimer: @unchecked Sendable {
    private let fires = LockedBox<[@Sendable () -> Void]>([])

    var lastFire: (@Sendable () -> Void)? {
        fires.withLock { $0.last }
    }

    func schedule(ms: Int, fire: @escaping @Sendable () -> Void) -> IdleTimerHandle {
        _ = ms
        fires.withLock { $0.append(fire) }
        // No-op cancel so the captured fire remains invokable after "cancel".
        return IdleTimerHandle {}
    }
}

@Suite("IdleWatchdog")
struct IdleWatchdogTests {

    @Test func defaultTimeoutIsThreeMinutes() {
        #expect(idleWatchdogTimeoutMs == 3 * 60 * 1000)
    }

    @Test func idleMessageIsKorean() {
        #expect(idleWatchdogMessageKo.contains("3분"))
        #expect(idleWatchdogMessageKo.contains("활동"))
    }

    @Test func armNoActivityFirePostsOnce() async {
        let timer = SingleShotManualTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in timer.schedule(ms: ms, fire: fire) },
            cancel: { h in timer.cancel(h) }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        #expect(timer.hasPending)
        #expect(timer.lastMs == 50)

        timer.fire()
        // Allow actor hop from timer callback → onFire → poster.
        try? await Task.sleep(nanoseconds: 30_000_000)

        #expect(await sink.count() == 1)
        #expect(await sink.lastContent() == idleWatchdogMessageKo)
    }

    @Test func noteActivityResetsTimerNoPrematurePost() async {
        let timer = SingleShotManualTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in timer.schedule(ms: ms, fire: fire) },
            cancel: { h in timer.cancel(h) }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        #expect(timer.hasPending)
        let scheduledAfterArm = timer.scheduleCount
        // noteActivity should cancel prior handle and schedule a fresh one.
        await w.noteActivity(channelId: "c1")
        #expect(timer.hasPending)
        #expect(timer.scheduleCount == scheduledAfterArm + 1)
        #expect(await sink.count() == 0)

        timer.fire()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 1)
    }

    @Test func firesOnlyOnceEvenIfCallbackReinvoked() async {
        let cap = CapturingTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in cap.schedule(ms: ms, fire: fire) },
            cancel: { _ in }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        let first = cap.lastFire
        #expect(first != nil)

        first?()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 1)

        // Re-invoke the same callback — must not post again.
        first?()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 1)
    }

    @Test func stopBeforeFireNoPost() async {
        let timer = SingleShotManualTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in timer.schedule(ms: ms, fire: fire) },
            cancel: { h in timer.cancel(h) }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        await w.stop(channelId: "c1")
        #expect(!timer.hasPending)

        timer.fire()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 0)
    }

    @Test func rearmAfterFireAllowsSecondNotice() async {
        let timer = SingleShotManualTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in timer.schedule(ms: ms, fire: fire) },
            cancel: { h in timer.cancel(h) }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        timer.fire()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 1)

        await w.arm(channelId: "c1")
        #expect(timer.hasPending)
        timer.fire()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 2)
        #expect(await sink.lastContent() == idleWatchdogMessageKo)
    }

    @Test func noteActivityAfterFireIsNoOp() async {
        let timer = SingleShotManualTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in timer.schedule(ms: ms, fire: fire) },
            cancel: { h in timer.cancel(h) }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        timer.fire()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 1)

        await w.noteActivity(channelId: "c1")
        #expect(!timer.hasPending)
    }

    @Test func disposeStopsLikeStop() async {
        let timer = SingleShotManualTimer()
        let sink = PostSink()
        let w = IdleWatchdog(
            timeoutMs: 50,
            schedule: { ms, fire in timer.schedule(ms: ms, fire: fire) },
            cancel: { h in timer.cancel(h) }
        )
        await w.setPoster { ch, content in
            await sink.record(channelId: ch, content: content)
        }

        await w.arm(channelId: "c1")
        await w.dispose(channelId: "c1")
        timer.fire()
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await sink.count() == 0)
    }
}
