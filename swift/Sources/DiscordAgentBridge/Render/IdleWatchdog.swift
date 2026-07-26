import Foundation

// Turn-scoped idle watchdog (TS `idleWatchdog.ts`).
// Arm on turn accept, reset on mid-turn activity, stop on result/error.
// After ~3 min without activity, post `idleWatchdogMessageKo` once per arm.
// Timer is injectable so unit tests never sleep on the wall clock.

/// Default idle timeout — 3 minutes (TS `IDLE_WATCHDOG_MS`).
public let idleWatchdogTimeoutMs: Int = 3 * 60 * 1000

/// Korean notice matching TS i18n `watchdog.idle` (ko).
public let idleWatchdogMessageKo =
    "약 3분 동안 새 활동이 없습니다. 아직 긴 작업을 하는 중일 수도 있고, 멈췄을 수도 있습니다. 채널 위쪽·스레드를 확인해 보거나, 작업이 끝났는지 에이전트한테 물어보세요."

/// Post a plain channel message (dab maps to DiscordBM createMessage).
public typealias IdleWatchdogPoster = @Sendable (_ channelId: String, _ content: String) async -> Void

/// One-shot timer handle. Call `cancel()` to drop the pending fire.
public final class IdleTimerHandle: @unchecked Sendable {
    private let cancelFn: @Sendable () -> Void
    private let once = LockedBox(false)

    public init(cancel: @escaping @Sendable () -> Void) {
        self.cancelFn = cancel
    }

    public func cancel() {
        let already: Bool = once.withLock { flag in
            if flag { return true }
            flag = true
            return false
        }
        if !already { cancelFn() }
    }
}

/// Schedule a one-shot timer; returns a handle for cancel.
public typealias IdleTimerSchedule = @Sendable (
    _ milliseconds: Int,
    _ onFire: @escaping @Sendable () -> Void
) -> IdleTimerHandle

/// Cancel a previously scheduled timer.
public typealias IdleTimerCancel = @Sendable (IdleTimerHandle) -> Void

/// Production timer via `Task.sleep` (no global mutable map).
public let defaultIdleTimerSchedule: IdleTimerSchedule = { ms, fire in
    let task = Task {
        if ms > 0 {
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }
        guard !Task.isCancelled else { return }
        fire()
    }
    return IdleTimerHandle { task.cancel() }
}

public let defaultIdleTimerCancel: IdleTimerCancel = { handle in
    handle.cancel()
}

// MARK: - Actor

/// Per-channel idle watchdog. Shared instance is wired from dab; tests construct their own.
public actor IdleWatchdog {
    public static let shared = IdleWatchdog()

    private var poster: IdleWatchdogPoster?
    private var schedule: IdleTimerSchedule
    private var cancelTimer: IdleTimerCancel
    private var timeoutMs: Int
    private var channels: [String: ChannelState] = [:]

    private struct ChannelState {
        var armed: Bool
        var fired: Bool
        var timer: IdleTimerHandle?
    }

    public init(
        timeoutMs: Int = idleWatchdogTimeoutMs,
        schedule: @escaping IdleTimerSchedule = defaultIdleTimerSchedule,
        cancel: @escaping IdleTimerCancel = defaultIdleTimerCancel
    ) {
        self.timeoutMs = timeoutMs
        self.schedule = schedule
        self.cancelTimer = cancel
    }

    /// Wire Discord post sink once at startup (dab). Absent → fire is a silent no-op.
    public func setPoster(_ poster: @escaping IdleWatchdogPoster) {
        self.poster = poster
    }

    /// Start/restart watch for a new turn; clears the fired flag so a prior notice
    /// does not block a fresh idle period.
    public func arm(channelId: String) {
        clearTimer(channelId: channelId)
        channels[channelId] = ChannelState(armed: true, fired: false, timer: nil)
        resetTimer(channelId: channelId)
    }

    /// Reset the idle timer when any mid-turn activity arrives. No-op if not armed
    /// or if the notice has already fired for this arm.
    public func noteActivity(channelId: String) {
        guard let s = channels[channelId], s.armed, !s.fired else { return }
        resetTimer(channelId: channelId)
    }

    /// Cancel the timer and leave idle (call on result/error/detach).
    public func stop(channelId: String) {
        clearTimer(channelId: channelId)
        channels.removeValue(forKey: channelId)
    }

    /// Alias of stop for dispose-style call sites.
    public func dispose(channelId: String) {
        stop(channelId: channelId)
    }

    // MARK: - private

    private func clearTimer(channelId: String) {
        guard var s = channels[channelId], let h = s.timer else { return }
        cancelTimer(h)
        s.timer = nil
        channels[channelId] = s
    }

    private func resetTimer(channelId: String) {
        clearTimer(channelId: channelId)
        guard var s = channels[channelId], s.armed else { return }
        let ms = timeoutMs
        let handle = schedule(ms) {
            Task { await self.onFire(channelId: channelId) }
        }
        s.timer = handle
        channels[channelId] = s
    }

    /// Fire at most once per arm. Best-effort post; never throws from the timer path.
    private func onFire(channelId: String) async {
        guard var s = channels[channelId], s.armed, !s.fired else { return }
        s.fired = true
        if let h = s.timer {
            cancelTimer(h)
            s.timer = nil
        }
        channels[channelId] = s
        guard let poster else { return }
        await poster(channelId, idleWatchdogMessageKo)
    }
}
