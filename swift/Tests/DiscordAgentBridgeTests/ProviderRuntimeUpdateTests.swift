import Testing
@testable import DiscordAgentBridge

@Suite("ProviderRuntimeUpdateCoordinator")
struct ProviderRuntimeUpdateCoordinatorTests {
    @Test func disabledSkipsMaintenanceAndAllProviders() async {
        let calls = LockedBox<[String]>([])
        let coordinator = ProviderRuntimeUpdateCoordinator(deps: makeDeps(
            enabled: false,
            beginMaintenance: true,
            calls: calls
        ))

        let report = await coordinator.checkNow()

        #expect(report.items.map(\.status) == [.disabled, .disabled, .disabled])
        #expect(calls.withLock { $0 }.isEmpty)
    }

    @Test func activeTurnDefersOneTransactionWithoutCallingProviders() async {
        let calls = LockedBox<[String]>([])
        let coordinator = ProviderRuntimeUpdateCoordinator(deps: makeDeps(
            enabled: true,
            beginMaintenance: false,
            calls: calls
        ))

        let report = await coordinator.checkNow()

        #expect(report.items.map(\.status) == [.deferredBusy, .deferredBusy, .deferredBusy])
        #expect(calls.withLock { $0 } == ["begin"])
    }

    @Test func updatesProvidersInOneMaintenanceWindowThenReleasesIt() async {
        let calls = LockedBox<[String]>([])
        let coordinator = ProviderRuntimeUpdateCoordinator(deps: makeDeps(
            enabled: true,
            beginMaintenance: true,
            calls: calls
        ))

        let report = await coordinator.checkNow()

        #expect(report.items.map(\.status) == [.updated, .updated, .updated])
        #expect(calls.withLock { $0 } == ["begin", "claude", "codex", "grok", "end"])
    }

    @Test func turnReservationBlocksMaintenanceBeforeBridgeDepthIsRegistered() async {
        let gate = ProviderRuntimeMaintenanceGate()
        #expect(await gate.reserveTurnIfAvailable())
        #expect(!(await gate.beginWhenIdle { true }))
        await gate.releaseTurn()
        #expect(await gate.beginWhenIdle { true })
        await gate.finish()
    }

    @Test func replacementWaitsForCurrentMaintenanceCheck() async {
        let pause = CheckPause()
        let calls = LockedBox<[String]>([])
        let deps = ProviderRuntimeUpdateCoordinatorDeps(
            enabled: { true },
            beginMaintenance: { true },
            endMaintenance: { calls.withLock { $0.append("end") } },
            updateClaude: {
                calls.withLock { $0.append("claude") }
                await pause.pause()
                return ProviderRuntimeUpdateItem(provider: .claude, status: .updated)
            },
            updateCodex: { ProviderRuntimeUpdateItem(provider: .codex, status: .updated) },
            updateGrok: { ProviderRuntimeUpdateItem(provider: .grok, status: .updated) }
        )
        let coordinator = ProviderRuntimeUpdateCoordinator(deps: deps)
        let check = Task { await coordinator.checkNow() }
        await pause.waitUntilEntered()

        let stopped = LockedBox(false)
        let replacement = Task {
            await coordinator.stopAndWaitForCurrentCheck()
            stopped.withLock { $0 = true }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(!stopped.withLock { $0 })

        await pause.release()
        _ = await check.value
        _ = await replacement.value
        #expect(stopped.withLock { $0 })
        #expect(calls.withLock { $0 } == ["claude", "end"])
    }

    /// The whole feature rests on this loop: every other test drives `checkNow()` by hand, so
    /// without it a timer that never fires again would look perfectly healthy — the bridge would
    /// update once at boot and then never notice a new version.
    @Test func startedLoopKeepsCheckingOnItsIntervalUntilStopped() async throws {
        let calls = LockedBox<[String]>([])
        let coordinator = ProviderRuntimeUpdateCoordinator(deps: makeDeps(
            enabled: true,
            beginMaintenance: true,
            calls: calls,
            intervalMs: 20
        ))

        await coordinator.start()
        // start() runs one check itself; the loop must produce more without anyone asking.
        while calls.withLock({ $0.filter { $0 == "begin" }.count }) < 3 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await coordinator.stop()

        let afterStop = calls.withLock { $0.filter { $0 == "begin" }.count }
        try await Task.sleep(nanoseconds: 150_000_000)
        // A cancelled loop must stay stopped: a replacement coordinator is started on every
        // gateway reconnect, and a leaked loop would keep claiming maintenance windows forever.
        #expect(calls.withLock { $0.filter { $0 == "begin" }.count } == afterStop)
    }

    private func makeDeps(
        enabled: Bool,
        beginMaintenance: Bool,
        calls: LockedBox<[String]>,
        intervalMs: Int = providerRuntimeUpdateDefaultIntervalMs
    ) -> ProviderRuntimeUpdateCoordinatorDeps {
        ProviderRuntimeUpdateCoordinatorDeps(
            enabled: { enabled },
            intervalMs: intervalMs,
            beginMaintenance: {
                calls.withLock { $0.append("begin") }
                return beginMaintenance
            },
            endMaintenance: { calls.withLock { $0.append("end") } },
            updateClaude: {
                calls.withLock { $0.append("claude") }
                return ProviderRuntimeUpdateItem(provider: .claude, status: .updated)
            },
            updateCodex: {
                calls.withLock { $0.append("codex") }
                return ProviderRuntimeUpdateItem(provider: .codex, status: .updated)
            },
            updateGrok: {
                calls.withLock { $0.append("grok") }
                return ProviderRuntimeUpdateItem(provider: .grok, status: .updated)
            }
        )
    }
}

private actor CheckPause {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("Provider default model binding policy")
struct ProviderDefaultModelBindingPolicyTests {
    @Test func defaultSelectionPersistsAsNil() {
        #expect(modelForPersistedBinding(providerDefaultModelSelection) == nil)
        #expect(modelForPersistedBinding("") == nil)
    }

    @Test func existingExplicitModelRemainsPinned() {
        #expect(modelForPersistedBinding("claude-opus-4-6") == "claude-opus-4-6")
        #expect(!isProviderDefaultModelSelection("claude-opus-4-6"))
    }
}
