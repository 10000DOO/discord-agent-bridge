import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("AutoUpdater.checkNow")
struct AutoUpdaterCheckTests {
    @Test func skipsWhenDisabled() async {
        let h = UpdateHarness()
        h.enabledBox.withLock { $0 = false }
        let r = await h.updater.checkNow()
        #expect(r.kind == .disabled)
        #expect(h.postsBox.withLock { $0 }.isEmpty)
        #expect(h.metaBox.withLock { $0 }.lastCheckAt == 0)
    }

    @Test func postsNewerStable() async {
        let h = UpdateHarness()
        let r = await h.updater.checkNow()
        #expect(r.kind == .available)
        #expect(h.postsBox.withLock { $0 } == ["1.1.0"])
        #expect(h.metaBox.withLock { $0 }.lastCheckAt == 1_000_000)
    }

    @Test func repostsUntilDismissed() async {
        let h = UpdateHarness()
        _ = await h.updater.checkNow()
        _ = await h.updater.checkNow()
        _ = await h.updater.checkNow()
        #expect(h.postsBox.withLock { $0 } == ["1.1.0", "1.1.0", "1.1.0"])
    }

    @Test func silentWhenNotNewer() async {
        let h = UpdateHarness(latest: "1.0.0")
        let r = await h.updater.checkNow()
        #expect(r.kind == .upToDate)
        #expect(h.postsBox.withLock { $0 }.isEmpty)
        #expect(h.metaBox.withLock { $0 }.lastCheckAt == 1_000_000)
    }

    @Test func silentWhenDismissed() async {
        let h = UpdateHarness()
        h.metaBox.withLock { $0.dismissedVersion = "1.1.0" }
        let r = await h.updater.checkNow()
        #expect(r.kind == .dismissed)
        #expect(h.postsBox.withLock { $0 }.isEmpty)
    }

    @Test func advancesLastCheckOnNullFetch() async {
        let h = UpdateHarness(latest: nil)
        let r = await h.updater.checkNow()
        #expect(r.kind == .fetchFailed)
        #expect(h.postsBox.withLock { $0 }.isEmpty)
        #expect(h.metaBox.withLock { $0 }.lastCheckAt == 1_000_000)
    }

    @Test func postFalseDoesNotPost() async {
        let h = UpdateHarness()
        let r = await h.updater.checkNow(post: false)
        #expect(r.kind == .available)
        #expect(h.postsBox.withLock { $0 }.isEmpty)
    }

    @Test func retriesWhenControlChannelExistsButPromptSendFails() async {
        let h = UpdateHarness(postPromptAvailable: false)
        _ = await h.updater.checkNow()
        #expect(h.postsBox.withLock { $0 }.isEmpty)

        h.postPromptAvailableBox.withLock { $0 = true }
        await h.updater.checkAfterControlChannelReady()
        #expect(h.postsBox.withLock { $0 } == ["1.1.0"])

        await h.updater.checkAfterControlChannelReady()
        #expect(h.postsBox.withLock { $0 } == ["1.1.0"])
    }
}

@Suite("AutoUpdater.approve / dismiss")
struct AutoUpdaterDecisionTests {
    @Test func approveWithoutInstallIsManualOnly() async {
        let h = UpdateHarness()
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(ctx.disabled == 1)
        #expect(ctx.acks == [UpdateLabels.manualOnly])
        #expect(h.restartCallsBox.withLock { $0 } == 0)
        #expect(h.announcesBox.withLock { $0 }.isEmpty)
    }

    @Test func approveWithInstallThenRestart() async {
        let h = UpdateHarness(withInstall: true)
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(ctx.disabled == 1)
        #expect(h.installCallsBox.withLock { $0 } == 1)
        #expect(h.restartCallsBox.withLock { $0 } == 1)
        // Outcomes go to the interaction channel (ctx.ack), not control-channel announce.
        #expect(h.announcesBox.withLock { $0 }.isEmpty)
        #expect(ctx.acks.contains { $0.contains("시작") })
        #expect(ctx.acks.contains(UpdateLabels.restartRequested))
        #expect(ctx.acks.contains(UpdateLabels.restartConfirmed))
    }

    @Test func installFailureDoesNotRestart() async {
        let h = UpdateHarness(withInstall: true, installOk: false)
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(h.restartCallsBox.withLock { $0 } == 0)
        #expect(h.installCallsBox.withLock { $0 } == 1)
        #expect(h.announcesBox.withLock { $0 }.isEmpty)
        #expect(ctx.acks.contains(UpdateLabels.installFailed))
    }

