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
    }

    @Test func approveWithInstallThenRestart() async {
        let h = UpdateHarness(withInstall: true)
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(ctx.disabled == 1)
        #expect(h.installCallsBox.withLock { $0 } == 1)
        #expect(h.restartCallsBox.withLock { $0 } == 1)
    }

    @Test func installFailureDoesNotRestart() async {
        let h = UpdateHarness(withInstall: true, installOk: false)
        let ctx = DecisionProbe()
        await h.updater.approve("1.1.0", ctx: ctx.asCtx())
        #expect(h.restartCallsBox.withLock { $0 } == 0)
        #expect(h.installCallsBox.withLock { $0 } == 1)
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

    init(
        latest: String? = "1.1.0",
        withInstall: Bool = false,
        installOk: Bool = true
    ) {
        let metaBox = LockedBox(AutoUpdateMeta())
        let postsBox = LockedBox<[String]>([])
        let enabledBox = LockedBox(true)
        let latestBox = LockedBox(latest)
        let installCallsBox = LockedBox(0)
        let restartCallsBox = LockedBox(0)
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
            now: { 1_000_000 },
            fetchLatest: { latestBox.withLock { $0 } },
            readMeta: { metaBox.withLock { $0 } },
            writeMeta: { patch in
                metaBox.withLock { m in
                    if let t = patch.lastCheckAt { m.lastCheckAt = t }
                    if let d = patch.dismissedVersion { m.dismissedVersion = d }
                }
            },
            postPrompt: { v in postsBox.withLock { $0.append(v) } },
            announce: { _ in },
            install: install,
            restart: { restartCallsBox.withLock { $0 += 1 } },
            messages: .korean,
            onLog: { _ in }
        )
        self.updater = AutoUpdater(deps: deps)
        self.metaBox = metaBox
        self.postsBox = postsBox
        self.enabledBox = enabledBox
        self.installCallsBox = installCallsBox
        self.restartCallsBox = restartCallsBox
    }
}
