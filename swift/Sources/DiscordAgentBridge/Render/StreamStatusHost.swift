import Foundation

// Per-channel live stream status coordinator (W11-g residual + G-P0-03 thinking).
// Accumulates mid-turn text / thinking / tool_use / progress and rate-limits Discord edits
// (≈1s debounce, immediate on tool_use when the interval allows).
// Thinking is buffered separately from answer text (TS streamEmbed kind:'thinking').
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

    /// Default minimum gap between Discord edits while text streams (TS `TEXT_DEBOUNCE_MS` = 1000).
    public static let defaultTextFlushInterval: TimeInterval = 1.0
    /// Default minimum gap between Discord edits while thinking streams (TS `THINKING_DEBOUNCE_MS` = 2000).
    public static let defaultThinkingFlushInterval: TimeInterval = 2.0
    /// Default gap between heartbeat re-renders while a turn is live. Every other flush here is
    /// event-driven, so a stretch of a turn that produces no events at all — the model building a
    /// large tool input, measured at 3m35s for a 33KB Write — used to leave the embed frozen with
    /// no way to tell a working session from a dead one. This re-renders on a timer so the title's
    /// elapsed clock keeps moving regardless of what the backend does or doesn't send.
    public static let defaultHeartbeatInterval: TimeInterval = 5.0

    /// Per-instance intervals (tests inject short values).
    private let textFlushInterval: TimeInterval
    private let thinkingFlushInterval: TimeInterval
    /// `<= 0` disables the heartbeat entirely (tests that assert exact edit counts).
    private let heartbeatInterval: TimeInterval
    private var updater: StreamStatusUpdater?
    private var states: [String: ChannelState] = [:]

    private struct ChannelState {
        var messageId: String
        var guildId: String
        /// Answer stream buffer (AgentEvent.text) — never mixed with thinking.
        var partialText: String = ""
        /// Extended-thinking buffer (AgentEvent.thinking) — separate from reply.
        var thinkingText: String = ""
        /// Last non-tool event phase drives embed title/color.
        var phase: StreamEmbedPhase = .responding
        var toolCount: Int = 0
        var active: Bool = true
        var lastFlush: Date?
        var flushTask: Task<Void, Never>?
        /// Turn start, independent of either kind's first delta — the heartbeat's elapsed source.
        var turnStartedAt: Date?
        var heartbeatTask: Task<Void, Never>?
        // H8 title clock (TS per-kind `startedAt`, `streamEmbed.ts:58-60,87-90`): lazily set on each
        // kind's first delta, independent of the other kind, reset only at begin().
        var textStartedAt: Date?
        var thinkingStartedAt: Date?
    }

    public init(
        textFlushInterval: TimeInterval = StreamStatusHost.defaultTextFlushInterval,
        thinkingFlushInterval: TimeInterval = StreamStatusHost.defaultThinkingFlushInterval,
        heartbeatInterval: TimeInterval = StreamStatusHost.defaultHeartbeatInterval
    ) {
        self.textFlushInterval = textFlushInterval
        self.thinkingFlushInterval = thinkingFlushInterval
        self.heartbeatInterval = heartbeatInterval
    }

    /// Wire Discord edit sink once at startup (dab). Absent → notes no-op.
    public func setUpdater(_ updater: @escaping StreamStatusUpdater) {
        self.updater = updater
    }

    /// Start tracking a turn's control message (posted by dab before runTurn).
    public func begin(channelId: String, guildId: String, messageId: String) {
        states[channelId]?.flushTask?.cancel()
        states[channelId]?.heartbeatTask?.cancel()
        var s = ChannelState(
            messageId: messageId,
            guildId: guildId,
            active: true
        )
        s.turnStartedAt = Date()
        states[channelId] = s
        startHeartbeat(channelId: channelId)
    }

    /// Stop mid-turn edits (turn finished / failed). Does not remove identity until dispose.
    public func end(channelId: String) {
        guard var s = states[channelId] else { return }
        s.flushTask?.cancel()
        s.flushTask = nil
        s.heartbeatTask?.cancel()
        s.heartbeatTask = nil
        s.active = false
        states[channelId] = s
    }

    /// Drop all state for a channel (session stop / detach).
    public func dispose(channelId: String) {
        states[channelId]?.flushTask?.cancel()
        states[channelId]?.heartbeatTask?.cancel()
        states.removeValue(forKey: channelId)
    }

    /// Append a text delta (Claude stream). Debounced flush. Switches phase → responding.
    public func noteText(channelId: String, delta: String) {
        guard !delta.isEmpty, var s = states[channelId], s.active else { return }
        flashThoughtCompleteIfLeavingThinking(s, channelId: channelId)
        if s.textStartedAt == nil { s.textStartedAt = Date() }
        s.partialText += delta
        s.phase = .responding
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: false)
        // G-P1-01: any stream activity resets the turn idle watchdog.
        Task { await IdleWatchdog.shared.noteActivity(channelId: channelId) }
    }

    /// Append a thinking delta (Claude extended thinking). Not mixed into answer text.
    /// Debounced flush; phase → thinking (purple "생각 중…").
    public func noteThinking(channelId: String, delta: String) {
        guard !delta.isEmpty, var s = states[channelId], s.active else { return }
        if s.thinkingStartedAt == nil { s.thinkingStartedAt = Date() }
        s.thinkingText += delta
        s.phase = .thinking
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: false)
        Task { await IdleWatchdog.shared.noteActivity(channelId: channelId) }
    }

    /// Increment tool count (tool_use). Prefer immediate flush when interval allows.
    public func noteToolUse(channelId: String) {
        guard var s = states[channelId], s.active else { return }
        s.toolCount += 1
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: true)
        Task { await IdleWatchdog.shared.noteActivity(channelId: channelId) }
    }

    /// Surface a progress label when no/partial text yet (or append a line).
    public func noteProgress(channelId: String, label: String, detail: String?) {
        guard var s = states[channelId], s.active else { return }
        flashThoughtCompleteIfLeavingThinking(s, channelId: channelId)
        let line = detail.map { "\(label): \($0)" } ?? label
        if s.partialText.isEmpty {
            s.partialText = line
        } else {
            s.partialText += "\n" + line
        }
        s.phase = .responding
        states[channelId] = s
        scheduleFlush(channelId: channelId, force: false)
        Task { await IdleWatchdog.shared.noteActivity(channelId: channelId) }
    }

    // MARK: - rate-limited flush

    private func scheduleFlush(channelId: String, force: Bool) {
        guard var s = states[channelId], s.active else { return }
        // TS debounces text (1s) and thinking (2s) separately; pick by the channel's current phase.
        let minInterval = s.phase == .thinking ? thinkingFlushInterval : textFlushInterval

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

        // Debounce: re-arm interval from latest text/thinking/progress event.
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

    /// `heartbeat: true` is the timer path, which is the only caller allowed to fall back to the
    /// turn's own start for the title clock. Event-driven flushes keep the per-kind rule (a
    /// tool-only flush shows the tool count and no clock — see `formatStreamEmbed`'s contract).
    private func flushNow(channelId: String, heartbeat: Bool = false) async {
        guard var s = states[channelId], s.active else { return }
        s.flushTask = nil
        s.lastFlush = Date()
        let messageId = s.messageId
        let guildId = s.guildId
        // Thinking phase shows thinking buffer only; answer text stays in partialText.
        let displayText = s.phase == .thinking ? s.thinkingText : s.partialText
        // H8: the clock is per-kind (nil until that kind's first delta arrived). The heartbeat
        // additionally falls back to the turn's start, so a tick that lands before any delta still
        // renders a moving clock instead of a bare title.
        let kindStartedAt = s.phase == .thinking ? s.thinkingStartedAt : s.textStartedAt
        let startedAt = heartbeat ? (kindStartedAt ?? s.turnStartedAt) : kindStartedAt
        let spec = formatStreamEmbed(
            partialText: displayText,
            toolCount: s.toolCount,
            phase: s.phase,
            elapsedSeconds: startedAt.map { Self.elapsedSeconds(since: $0) }
        )
        states[channelId] = s
        guard let updater else { return }
        await updater(channelId, messageId, guildId, spec)
    }

    // MARK: - heartbeat

    /// Re-render on a timer for as long as the turn is live, so the embed keeps proving the session
    /// is alive through a stretch that produces no events. Only the title's elapsed value changes,
    /// so this never invents content — a turn with nothing to show still shows nothing but a clock.
    /// Cancelled by `end()` / `dispose()`; `flushNow`'s own `active` guard covers the race where
    /// the turn ends between a tick firing and the actor hop.
    private func startHeartbeat(channelId: String) {
        guard heartbeatInterval > 0 else { return }
        let waitNs = UInt64(heartbeatInterval * 1_000_000_000)
        // Strong self, same as scheduleFlush: the task is owned by ChannelState and cancelled there.
        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: waitNs)
                guard !Task.isCancelled else { return }
                await self.flushNow(channelId: channelId, heartbeat: true)
            }
        }
        states[channelId]?.heartbeatTask = task
    }

    // MARK: - H8 thought-complete flash

    /// TS `finalize()` kind:'thinking' collapses the (separate) thinking message to "Thought for
    /// Ns" once the turn ends (`streamEmbed.ts:158-164`). Swift merged both kinds into one control
    /// message, so by real turn-end it already shows the finalized "done" embed — the only point
    /// this is ever visible is the instant the phase actually leaves `.thinking`. Called from every
    /// note*() that can move the phase to `.responding` (text delta, progress line) BEFORE that
    /// mutation, so it still sees the outgoing `.thinking` state.
    private func flashThoughtCompleteIfLeavingThinking(_ state: ChannelState, channelId: String) {
        guard state.phase == .thinking, let startedAt = state.thinkingStartedAt, let updater else { return }
        let spec = formatThoughtCompleteEmbed(elapsedSeconds: Self.elapsedSeconds(since: startedAt))
        let messageId = state.messageId
        let guildId = state.guildId
        // Fire-and-forget: the caller's own scheduleFlush(force:false) right after re-arms the
        // debounce for the new (responding) phase, so this is a one-shot edit, not a tracked task.
        Task { await updater(channelId, messageId, guildId, spec) }
    }

    private static func elapsedSeconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt))
    }
}