    @Test func installSuccessWithRelaunchFailureAcksRestartFailed() async {
        let h = UpdateHarness(withInstall: true, restartResult: .manualRestartRequired)
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(h.restartCallsBox.withLock { $0 } == 1)
        #expect(h.announcesBox.withLock { $0 }.isEmpty)
        #expect(ctx.acks.contains(UpdateLabels.restartRequested))
        #expect(ctx.acks.contains(UpdateLabels.restartFailed))
    }

    @Test func approveDelegatesToHomebrewTriggerAndSkipsInstall() async {
        let triggerCallsBox = LockedBox<[(String, String)]>([])
        let h = UpdateHarness(withInstall: true, homebrewTrigger: { appId, token in
            triggerCallsBox.withLock { $0.append((appId, token)) }
            return true
        })
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(triggerCallsBox.withLock { $0 }.count == 1)
        #expect(triggerCallsBox.withLock { $0 }[0].0 == "app-1")
        #expect(triggerCallsBox.withLock { $0 }[0].1 == "token-1")
        #expect(ctx.disabled == 1)
        #expect(ctx.acks == [UpdateLabels.homebrewInProgress])
        #expect(h.installCallsBox.withLock { $0 } == 0)
        #expect(h.restartCallsBox.withLock { $0 } == 0)
        #expect(h.announcesBox.withLock { $0 }.isEmpty)
    }

    @Test func approveFallsBackToInstallWhenHomebrewTriggerReturnsFalse() async {
        let h = UpdateHarness(withInstall: true, homebrewTrigger: { _, _ in false })
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(ctx.disabled == 1)
        #expect(h.installCallsBox.withLock { $0 } == 1)
        #expect(h.restartCallsBox.withLock { $0 } == 1)
        #expect(h.announcesBox.withLock { $0 }.isEmpty)
        #expect(ctx.acks.contains(UpdateLabels.restartRequested))
        #expect(ctx.acks.contains(UpdateLabels.restartConfirmed))
    }

    @Test func dismissPersistsAndAcks() async {
        let h = UpdateHarness()
        let ctx = DecisionProbe()
        await h.updater.dismiss("1.1.0", ctx: ctx.asCtx())
        #expect(h.metaBox.withLock { $0 }.dismissedVersion == "1.1.0")
        #expect(ctx.disabled == 1)
        #expect(ctx.acks == [UpdateLabels.dismissed])
        #expect(h.restartCallsBox.withLock { $0 } == 0)
        let r = await h.updater.checkNow()
        #expect(r.kind == .dismissed)
        #expect(h.postsBox.withLock { $0 }.isEmpty)
    }
}

