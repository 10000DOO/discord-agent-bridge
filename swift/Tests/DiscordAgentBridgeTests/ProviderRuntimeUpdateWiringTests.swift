import Foundation
import Testing
@testable import DiscordAgentBridge
@testable import dab

@Suite("Provider runtime update wiring safety")
struct ProviderRuntimeUpdateWiringTests {
    @Test func timedOutCommandReturnsWithoutWaitingForPipeEOF() {
        let started = Date()
        let result = runRuntimeCommand("/bin/sleep", args: ["30"], timeout: 0.05)

        #expect(result.timedOut)
        #expect(!result.ok)
        #expect(Date().timeIntervalSince(started) < 4.5)
    }

    @Test func timedOutCommandKillsDescendantsBeforeReturning() throws {
        let root = try makeDirectory(prefix: "dab-runtime-descendant")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("late-write")
        let script = "import os, time; child = os.fork(); (time.sleep(0.3), open('\(marker.path)', 'w').write('leaked'), os._exit(0)) if child == 0 else time.sleep(30)"

        let result = runRuntimeCommand("/usr/bin/python3", args: ["-c", script], timeout: 0.05)

        #expect(result.timedOut)
        #expect(result.descendantsExited)
        usleep(500_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func rollbackRestoresEveryPromotedArtifactAndConsumesBackup() throws {
        let root = try makeDirectory(prefix: "dab-runtime-root")
        let backup = try makeDirectory(prefix: "dab-runtime-backup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: backup)
        }
        let targets = ["package.json", "package-lock.json", "node_modules"]
        for target in targets {
            let old = backup.appendingPathComponent(target)
            let new = root.appendingPathComponent(target)
            if target == "node_modules" {
                try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
                try "old".write(to: old.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
                try "new".write(to: new.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            } else {
                try "old".write(to: old, atomically: true, encoding: .utf8)
                try "new".write(to: new, atomically: true, encoding: .utf8)
            }
        }

        #expect(rollbackClaudePromotion(root: root, backup: backup, targets: targets) == nil)
        for target in targets {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(target).path))
            #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent(target).path))
        }
        #expect(try String(contentsOf: root.appendingPathComponent("node_modules/marker")) == "old")
    }

    @Test func startupRecoveryRollsBackCrashMidPromotionFromDurableJournal() throws {
        let root = try makeDirectory(prefix: "dab-runtime-crash")
        let backup = root.appendingPathComponent(".dab-provider-runtime-backup-crash")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for target in claudePromotionTargets {
            let old = backup.appendingPathComponent(target)
            if target == "node_modules" {
                try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
                try "old".write(to: old.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            } else {
                try "old".write(to: old, atomically: true, encoding: .utf8)
            }
        }
        // Simulate a kill after package.json promotion but before the remaining staged moves.
        try "new".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true
        )
        try "new".write(
            to: root.appendingPathComponent("node_modules/marker"), atomically: true, encoding: .utf8
        )
        try writeClaudeTransactionJournal(root: root, backup: backup, targets: claudePromotionTargets)

        #expect(recoverClaudeRuntimeTransactionIfNeeded(root: root) == .recovered)
        #expect(try String(contentsOf: root.appendingPathComponent("package.json")) == "old")
        #expect(try String(contentsOf: root.appendingPathComponent("package-lock.json")) == "old")
        #expect(try String(contentsOf: root.appendingPathComponent("node_modules/marker")) == "old")
        #expect(!FileManager.default.fileExists(atPath: claudeTransactionJournalURL(root: root).path))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func reconnectWaitsForInProgressCheckBeforeRecoveringTransactionJournal() async throws {
        let root = try makeDirectory(prefix: "dab-runtime-reconnect")
        let backup = root.appendingPathComponent(".dab-provider-runtime-backup-live")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for target in claudePromotionTargets {
            let old = backup.appendingPathComponent(target)
            if target == "node_modules" {
                try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
                try "old".write(to: old.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            } else {
                try "old".write(to: old, atomically: true, encoding: .utf8)
            }
        }
        try "new".write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "new".write(to: root.appendingPathComponent("node_modules/marker"), atomically: true, encoding: .utf8)
        try writeClaudeTransactionJournal(root: root, backup: backup, targets: claudePromotionTargets)

        let pause = RuntimeCheckPause()
        let registry = ProviderRuntimeUpdateRegistry()
        let active = ProviderRuntimeUpdateCoordinator(deps: ProviderRuntimeUpdateCoordinatorDeps(
            enabled: { true },
            intervalMs: 60_000,
            beginMaintenance: { true },
            endMaintenance: {},
            updateClaude: {
                await pause.pause()
                return ProviderRuntimeUpdateItem(provider: .claude, status: .updated)
            },
            updateCodex: { ProviderRuntimeUpdateItem(provider: .codex, status: .updated) },
            updateGrok: { ProviderRuntimeUpdateItem(provider: .grok, status: .updated) }
        ))
        let replacement = ProviderRuntimeUpdateCoordinator(deps: ProviderRuntimeUpdateCoordinatorDeps(
            enabled: { false },
            intervalMs: 60_000,
            beginMaintenance: { true },
            endMaintenance: {},
            updateClaude: { ProviderRuntimeUpdateItem(provider: .claude, status: .disabled) },
            updateCodex: { ProviderRuntimeUpdateItem(provider: .codex, status: .disabled) },
            updateGrok: { ProviderRuntimeUpdateItem(provider: .grok, status: .disabled) }
        ))
        let initialStart = Task { await registry.startReplacing(with: active) }
        await pause.waitUntilEntered()

        let recovery = LockedBox<ClaudeRuntimeTransactionRecovery?>(nil)
        let reconnect = Task {
            await registry.replaceAfterCurrentCheck(with: replacement) {
                recovery.withLock { $0 = recoverClaudeRuntimeTransactionIfNeeded(root: root) }
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(recovery.withLock { $0 } == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("package.json")) == "new")

        await pause.release()
        await initialStart.value
        await reconnect.value
        #expect(recovery.withLock { $0 } == .recovered)
        #expect(try String(contentsOf: root.appendingPathComponent("package.json")) == "old")
    }

    @Test func codexFailedUpdateRestoresManagedPackageSnapshot() async throws {
        let fixture = try makeManagedCodexInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = LockedBox<[[String]]>([])
        let runner: RuntimeCommandRunner = { _, args, _, _ in
            calls.withLock { $0.append(args) }
            switch args {
            case ["--version"]:
                let marker = (try? String(contentsOf: fixture.executable)) ?? "missing"
                return RuntimeCommandResult(code: 0, output: "codex-cli \(marker == "old" ? "1.0.0" : "2.0.0")", timedOut: false)
            case ["--help"]:
                return RuntimeCommandResult(code: 0, output: "Codex help", timedOut: false)
            case ["update"]:
                try? "new".write(to: fixture.executable, atomically: true, encoding: .utf8)
                return RuntimeCommandResult(code: 1, output: "simulated update failure", timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }

        let result = await updateCodexRuntime(
            binary: fixture.shim.path,
            stateRoot: fixture.root.appendingPathComponent("state"),
            command: runner,
            catalogHealthy: { true },
            baseline: SpawnedRuntimeVersions([:])
        )

        #expect(result.status == .failed)
        #expect(try String(contentsOf: fixture.executable) == "old")
        #expect(fixture.shim.resolvingSymlinksInPath().standardizedFileURL == fixture.executable.standardizedFileURL)
        #expect(calls.withLock { $0 }.contains(["update"]))
    }

    @Test func codexManagedUpdatePassesSmokeAndReportsUpdated() async throws {
        let fixture = try makeManagedCodexInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let restarted = LockedBox(false)
        let runner: RuntimeCommandRunner = { _, args, _, _ in
            switch args {
            case ["--version"]:
                let marker = (try? String(contentsOf: fixture.executable)) ?? "missing"
                return RuntimeCommandResult(code: 0, output: "codex-cli \(marker == "old" ? "1.0.0" : "2.0.0")", timedOut: false)
            case ["--help"]:
                return RuntimeCommandResult(code: 0, output: "Codex help", timedOut: false)
            case ["update"]:
                try? "new".write(to: fixture.executable, atomically: true, encoding: .utf8)
                return RuntimeCommandResult(code: 0, output: "updated", timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }

        let result = await updateCodexRuntime(
            binary: fixture.shim.path,
            stateRoot: fixture.root.appendingPathComponent("state"),
            command: runner,
            catalogHealthy: { true },
            restartRuntime: {
                restarted.withLock { $0 = true }
                return true
            },
            baseline: SpawnedRuntimeVersions([:])
        )

        #expect(result.status == .updated)
        #expect(result.version == "codex-cli 2.0.0")
        #expect(restarted.withLock { $0 })
        #expect(try String(contentsOf: fixture.executable) == "new")
    }

    @Test func codexStartupRecoveryRestoresDurableSnapshotOutsideNpmTree() throws {
        let fixture = try makeManagedCodexInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stateRoot = fixture.root.appendingPathComponent("state")
        let install = try #require(managedCodexInstall(binary: fixture.shim.path))
        let snapshot = try snapshotManagedCodexInstall(install, stateRoot: stateRoot)
        try "new".write(to: fixture.executable, atomically: true, encoding: .utf8)
        try writeCodexTransactionJournal(stateRoot: stateRoot, install: install, snapshot: snapshot)

        #expect(recoverCodexRuntimeTransactionIfNeeded(stateRoot: stateRoot) == .recovered)
        #expect(try String(contentsOf: fixture.executable) == "old")
        #expect(!FileManager.default.fileExists(atPath: codexTransactionJournalURL(stateRoot: stateRoot).path))
        #expect(snapshot.backupDirectory.deletingLastPathComponent().standardizedFileURL == stateRoot.standardizedFileURL)
    }

    @Test func updateDoesNotRestoreWhileCommandContainmentIsUnverified() async throws {
        let fixture = try makeManagedCodexInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stateRoot = fixture.root.appendingPathComponent("state")
        let runner: RuntimeCommandRunner = { _, args, _, _ in
            if args == ["--version"] {
                return RuntimeCommandResult(code: 0, output: "codex-cli 1.0.0", timedOut: false)
            }
            if args == ["update"] {
                try? "new".write(to: fixture.executable, atomically: true, encoding: .utf8)
                return RuntimeCommandResult(code: -1, output: "descendant still running", timedOut: true, descendantsExited: false)
            }
            return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
        }

        let result = await updateCodexRuntime(binary: fixture.shim.path, stateRoot: stateRoot, command: runner, catalogHealthy: { true }, baseline: SpawnedRuntimeVersions([:]))

        #expect(result.status == .failed)
        #expect(try String(contentsOf: fixture.executable) == "new")
        #expect(FileManager.default.fileExists(atPath: codexTransactionJournalURL(stateRoot: stateRoot).path))
    }

    @Test func grokBrokenUpdateRestoresCapturedManagedDownloadAndShim() async throws {
        let fixture = try makeManagedGrokInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = LockedBox<[[String]]>([])
        let runner: RuntimeCommandRunner = { _, args, _, _ in
            calls.withLock { $0.append(args) }
            switch args {
            case ["--version"]:
                let marker = (try? String(contentsOf: fixture.shim.resolvingSymlinksInPath())) ?? "missing"
                return RuntimeCommandResult(code: 0, output: "grok \(marker == "old" ? "0.2.114" : "0.2.115") (build) [stable]", timedOut: false)
            case ["--help"]:
                return RuntimeCommandResult(code: 0, output: "Grok help", timedOut: false)
            case ["update"]:
                try? "new".write(to: fixture.shim.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
                return RuntimeCommandResult(code: 0, output: "updated", timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }

        let result = await updateGrokRuntime(
            binary: fixture.shim.path,
            homeDirectory: fixture.home,
            stateRoot: fixture.root.appendingPathComponent("state"),
            command: runner,
            catalogHealthy: { true },
            restartRuntime: { false },
            baseline: SpawnedRuntimeVersions([:])
        )

        #expect(result.status == .failed)
        #expect(try String(contentsOf: fixture.shim.resolvingSymlinksInPath()) == "old")
        #expect(!calls.withLock { $0 }.contains(["update", "--version", "0.2.114"]))
    }

    @Test func grokStartupRecoveryRestoresDurableSnapshotOutsideDownloadTree() throws {
        let fixture = try makeManagedGrokInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stateRoot = fixture.root.appendingPathComponent("state")
        let install = try #require(managedGrokInstall(binary: fixture.shim.path, homeDirectory: fixture.home))
        let snapshot = try snapshotManagedGrokInstall(install, stateRoot: stateRoot)
        try "new".write(to: install.download, atomically: true, encoding: .utf8)
        try writeGrokTransactionJournal(stateRoot: stateRoot, install: install, snapshot: snapshot)

        #expect(recoverGrokRuntimeTransactionIfNeeded(stateRoot: stateRoot) == .recovered)
        #expect(try String(contentsOf: install.download) == "old")
        #expect(!FileManager.default.fileExists(atPath: grokTransactionJournalURL(stateRoot: stateRoot).path))
        #expect(snapshot.backupDirectory.deletingLastPathComponent().standardizedFileURL == stateRoot.standardizedFileURL)
    }

    /// An hourly no-op check must leave live ACP children alone: dropping them costs the channel a
    /// `session/load` round trip and a failed resume is surfaced to the user.  A version that changed
    /// behind our back (Grok's own background updater) must still force the restart.
    @Test func upToDateChecksRestartOnlyWhenTheOnDiskVersionChanged() async throws {
        let fixture = try makeManagedGrokInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baseline = SpawnedRuntimeVersions([:])
        let restarts = LockedBox(0)
        let reported = LockedBox("0.2.117")
        let runner: RuntimeCommandRunner = { _, args, _, _ in
            switch args {
            case ["--version"]:
                return RuntimeCommandResult(code: 0, output: "grok \(reported.withLock { $0 }) (abc)", timedOut: false)
            case ["--help"]:
                return RuntimeCommandResult(code: 0, output: "Grok help", timedOut: false)
            case ["update", "--check", "--json"]:
                return RuntimeCommandResult(code: 0, output: #"{"updateAvailable":false}"#, timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }
        func check() async -> ProviderRuntimeUpdateItem {
            await updateGrokRuntime(binary: fixture.shim.path, homeDirectory: fixture.home, stateRoot: fixture.root.appendingPathComponent("state"), command: runner, catalogHealthy: { true }, restartRuntime: { restarts.withLock { $0 += 1 }; return true }, baseline: baseline)
        }

        #expect(await check().status == .upToDate)
        #expect(await check().status == .upToDate)
        #expect(restarts.withLock { $0 } == 0)

        // Grok's internal updater swapped the binary between checks.
        reported.withLock { $0 = "0.2.118" }
        #expect(await check().status == .upToDate)
        #expect(restarts.withLock { $0 } == 1)
        #expect(await check().status == .upToDate)
        #expect(restarts.withLock { $0 } == 1)
    }

    /// A self-update keeps predecessor and successor alive at once; the second must not read the
    /// first's live transaction journal as an interrupted one.
    @Test func maintenanceLockIsExclusiveAcrossHolders() async throws {
        let stateRoot = try makeDirectory(prefix: "dab-runtime-lock")
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        #expect(await ProviderRuntimeMaintenanceLock.shared.acquire(stateRoot: stateRoot))

        // A separate descriptor is what another dab process would hold.
        let rival = open(stateRoot.appendingPathComponent("maintenance.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(rival >= 0)
        #expect(flock(rival, LOCK_EX | LOCK_NB) != 0)

        await ProviderRuntimeMaintenanceLock.shared.release()
        #expect(flock(rival, LOCK_EX | LOCK_NB) == 0)
        flock(rival, LOCK_UN)
        close(rival)
    }

    /// A kill between the promotion renames orphans a staged tree whose `defer` cleanup never ran.
    @Test func startupSweepReclaimsOrphanedStageDirectoriesOnly() throws {
        let root = try makeDirectory(prefix: "dab-runtime-sweep")
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(".dab-provider-runtime-stage-abc")
        let backup = root.appendingPathComponent(".dab-provider-runtime-backup-abc")
        let unrelated = root.appendingPathComponent("node_modules")
        for dir in [orphan, backup, unrelated] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        #expect(sweepOrphanedClaudeStages(root: root) == 1)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        // A backup is the rollback authority a retained journal points at — never sweep it.
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// An hourly no-op check must not copy the 120MB+ release just to throw the copy away.
    @Test func grokAlreadyCurrentSkipsSnapshotAndUpdate() async throws {
        let fixture = try makeManagedGrokInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stateRoot = fixture.root.appendingPathComponent("state")
        let calls = LockedBox<[[String]]>([])
        let runner: RuntimeCommandRunner = { _, args, _, _ in
            calls.withLock { $0.append(args) }
            switch args {
            case ["--version"]:
                return RuntimeCommandResult(code: 0, output: "grok 0.2.117 (f1c0609) [stable]", timedOut: false)
            case ["--help"]:
                return RuntimeCommandResult(code: 0, output: "Grok help", timedOut: false)
            case ["update", "--check", "--json"]:
                return RuntimeCommandResult(code: 0, output: #"{"currentVersion":"0.2.117","latestVersion":"0.2.117","updateAvailable":false}"#, timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }

        let result = await updateGrokRuntime(binary: fixture.shim.path, homeDirectory: fixture.home, stateRoot: stateRoot, command: runner, catalogHealthy: { true }, restartRuntime: { true }, baseline: SpawnedRuntimeVersions([:]))

        #expect(result.status == .upToDate)
        #expect(result.version == "0.2.117")
        #expect(!calls.withLock { $0 }.contains(["update"]))
        #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
    }

    /// x.ai's install.sh drops `~/.local/bin/grok` alongside `~/.grok/bin/grok`, and the launchd PATH
    /// finds that one first — the managed check must still anchor on the shim `grok update` rewrites.
    @Test func grokInstallStaysManagedWhenPathResolvesAnIndirectionShim() throws {
        let fixture = try makeManagedGrokInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let localBin = fixture.home.appendingPathComponent(".local/bin/grok")
        try FileManager.default.createDirectory(at: localBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: localBin.path, withDestinationPath: fixture.shim.path)

        let install = try #require(managedGrokInstall(binary: localBin.path, homeDirectory: fixture.home))

        #expect(install.shim.standardizedFileURL == fixture.shim.standardizedFileURL)
        #expect(install.download.lastPathComponent == "grok-0.2.114-macos-aarch64")
    }

    /// Same indirection hazard for a global npm install reached through `~/.local/bin/codex`.
    @Test func codexInstallStaysManagedWhenPathResolvesAnIndirectionShim() throws {
        let fixture = try makeManagedCodexInstall()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let localBin = fixture.root.appendingPathComponent("local/bin/codex")
        try FileManager.default.createDirectory(at: localBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: localBin.path, withDestinationPath: fixture.shim.path)

        let install = try #require(managedCodexInstall(binary: localBin.path))

        #expect(install.shim.standardizedFileURL == fixture.shim.standardizedFileURL)
        #expect(install.packageDirectory.lastPathComponent == "codex")
    }

    /// Homebrew cask layout: `<prefix>/bin/<name>` symlinks into a Caskroom version directory, and
    /// `brew` — not the CLI's own updater — owns the upgrade.
    @Test func homebrewCaskCodexUpgradesThroughBrewAndRelinksOnFailure() async throws {
        let fixture = try makeHomebrewCask(token: "codex", binary: "codex", version: "0.145.0")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = LockedBox<[[String]]>([])
        let runner: RuntimeCommandRunner = { command, args, _, _ in
            calls.withLock { $0.append([command] + args) }
            switch (command, args) {
            case (_, ["--version"]):
                let marker = (try? String(contentsOf: fixture.shim.resolvingSymlinksInPath())) ?? "missing"
                return RuntimeCommandResult(code: 0, output: marker == "old" ? "0.145.0" : "0.146.0", timedOut: false)
            case (_, ["--help"]):
                return RuntimeCommandResult(code: 0, output: "Codex help", timedOut: false)
            case ("brew", ["outdated", "--cask", "--quiet", "codex"]):
                return RuntimeCommandResult(code: 0, output: "codex", timedOut: false)
            case ("brew", ["upgrade", "--cask", "codex"]):
                // brew installs a new keg beside the old one and relinks the shim.
                try? FileManager.default.createDirectory(at: fixture.newKeg.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "new".write(to: fixture.newKeg, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: fixture.shim)
                try? FileManager.default.createSymbolicLink(atPath: fixture.shim.path, withDestinationPath: fixture.newKeg.path)
                return RuntimeCommandResult(code: 0, output: "upgraded", timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }

        let install = try #require(managedShimInstall(
            provider: .codex,
            binary: fixture.shim.path,
            candidates: [ShimLayoutCandidate(shim: fixture.shim, payloadRoot: fixture.caskroom, owner: .homebrewCask(token: "codex"))]
        ))
        // Health fails after the upgrade → the shim must go back to the old keg.
        let result = await updateShimRuntime(
            install: install,
            stateRoot: fixture.root.appendingPathComponent("state"),
            command: runner,
            binary: fixture.shim.path,
            parseVersion: { $0 },
            catalogHealthy: { false },
            restartRuntime: { true },
            baseline: SpawnedRuntimeVersions([:])
        )

        #expect(result.status == .failed)
        #expect(calls.withLock { $0 }.contains(["brew", "upgrade", "--cask", "codex"]))
        #expect(try String(contentsOf: fixture.shim.resolvingSymlinksInPath()) == "old")
    }

    /// `brew outdated` says nothing is newer → no upgrade, no snapshot, and live children stay up.
    @Test func homebrewCaskCurrentSkipsUpgradeEntirely() async throws {
        let fixture = try makeHomebrewCask(token: "claude-code", binary: "claude", version: "2.1.212")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = LockedBox<[[String]]>([])
        let restarts = LockedBox(0)
        let runner: RuntimeCommandRunner = { command, args, _, _ in
            calls.withLock { $0.append([command] + args) }
            switch (command, args) {
            case (_, ["--version"]):
                return RuntimeCommandResult(code: 0, output: "2.1.212 (Claude Code)", timedOut: false)
            case (_, ["--help"]):
                return RuntimeCommandResult(code: 0, output: "Claude help", timedOut: false)
            case ("brew", ["outdated", "--cask", "--quiet", "claude-code"]):
                return RuntimeCommandResult(code: 0, output: "", timedOut: false)
            default:
                return RuntimeCommandResult(code: 1, output: "unexpected", timedOut: false)
            }
        }
        let install = try #require(managedShimInstall(
            provider: .claude,
            binary: fixture.shim.path,
            candidates: [ShimLayoutCandidate(shim: fixture.shim, payloadRoot: fixture.caskroom, owner: .homebrewCask(token: "claude-code"))]
        ))

        let result = await updateShimRuntime(
            install: install, stateRoot: fixture.root.appendingPathComponent("state"), command: runner,
            binary: fixture.shim.path, parseVersion: claudeCliVersion, catalogHealthy: { true },
            restartRuntime: { restarts.withLock { $0 += 1 }; return true }, baseline: SpawnedRuntimeVersions([:])
        )

        #expect(result.status == .upToDate)
        #expect(result.version == "2.1.212")
        #expect(!calls.withLock { $0 }.contains(["brew", "upgrade", "--cask", "claude-code"]))
        #expect(restarts.withLock { $0 } == 0)
    }

    /// The native installer layout the Claude CLI migrates itself to: `~/.local/bin/claude` →
    /// `~/.local/share/claude/versions/<version>`, updated by `claude update`.
    @Test func nativeClaudeCliInstallIsManagedAndSelfUpdated() async throws {
        let home = try makeDirectory(prefix: "dab-claude-native")
        defer { try? FileManager.default.removeItem(at: home) }
        let payload = home.appendingPathComponent(".local/share/claude/versions/2.1.220")
        try FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: payload, atomically: true, encoding: .utf8)
        let shim = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shim.path, withDestinationPath: payload.path)

        let install = try #require(managedShimInstall(
            provider: .claude,
            binary: shim.path,
            candidates: [ShimLayoutCandidate(
                shim: shim,
                payloadRoot: home.appendingPathComponent(".local/share/claude/versions"),
                owner: .selfManaged
            )]
        ))

        #expect(install.owner == .selfManaged)
        #expect(install.payload.lastPathComponent == "2.1.220")
        #expect(claudeCliVersion("2.1.220 (Claude Code)") == "2.1.220")
        #expect(claudeCliVersion("Claude Code") == nil)
    }

    /// `claude-code` puts its bin entry at the package ROOT (`cli.js`), not in `bin/` — the npm
    /// detector must not assume Codex's depth.
    @Test func npmGlobalDetectorHandlesBothBinDepths() throws {
        let root = try makeDirectory(prefix: "dab-npm-depth")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("lib/node_modules/@anthropic-ai/claude-code/cli.js")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: executable, atomically: true, encoding: .utf8)
        let shim = root.appendingPathComponent("bin/claude")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shim.path, withDestinationPath: "../lib/node_modules/@anthropic-ai/claude-code/cli.js")

        let install = try #require(managedNpmGlobalInstall(binary: shim.path, package: .claudeCode))

        #expect(install.packageDirectory.lastPathComponent == "claude-code")
        #expect(install.shim.standardizedFileURL == shim.standardizedFileURL)
        // A Codex lookup must not match a Claude Code tree.
        #expect(managedNpmGlobalInstall(binary: shim.path, package: .codex) == nil)
    }

    /// A cask keg lives beside the old one, so a crashed upgrade is undone by relinking alone.
    @Test func shimStartupRecoveryRelinksThePreviousPayload() throws {
        let fixture = try makeHomebrewCask(token: "codex", binary: "codex", version: "0.145.0")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let stateRoot = fixture.root.appendingPathComponent("state")
        let install = ManagedShimInstall(provider: .codex, shim: fixture.shim, payload: fixture.keg, owner: .homebrewCask(token: "codex"))
        try writeShimTransactionJournal(stateRoot: stateRoot, install: install)
        // Simulate the crash: the shim already points at the new keg.
        try FileManager.default.createDirectory(at: fixture.newKeg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "new".write(to: fixture.newKeg, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.shim)
        try FileManager.default.createSymbolicLink(atPath: fixture.shim.path, withDestinationPath: fixture.newKeg.path)

        #expect(recoverShimRuntimeTransactionIfNeeded(provider: .codex, stateRoot: stateRoot) == .recovered)
        #expect(try String(contentsOf: fixture.shim.resolvingSymlinksInPath()) == "old")
        #expect(!FileManager.default.fileExists(atPath: shimTransactionJournalURL(stateRoot: stateRoot, provider: .codex).path))
    }

    private func makeHomebrewCask(token: String, binary: String, version: String) throws -> (root: URL, shim: URL, caskroom: URL, keg: URL, newKeg: URL) {
        let root = try makeDirectory(prefix: "dab-brew-\(token)")
        let caskroom = root.appendingPathComponent("Caskroom/\(token)")
        let keg = caskroom.appendingPathComponent("\(version)/\(binary)-payload")
        try FileManager.default.createDirectory(at: keg.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: keg, atomically: true, encoding: .utf8)
        let shim = root.appendingPathComponent("bin/\(binary)")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shim.path, withDestinationPath: keg.path)
        let newKeg = caskroom.appendingPathComponent("9.9.9/\(binary)-payload")
        return (root, shim, caskroom, keg, newKeg)
    }

    private func makeDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeManagedCodexInstall() throws -> (root: URL, shim: URL, executable: URL) {
        let root = try makeDirectory(prefix: "dab-codex-managed")
        let executable = root.appendingPathComponent("lib/node_modules/@openai/codex/bin/codex.js")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: executable, atomically: true, encoding: .utf8)
        let shim = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shim.path, withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
        return (root, shim, executable)
    }

    private func makeManagedGrokInstall() throws -> (root: URL, home: URL, shim: URL) {
        let root = try makeDirectory(prefix: "dab-grok-managed")
        let home = root.appendingPathComponent("home")
        let binary = home.appendingPathComponent(".grok/downloads/grok-0.2.114-macos-aarch64")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: binary, atomically: true, encoding: .utf8)
        let shim = home.appendingPathComponent(".grok/bin/grok")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shim.path, withDestinationPath: "../downloads/grok-0.2.114-macos-aarch64")
        return (root, home, shim)
    }

    // A Homebrew keg owns its own `libexec/node_modules`, so the in-place SDK staging must never
    // start there — `brew upgrade dab` replaces the whole keg. Before this branch existed the
    // Homebrew path fell through to `findRepoRoot()`, which searches upward from the process cwd
    // (`/` under `brew services`) and therefore failed on literally every run, logging
    // "Claude project root not found" every check forever.
    @Test func homebrewInstallReportsSdkUnmanagedInsteadOfFailing() {
        let item = claudeSdkRuntimeUnmanagedReason(env: ["DAB_INSTALL_METHOD": "homebrew"])

        #expect(item?.status == .unsupported)
        #expect(item?.provider == .claude)
        #expect(item?.detail?.contains("brew upgrade dab") == true)
    }

    // The source install still owns its checkout, so a missing repo root there is a real failure
    // and must keep reaching the existing `.failed` branch.
    @Test func sourceInstallLeavesSdkRuntimeCheckAlone() {
        #expect(claudeSdkRuntimeUnmanagedReason(env: [:]) == nil)
        #expect(claudeSdkRuntimeUnmanagedReason(env: ["DAB_INSTALL_METHOD": "source"]) == nil)
    }
}

private actor RuntimeCheckPause {
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
