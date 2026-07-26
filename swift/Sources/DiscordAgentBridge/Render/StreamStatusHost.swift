import Foundation

// Per-channel live stream status coordinator (W11-g residual).
// Accumulates mid-turn text / tool_use / progress and rate-limits Discord edits
// (≈1s debounce, immediate on tool_use when the interval allows).
// Discord I/O injected once via updater (library never imports DiscordBM).

/// Edit the control message for a channel (dab maps StreamEmbedSpec → DiscordBM).
public typealias StreamStatusUpdater = @Sendable (
    _ channelId: String,
    _ messageId: String,
    _ guildId: String,
    _ spec: StreamEmbedSpec
) async -> Void

/// Mid-turn progress → rate-limited stream embed edits.
public actor StreamStatusHost {
    public static let shared = StreamStatusHost()

    /// Default minimum gap between Discord edits (TS text debounce ≈ 1s).
    public static let defaultMinFlushInterval: TimeInterval = 1.0

    /// Per-instance interval (tests inject a short value).
    private let minFlushInterval: TimeInterval
    private var updater: StreamStatusUpdater?
    private var states: [String: ChannelState] = [:]

    private struct ChannelState {
        var messageId: String
        var guildId: String
        var partialText: String = ""
        var toolCount: Int = 0
        var active: Bool = true
        var lastFlush: Date?
        var flushTask: Task<Void, Never>?
    }

    public init(minFlushInterval: TimeInterval = StreamStatusHost.defaultMinFlushInterval) {
        self.minFlushInterval = minFlushInterval
    }

    /// Wire Discord edit sink once at startup (dab). Absent → notes no-op.
    public func setUpdater(_ updater: @escaping StreamStatusUpdater) {
        self.updater = updater
    }

    /// Start tracking a turn's control message (posted by dab before runTurn).
    public func begin(channelId: String, guildId: String, messageId: String) {
        states[channelId]?.flushTask?.cancel()
        states[channelId] = ChannelState(
            messageId: messageId,
            guildId: guildId,
            active: true
        )
    }

    /// Stop mid-turn edits (turn finished / failed). Does not remove identity until dispose.
    public func end(channelId: String) {
        guard var s = states[channelId] else { return }
        s.flushTask?.cancel()
        s.flushTask = nil
        s.active = false
        states[channelId] = s
    }

    /// Drop all state for a channel (session stop / detach).
    public func dispose(channelId: String) {
        states[channelId]?.flushTask?.cancel()
        states.removeValue(forKey: channelId)
    }

    /// Append a text delta (Claude stream). Debounced flush.
    public func noteText(channelId: String, delta: String) {
        guard !delta.isEmpty, var s = states[channelId], s.active else { return }
        s.partialText += delta
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: false)
    }

    /// Increment tool count (tool_use). Prefer immediate flush when interval allows.
    public func noteToolUse(channelId: String) {
        guard var s = states[channelId], s.active else { return }
        s.toolCount += 1
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: true)
    }

    /// Surface a progress label when no/partial text yet (or append a line).
    public func noteProgress(channelId: String, label: String, detail: String?) {
        guard var s = states[channelId], s.active else { return }
        let line = detail.map { "\(label): \($0)" } ?? label
        if s.partialText.isEmpty {
            s.partialText = line
        } else {
            s.partialText += "\n" + line
        }
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: false)
    }

    // MARK: - rate-limited flush

    private func scheduleFlush(channelId: String, force: Bool) {
        guard var s = states[channelId], s.active else { return }
        let minInterval = minFlushInterval

        if force {
            // Immediate if enough time has passed; else wait out the remainder.
            let wait: TimeInterval
            if let last = s.lastFlush {
                let elapsed = Date().timeIntervalSince(last)
                wait = elapsed >= minInterval ? 0 : minInterval - elapsed
            } else {
                wait = 0
            }
            s.flushTask?.cancel()
            let waitNs = UInt64(max(0, wait) * 1_000_000_000)
            // Strong self: task is owned by ChannelState.flushTask and cancelled on end/dispose.
            // weak self under parallel suite load can drop the host before sleep resumes (flaky tests).
            let task = Task {
                if waitNs > 0 {
                    try? await Task.sleep(nanoseconds: waitNs)
                }
                guard !Task.isCancelled else { return }
                await self.flushNow(channelId: channelId)
            }
            s.flushTask = task
            states[channelId] = s
            return
        }

        // Debounce: re-arm interval from latest text/progress event.
        s.flushTask?.cancel()
        let waitNs = UInt64(max(0, minInterval) * 1_000_000_000)
        let task = Task {
            if waitNs > 0 {
                try? await Task.sleep(nanoseconds: waitNs)
            }
            guard !Task.isCancelled else { return }
            await self.flushNow(channelId: channelId)
        }
        s.flushTask = task
        states[channelId] = s
    }

    private func flushNow(channelId: String) async {
        guard var s = states[channelId], s.active else { return }
        s.flushTask = nil
        s.lastFlush = Date()
        let messageId = s.messageId
        let guildId = s.guildId
        let spec = formatStreamEmbed(partialText: s.partialText, toolCount: s.toolCount)
        states[channelId] = s
        guard let updater else { return }
        await updater(channelId, messageId, guildId, spec)
    }
}
