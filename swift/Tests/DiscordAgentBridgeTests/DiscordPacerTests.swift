import Foundation
import Testing
@testable import dab

// The pacer exists to stop a turn-end burst from crashing into DiscordBM's global-per-second
// ceiling (see DiscordPacer.swift). `reserve` is the whole of that logic — `acquire` only sleeps
// for the duration it returns — so driving it with a fixed `now` proves the schedule without the
// test ever waiting.
@Suite("DiscordPacer")
struct DiscordPacerTests {
    @Test("callers arriving together are spaced one interval apart, in arrival order")
    func spacesConcurrentArrivals() async {
        let pacer = DiscordPacer(interval: .milliseconds(50))
        let now = ContinuousClock.now
        #expect(await pacer.reserve(now: now) == .zero)
        #expect(await pacer.reserve(now: now) == .milliseconds(50))
        #expect(await pacer.reserve(now: now) == .milliseconds(100))
    }

    @Test("an idle stretch collapses the queue — a quiet bot never waits")
    func idleCollapsesQueue() async {
        let pacer = DiscordPacer(interval: .milliseconds(50))
        let now = ContinuousClock.now
        _ = await pacer.reserve(now: now)
        _ = await pacer.reserve(now: now)
        #expect(await pacer.reserve(now: now.advanced(by: .seconds(1))) == .zero)
    }

    @Test("a caller arriving mid-queue waits only the remainder")
    func waitsOnlyTheRemainder() async {
        let pacer = DiscordPacer(interval: .milliseconds(50))
        let now = ContinuousClock.now
        _ = await pacer.reserve(now: now)
        _ = await pacer.reserve(now: now)
        // Queue now runs to now+100ms; arriving 60ms in leaves 40ms of it.
        #expect(await pacer.reserve(now: now.advanced(by: .milliseconds(60))) == .milliseconds(40))
    }
}