@Suite("AutoUpdaterRegistry")
struct AutoUpdaterRegistryTests {
    @Test func replacingStopsPreviousSchedule() async {
        let first = UpdateHarness(intervalMs: 10)
        let second = UpdateHarness(intervalMs: 10)
        let registry = AutoUpdaterRegistry()
        await registry.startReplacing(with: first.updater)

        for _ in 0..<20 where first.fetchCallsBox.withLock({ $0 }) < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(first.fetchCallsBox.withLock { $0 } >= 2)

        await registry.startReplacing(with: second.updater)
        let firstCallsAfterReplacement = first.fetchCallsBox.withLock { $0 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let current = await registry.get()
        #expect(current === second.updater)
        #expect(first.fetchCallsBox.withLock { $0 } == firstCallsAfterReplacement)
        #expect(second.fetchCallsBox.withLock { $0 } >= 2)
        await second.updater.stop()
    }

    @Test func replacementWaitsForPreviousDueCheckBeforeStartingSuccessor() async {
        let events = LockedBox<[String]>([])
        let first = UpdateHarness(intervalMs: 500_000, fetchLatest: {
            events.withLock { $0.append("first-start") }
            try? await Task.sleep(nanoseconds: 50_000_000)
            events.withLock { $0.append("first-end") }
            return "1.1.0"
        })
        let second = UpdateHarness(intervalMs: 500_000, fetchLatest: {
            events.withLock { $0.append("second-start") }
            return "1.1.0"
        })
        let registry = AutoUpdaterRegistry()

        let firstStart = Task { await registry.startReplacing(with: first.updater) }
        for _ in 0..<20 where !events.withLock({ $0.contains("first-start") }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(events.withLock { $0.contains("first-start") })
        let replacement = Task { await registry.startReplacing(with: second.updater) }
        await firstStart.value
        await replacement.value
        let order = events.withLock { $0 }
        if let firstEnd = order.firstIndex(of: "first-end"),
           let secondStart = order.firstIndex(of: "second-start")
        {
            #expect(firstEnd < secondStart)
        } else {
            #expect(Bool(false), "expected both due checks to run")
        }
        #expect(second.fetchCallsBox.withLock { $0 } == 1)
        await first.updater.stop()
        await second.updater.stop()
    }
}

// MARK: - Harness

private final class DecisionProbe: @unchecked Sendable {
    private let acksBox = LockedBox<[String]>([])
    private let disabledBox = LockedBox(0)

    var acks: [String] { acksBox.withLock { $0 } }
    var disabled: Int { disabledBox.withLock { $0 } }

    func asCtx() -> UpdateDecisionCtx {
        UpdateDecisionCtx(
            actorId: "admin-1",
            guildId: "g1",
            channelId: "c1",
            applicationId: "app-1",
            interactionToken: "token-1",
            ack: { [acksBox] t in acksBox.withLock { $0.append(t) } },
            disableButtons: { [disabledBox] in disabledBox.withLock { $0 += 1 } }
        )
    }
}

private final class UpdateHarness: @unchecked Sendable {
    let updater: AutoUpdater
    let metaBox: LockedBox<AutoUpdateMeta>
    let postsBox: LockedBox<[String]>
    let enabledBox: LockedBox<Bool>
    let installCallsBox: LockedBox<Int>
    let restartCallsBox: LockedBox<Int>
    let announcesBox: LockedBox<[String]>
    let postPromptAvailableBox: LockedBox<Bool>
    let fetchCallsBox: LockedBox<Int>

    init(
        latest: String? = "1.1.0",
        withInstall: Bool = false,
        installOk: Bool = true,
        restartResult: RestartResult = .handedOff,
        postPromptAvailable: Bool = true,
        intervalMs: Int = updateDefaultIntervalMs,
        fetchLatest: (@Sendable () async -> String?)? = nil,
        homebrewTrigger: (@Sendable (String, String) -> Bool)? = nil
    ) {
        let metaBox = LockedBox(AutoUpdateMeta())
        let postsBox = LockedBox<[String]>([])
        let enabledBox = LockedBox(true)
        let latestBox = LockedBox(latest)
        let installCallsBox = LockedBox(0)
        let restartCallsBox = LockedBox(0)
        let announcesBox = LockedBox<[String]>([])
        let postPromptAvailableBox = LockedBox(postPromptAvailable)
        let fetchCallsBox = LockedBox(0)
        let okBox = LockedBox(installOk)

        var install: (@Sendable () async -> UpdateInstallResult)?
        if withInstall {
            install = {
                installCallsBox.withLock { $0 += 1 }
                let ok = okBox.withLock { $0 }
                return UpdateInstallResult(ok: ok, code: ok ? 0 : 1, stderr: ok ? "" : "fail")
            }
        }

        let deps = AutoUpdaterDeps(
            currentVersion: "1.0.0",
            enabled: { enabledBox.withLock { $0 } },
            intervalMs: intervalMs,
            now: { 1_000_000 },
            fetchLatest: {
                fetchCallsBox.withLock { $0 += 1 }
                if let fetchLatest { return await fetchLatest() }
                return latestBox.withLock { $0 }
            },
            readMeta: { metaBox.withLock { $0 } },
            writeMeta: { patch in
                metaBox.withLock { m in
                    if let t = patch.lastCheckAt { m.lastCheckAt = t }
                    if let d = patch.dismissedVersion { m.dismissedVersion = d }
                }
            },
            postPrompt: { v in
                guard postPromptAvailableBox.withLock({ $0 }) else { return false }
                postsBox.withLock { $0.append(v) }
                return true
            },
            announce: { t in announcesBox.withLock { $0.append(t) } },
            install: install,
            restart: { request in
                restartCallsBox.withLock { $0 += 1 }
                // Simulate respawn READY confirm path when handoff succeeds.
                if restartResult == .handedOff {
                    await request.notify(UpdateLabels.restartConfirmed)
                }
                return restartResult
            },
            homebrewTrigger: homebrewTrigger,
            messages: .korean,
            onLog: { _ in }
        )
        self.updater = AutoUpdater(deps: deps)
        self.metaBox = metaBox
        self.postsBox = postsBox
        self.enabledBox = enabledBox
        self.installCallsBox = installCallsBox
        self.restartCallsBox = restartCallsBox
        self.announcesBox = announcesBox
        self.postPromptAvailableBox = postPromptAvailableBox
        self.fetchCallsBox = fetchCallsBox
    }
}
