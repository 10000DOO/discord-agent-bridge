import Foundation

// Per-channel task checklist coordinator (docs/task-panel-and-diff-view.md WO-2).
// Mirrors StreamStatusHost: channel-keyed state, Discord I/O injected once via a sink, and
// rate-limited edits (a checklist can be rewritten several times a second mid-turn).
//
// Lifecycle, deliberately NOT turn-scoped (D3-2): a turn that publishes no list leaves the
// previous list standing. Only `/clear` · `/stop` · unbind drop the panel, through `dispose`.

/// Create-or-edit the panel message for a channel. Returns the message id to remember, or nil
/// when the post failed (the next flush retries). `messageId == nil` means "create it".
public typealias TaskPanelSink = @Sendable (
    _ channelId: String,
    _ messageId: String?,
    _ spec: TaskPanelSpec
) async -> String?

/// Unpin + delete a panel message (session teardown).
public typealias TaskPanelRemover = @Sendable (_ channelId: String, _ messageId: String) async -> Void

public actor TaskPanelHost {
    public static let shared = TaskPanelHost()

    /// Minimum gap between panel edits. Matches the stream embed's text debounce.
    public static let defaultFlushInterval: TimeInterval = 1.0

    private let flushInterval: TimeInterval
    private var sink: TaskPanelSink?
    private var remover: TaskPanelRemover?
    private var states: [String: ChannelState] = [:]

    private struct ChannelState {
        var items: [TaskPanelItem] = []
        var messageId: String?
        var lastFlush: Date?
        var flushTask: Task<Void, Never>?
        /// A sink call is in flight. A note arriving during it sets `dirty` rather than starting a
        /// second call — two concurrent creates would post (and pin) two panels.
        var sending = false
        var dirty = false
    }

    public init(flushInterval: TimeInterval = TaskPanelHost.defaultFlushInterval) {
        self.flushInterval = flushInterval
    }

    /// Wire Discord create/edit once at startup (dab). Absent → notes no-op.
    public func setSink(_ sink: @escaping TaskPanelSink) {
        self.sink = sink
    }

    /// Wire Discord unpin+delete once at startup (dab). Absent → dispose only drops state.
    public func setRemover(_ remover: @escaping TaskPanelRemover) {
        self.remover = remover
    }

    /// Replace this channel's checklist. Every backend publishes the whole list on each update,
    /// so this is a wholesale replacement, never a merge.
    public func noteItems(channelId: String, items: [TaskPanelItem]) {
        guard !items.isEmpty else { return }
        var state = states[channelId] ?? ChannelState()
        guard state.items != items else { return }
        state.items = items
        states[channelId] = state
        scheduleFlush(channelId: channelId)
    }

    /// Adopt a panel message that already exists in the channel (boot recovery, D3-3). Keeps the
    /// message id so the next update edits it instead of posting — and pinning — a second panel.
    public func adopt(channelId: String, messageId: String) {
        var state = states[channelId] ?? ChannelState()
        state.messageId = messageId
        states[channelId] = state
    }

    /// Message id currently backing this channel's panel, if any.
    public func panelMessageId(channelId: String) -> String? {
        states[channelId]?.messageId
    }

    /// Session teardown: drop the panel message and forget the channel.
    public func dispose(channelId: String) async {
        guard let state = states.removeValue(forKey: channelId) else { return }
        state.flushTask?.cancel()
        guard let messageId = state.messageId, let remover else { return }
        await remover(channelId, messageId)
    }

    // MARK: - rate-limited flush

    private func scheduleFlush(channelId: String) {
        guard var state = states[channelId] else { return }
        let wait: TimeInterval
        if let last = state.lastFlush {
            let elapsed = Date().timeIntervalSince(last)
            wait = elapsed >= flushInterval ? 0 : flushInterval - elapsed
        } else {
            wait = 0
        }
        state.flushTask?.cancel()
        let waitNs = UInt64(max(0, wait) * 1_000_000_000)
        // Strong self, like StreamStatusHost.scheduleFlush: the task is owned by ChannelState and
        // cancelled on dispose, and a weak capture drops it under parallel test load.
        let task = Task {
            if waitNs > 0 {
                try? await Task.sleep(nanoseconds: waitNs)
            }
            guard !Task.isCancelled else { return }
            await self.flushNow(channelId: channelId)
        }
        state.flushTask = task
        states[channelId] = state
    }

    private func flushNow(channelId: String) async {
        guard var state = states[channelId], let sink else { return }
        if state.sending {
            // Fold this flush into the in-flight one instead of racing it.
            state.dirty = true
            states[channelId] = state
            return
        }
        state.sending = true
        state.flushTask = nil
        state.lastFlush = Date()
        states[channelId] = state

        let spec = formatTaskPanel(items: state.items)
        let posted = await sink(channelId, state.messageId, spec)

        // dispose() may have run while the sink was in flight. Its own removal saw no message id
        // for a first-time create, so clean up here rather than leaking a pinned orphan.
        guard var after = states[channelId] else {
            if let posted, let remover {
                await remover(channelId, posted)
            }
            return
        }
        if let posted { after.messageId = posted }
        after.sending = false
        let hadPendingUpdate = after.dirty
        after.dirty = false
        states[channelId] = after
        if hadPendingUpdate {
            scheduleFlush(channelId: channelId)
        }
    }
}
