import Foundation

/// Provider runtime maintenance blocks new turns only after every active turn has drained.
public actor ProviderRuntimeMaintenanceGate {
    public static let shared = ProviderRuntimeMaintenanceGate()

    private var updating = false
    /// Reserved by a turn before its bridge increments `turnDepth`.  Keeping this count until
    /// the turn returns closes the await-return-to-depth-registration race.
    private var turnReservations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Atomically admit a turn.  The caller must pair this with `releaseTurn()` exactly once.
    public func reserveTurn() async {
        if !updating {
            turnReservations += 1
            return
        }
        // `finish()` reserves a slot before resuming this continuation, preventing a new
        // maintenance claim from slipping between continuation resumption and caller execution.
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Fast path of `reserveTurn()`: actor isolation keeps this increment in the same critical
    /// section as observing `updating == false`.
    public func reserveTurnIfAvailable() -> Bool {
        guard !updating else { return false }
        turnReservations += 1
        return true
    }

    public func releaseTurn() {
        guard turnReservations > 0 else { return }
        turnReservations -= 1
    }

    /// Claim the window before probing idleness, closing the idle-probe-to-swap race.
    public func beginWhenIdle(_ isIdle: @escaping @Sendable () async -> Bool) async -> Bool {
        guard !updating, turnReservations == 0 else { return false }
        updating = true
        guard await isIdle() else {
            finish()
            return false
        }
        return true
    }

    public func finish() {
        guard updating else { return }
        updating = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            turnReservations += 1
            waiter.resume()
        }
    }
}

public let providerRuntimeUpdateDefaultIntervalMs = 60 * 60 * 1_000

public enum ProviderRuntime: String, Sendable, CaseIterable, Equatable {
    case claude
    case codex
    case grok
}

public enum ProviderRuntimeUpdateStatus: String, Sendable, Equatable {
    case disabled
    case deferredBusy
    case upToDate
    case updated
    case unsupported
    case failed
}

public struct ProviderRuntimeUpdateItem: Sendable, Equatable {
    public var provider: ProviderRuntime
    public var status: ProviderRuntimeUpdateStatus
    public var version: String?
    public var detail: String?

    public init(provider: ProviderRuntime, status: ProviderRuntimeUpdateStatus, version: String? = nil, detail: String? = nil) {
        self.provider = provider
        self.status = status
        self.version = version
        self.detail = detail
    }
}

public struct ProviderRuntimeUpdateReport: Sendable, Equatable {
    public var items: [ProviderRuntimeUpdateItem]
    public init(items: [ProviderRuntimeUpdateItem]) { self.items = items }
}

public struct ProviderRuntimeUpdateCoordinatorDeps: Sendable {
    public var enabled: @Sendable () async -> Bool
    public var intervalMs: Int
    public var beginMaintenance: @Sendable () async -> Bool
    public var endMaintenance: @Sendable () async -> Void
    public var updateClaude: @Sendable () async -> ProviderRuntimeUpdateItem
    public var updateCodex: @Sendable () async -> ProviderRuntimeUpdateItem
    public var updateGrok: @Sendable () async -> ProviderRuntimeUpdateItem
    public var onLog: @Sendable (String) -> Void

    public init(
        enabled: @escaping @Sendable () async -> Bool,
        intervalMs: Int = providerRuntimeUpdateDefaultIntervalMs,
        beginMaintenance: @escaping @Sendable () async -> Bool,
        endMaintenance: @escaping @Sendable () async -> Void,
        updateClaude: @escaping @Sendable () async -> ProviderRuntimeUpdateItem,
        updateCodex: @escaping @Sendable () async -> ProviderRuntimeUpdateItem,
        updateGrok: @escaping @Sendable () async -> ProviderRuntimeUpdateItem,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.enabled = enabled
        self.intervalMs = intervalMs
        self.beginMaintenance = beginMaintenance
        self.endMaintenance = endMaintenance
        self.updateClaude = updateClaude
        self.updateCodex = updateCodex
        self.updateGrok = updateGrok
        self.onLog = onLog
    }
}

