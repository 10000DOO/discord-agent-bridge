import Foundation

// Per-channel tool-activity coordinator (W16-g). Owns TurnThreadRegistry + ToolThreadHandler
// + DiffViewHandler for each session channel. Discord I/O injected once via channel factory
// (same DocumentShareHost / PermissionPresenter pattern — library never imports DiscordBM).

/// Builds a TurnThreadChannel for a Discord session channel id.
public typealias TurnThreadChannelFactory = @Sendable (_ channelId: String) -> TurnThreadChannel

/// C15: status-channel tool_use notification (TS `SessionNotifier` — a subscription
/// independent of RendererDispatcher/render caps). Fired only for `.toolUse`, never `.toolResult`.
public typealias ToolUseNotifier = @Sendable (
    _ channelId: String, _ guildId: String, _ backend: Backend, _ event: AgentEvent
) async -> Void

/// Mid-turn tool_use / tool_result → Discord work threads + diffs.
public actor ToolActivityHost {
    public static let shared = ToolActivityHost()

    private var factory: TurnThreadChannelFactory?
    private var states: [String: ChannelState] = [:]
    /// Per-channel render caps (set by dab each turn). Absent → allEnabled.
    private var capsByChannel: [String: Capabilities] = [:]
    private var notifier: ToolUseNotifier?
    /// Per-channel guildId/backend for the C15 notifier (set by dab each turn).
    private var notifyContextByChannel: [String: (guildId: String, backend: Backend)] = [:]

    private struct ChannelState {
        var registry: TurnThreadRegistry
        var toolThread: ToolThreadHandler
        var diff: DiffViewHandler
    }

    public init() {}

    /// Wire Discord thread creation once at startup (dab). Absent → events no-op.
    public func setChannelFactory(_ factory: @escaping TurnThreadChannelFactory) {
        self.factory = factory
    }

    /// Bind render capabilities for a session channel (toolThreads / fileDiff gates).
    public func setCapabilities(channelId: String, _ caps: Capabilities) {
        capsByChannel[channelId] = caps
    }

    /// Wire the status-channel tool_use notifier once at startup (dab). Absent → no-op.
    public func setNotifier(_ notifier: @escaping ToolUseNotifier) {
        self.notifier = notifier
    }

    /// Bind guildId/backend for a session channel (dab, each turn, alongside setCapabilities).
    public func setNotifyContext(channelId: String, guildId: String, backend: Backend) {
        notifyContextByChannel[channelId] = (guildId: guildId, backend: backend)
    }

    /// Handle a tool_use or tool_result AgentEvent for a session channel.
    /// Gated by channel caps: `toolThreads` → ToolThreadHandler, `fileDiff` → DiffViewHandler.
    public func handle(channelId: String, event: AgentEvent) async {
        // C15: status-channel notification — independent of toolThreads/fileDiff render caps.
        if case .toolUse = event, let notifier, let ctx = notifyContextByChannel[channelId] {
            let ch = channelId
            let ev = event
            Task { await notifier(ch, ctx.guildId, ctx.backend, ev) }
        }
        // Task checklist panel (WO-3): a task list arrives as an ordinary tool call, and the panel
        // is not a tool renderer — so it runs before, and independently of, the caps gate below.
        // Someone who turned tool threads off still wants to see what the agent is working through.
        if case .toolUse(_, let name, let input, _) = event,
           let items = parseTaskPanelInput(name: name, input: input) {
            await TaskPanelHost.shared.noteItems(channelId: channelId, items: items)
        }
        let caps = capsByChannel[channelId] ?? .allEnabled
        if !caps.toolThreads && !caps.fileDiff { return }
        switch event {
        case .toolUse(let id, let name, let input, let parent):
            let state = ensureState(channelId: channelId)
            if caps.fileDiff {
                state.diff.noteToolUse(id: id, name: name, input: input, parentToolUseId: parent)
            }
            if caps.toolThreads {
                await state.toolThread.handleToolUse(id: id, name: name, input: input, parentToolUseId: parent)
            }
        case .toolResult(let id, let ok, let content, let parent):
            let state = ensureState(channelId: channelId)
            if caps.fileDiff {
                await state.diff.handleResult(id: id, ok: ok, content: content, parentToolUseId: parent)
            }
            if caps.toolThreads {
                await state.toolThread.handleToolResult(id: id, ok: ok, content: content, parentToolUseId: parent)
            }
        default:
            break
        }
    }

    /// Turn boundary: drop holders/maps so the next turn opens fresh threads.
    public func resetTurn(channelId: String) {
        guard let state = states[channelId] else { return }
        state.registry.reset()
        state.toolThread.resetTurn()
        state.diff.resetTurn()
    }

    /// Drop all state for a channel (session stop / detach).
    public func dispose(channelId: String) {
        capsByChannel.removeValue(forKey: channelId)
        notifyContextByChannel.removeValue(forKey: channelId)
        if let state = states.removeValue(forKey: channelId) {
            state.registry.reset()
            state.toolThread.resetTurn()
            state.diff.resetTurn()
        }
    }

    private func ensureState(channelId: String) -> ChannelState {
        if let s = states[channelId] { return s }
        let channel: TurnThreadChannel
        if let factory {
            channel = factory(channelId)
        } else {
            // No factory → no-op sink (tests may inject registry directly; host is inert).
            channel = TurnThreadChannel { name in
                TurnThreadMessage(id: "noop-\(name)") { _ in }
            }
        }
        let registry = TurnThreadRegistry(channel: channel, mainName: ToolThreadLabels.workThread)
        let state = ChannelState(
            registry: registry,
            toolThread: ToolThreadHandler(registry: registry),
            diff: DiffViewHandler(registry: registry)
        )
        states[channelId] = state
        return state
    }
}