/// A serial check holds one maintenance transaction across all three provider runtimes.
public actor ProviderRuntimeUpdateCoordinator {
    private let deps: ProviderRuntimeUpdateCoordinatorDeps
    private var loopTask: Task<Void, Never>?
    private var checking = false
    private var checkWaiters: [CheckedContinuation<Void, Never>] = []

    public init(deps: ProviderRuntimeUpdateCoordinatorDeps) { self.deps = deps }

    public func start() async {
        guard loopTask == nil else { return }
        let interval = UInt64(max(1, deps.intervalMs)) * 1_000_000
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                _ = await self.checkNow()
            }
        }
        _ = await checkNow()
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// A replacement must not overlap an in-flight maintenance transaction with its own boot
    /// check.  This mirrors AutoUpdater's hand-off invariant.
    public func stopAndWaitForCurrentCheck() async {
        stop()
        guard checking else { return }
        await withCheckedContinuation { checkWaiters.append($0) }
    }

    @discardableResult
    public func checkNow() async -> ProviderRuntimeUpdateReport {
        let all = ProviderRuntime.allCases
        guard await deps.enabled() else {
            return ProviderRuntimeUpdateReport(items: all.map { .init(provider: $0, status: .disabled) })
        }
        guard !checking else {
            return ProviderRuntimeUpdateReport(items: all.map { .init(provider: $0, status: .deferredBusy, detail: "check already running") })
        }
        checking = true
        defer {
            checking = false
            let waiters = checkWaiters
            checkWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        guard await deps.beginMaintenance() else {
            return ProviderRuntimeUpdateReport(items: all.map { .init(provider: $0, status: .deferredBusy, detail: "active turn") })
        }
        let items = [await deps.updateClaude(), await deps.updateCodex(), await deps.updateGrok()]
        await deps.endMaintenance()
        for item in items {
            deps.onLog("provider-runtime: \(item.provider.rawValue) \(item.status.rawValue)\(item.version.map { " version=\($0)" } ?? "")\(item.detail.map { " \($0)" } ?? "")")
        }
        return ProviderRuntimeUpdateReport(items: items)
    }
}

public actor ProviderRuntimeUpdateRegistry {
    public static let shared = ProviderRuntimeUpdateRegistry()
    private var coordinator: ProviderRuntimeUpdateCoordinator?
    /// A replacement remains owned across suspension points.  Actor reentrancy alone is not
    /// sufficient here: recovery and `next.start()` both await, and a second reconnect must not
    /// enter between them and interpret the first updater's live transaction journal as stale.
    private var replacing = false
    private var replacementWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func startReplacing(with next: ProviderRuntimeUpdateCoordinator) async {
        await replaceAfterCurrentCheck(with: next) {}
    }

    /// Serializes a reconnect hand-off with startup recovery.  `beforeStart` runs only after the
    /// previous coordinator has fully completed its maintenance transaction, while this caller
    /// still owns replacement so another reconnect cannot race the recovery or boot check.
    public func replaceAfterCurrentCheck(
        with next: ProviderRuntimeUpdateCoordinator,
        beforeStart: @escaping @Sendable () async -> Void
    ) async {
        await acquireReplacement()
        defer { releaseReplacement() }
        await coordinator?.stopAndWaitForCurrentCheck()
        await beforeStart()
        coordinator = next
        await next.start()
    }

    public func get() -> ProviderRuntimeUpdateCoordinator? { coordinator }

    private func acquireReplacement() async {
        guard !replacing else {
            await withCheckedContinuation { replacementWaiters.append($0) }
            return
        }
        replacing = true
    }

    private func releaseReplacement() {
        guard replacing else { return }
        guard !replacementWaiters.isEmpty else {
            replacing = false
            return
        }
        let next = replacementWaiters.removeFirst()
        // Keep `replacing` true until the resumed waiter releases ownership.  This closes the
        // resume-to-execution gap that would otherwise admit a third reconnect.
        next.resume()
    }
}
