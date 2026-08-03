import Foundation
import Testing
@testable import DiscordAgentBridge

/// Counts `discover()` invocations across concurrent/serial `ensureIndexed` calls so tests can
/// assert how many real builds actually happened without reaching into `ProjectRagCoordinator`
/// internals (mirrors `RedminePollerTests`'s `LockedBox`-based call counting).
private struct CountingStubProfile: ProjectRagProfile {
    let id: String
    let version: Int
    let score: Int
    let calls: LockedBox<Int>
    var delayNs: UInt64 = 0

    func matches(root: URL, files: [ProjectFileRecord]) -> Int { score }
    func discover(root: URL, files: [ProjectFileRecord]) async throws -> ProfileDiscovery {
        calls.withLock { $0 += 1 }
        if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
        return ProfileDiscovery()
    }
}

private func tempProjectRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-rag-coordinator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("ProjectRagCoordinator")
struct ProjectRagCoordinatorTests {
    /// Very short intervals so scheduler-loop assertions don't wait on the real 1h/5m/15m/60m ones.
    private func testCoordinator() -> ProjectRagCoordinator {
        ProjectRagCoordinator(refreshIntervalNs: 20_000_000, backoffStepsNs: [10_000_000])
    }

    @Test func concurrentEnsureIndexedSharesOneBuild() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "content".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let calls = LockedBox(0)
        let profiles: [ProjectRagProfile] = [
            CountingStubProfile(id: "generic-file-graph", version: 1, score: 10, calls: calls, delayNs: 150_000_000),
        ]
        let coordinator = testCoordinator()
        let key = ProjectRagCoordinator.projectKey(for: root)
        defer { Task { await coordinator.cancelScheduler(key: key) } }

        async let first = coordinator.ensureIndexed(root: root, initiator: "a", profiles: profiles, notify: { _ in })
        async let second = coordinator.ensureIndexed(root: root, initiator: "b", profiles: profiles, notify: { _ in })
        let (r1, r2) = await (first, second)

        #expect(r1.freshness == .fresh)
        #expect(r2.freshness == .fresh)
        #expect(r1.projectRagEnabled)
        #expect(r2.projectRagEnabled)
        #expect(calls.withLock { $0 } == 1, "two concurrent ensureIndexed calls for the same root must share a single build")
    }

    @Test func secondEnsureIndexedSkipsRebuildWhenFresh() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "content".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let calls = LockedBox(0)
        let profiles: [ProjectRagProfile] = [CountingStubProfile(id: "generic-file-graph", version: 1, score: 10, calls: calls)]
        let coordinator = testCoordinator()
        let key = ProjectRagCoordinator.projectKey(for: root)
        defer { Task { await coordinator.cancelScheduler(key: key) } }

        let notified = LockedBox<[String]>([])
        let notify: @Sendable (String) async -> Void = { text in notified.withLock { $0.append(text) } }

        let first = await coordinator.ensureIndexed(root: root, initiator: "a", profiles: profiles, notify: notify)
        #expect(first.freshness == .fresh)
        #expect(calls.withLock { $0 } == 1)
        #expect(notified.withLock { $0 }.last == I18n.t("orchestration.project.ragReady"))

        let second = await coordinator.ensureIndexed(root: root, initiator: "a", profiles: profiles, notify: notify)
        #expect(second.freshness == .fresh)
        #expect(calls.withLock { $0 } == 1, "second call on an unchanged project must not rebuild")
        #expect(notified.withLock { $0 }.last == I18n.t("orchestration.project.ragReadyFresh"))
    }

    @Test func rescheduleCancelsPreviousSchedulerLeavingOnlyOneAlive() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "content".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let calls = LockedBox(0)
        let profiles: [ProjectRagProfile] = [CountingStubProfile(id: "generic-file-graph", version: 1, score: 10, calls: calls)]
        let coordinator = testCoordinator()
        let key = ProjectRagCoordinator.projectKey(for: root)
        defer { Task { await coordinator.cancelScheduler(key: key) } }

        _ = await coordinator.ensureIndexed(root: root, initiator: "a", profiles: profiles, notify: { _ in })
        let firstScheduler = try #require(await coordinator.schedulerTaskForTesting(key: key))

        _ = await coordinator.ensureIndexed(root: root, initiator: "a", profiles: profiles, notify: { _ in })
        let secondScheduler = try #require(await coordinator.schedulerTaskForTesting(key: key))

        #expect(firstScheduler.isCancelled, "the superseded scheduler task must be cancelled, not left running")
        #expect(!secondScheduler.isCancelled)
    }

    // Regression: `computeSnapshot` (heavy synchronous file walk + hash, no await points) used to
    // run directly on the actor before the freshness check, so one project's scan blocked every
    // other project's `ensureIndexed` — not just same-project serialization (D2). `slowRoot` gets a
    // large fileset so its real scan reliably takes tens of ms; there's no test hook to fake a delay
    // since `computeSnapshot` (ProjectRagBuilder.swift) is pure and out of scope for this fix.
    @Test func slowComputeSnapshotForOneProjectDoesNotBlockAnother() async throws {
        let slowRoot = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: slowRoot) }
        let filler = Data(repeating: 0x78, count: 200)
        for i in 0..<4000 {
            try filler.write(to: slowRoot.appendingPathComponent("f\(i).txt"))
        }

        let fastRoot = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: fastRoot) }
        try "content".write(to: fastRoot.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let slowCalls = LockedBox(0)
        let fastCalls = LockedBox(0)
        let slowProfiles: [ProjectRagProfile] = [CountingStubProfile(id: "generic-file-graph", version: 1, score: 10, calls: slowCalls)]
        let fastProfiles: [ProjectRagProfile] = [CountingStubProfile(id: "generic-file-graph", version: 1, score: 10, calls: fastCalls)]

        let coordinator = testCoordinator()
        let slowKey = ProjectRagCoordinator.projectKey(for: slowRoot)
        let fastKey = ProjectRagCoordinator.projectKey(for: fastRoot)
        defer {
            Task { await coordinator.cancelScheduler(key: slowKey) }
            Task { await coordinator.cancelScheduler(key: fastKey) }
        }

        async let slow = coordinator.ensureIndexed(root: slowRoot, initiator: "slow", profiles: slowProfiles, notify: { _ in })
        // Grace period for the slow call's actor-isolated body to actually start running (and,
        // pre-fix, sit mid-`computeSnapshot`) before the fast call is even issued.
        try? await Task.sleep(nanoseconds: 20_000_000)

        let fastStart = Date()
        let fastResult = await coordinator.ensureIndexed(root: fastRoot, initiator: "fast", profiles: fastProfiles, notify: { _ in })
        let fastElapsedNs = UInt64(max(0, -fastStart.timeIntervalSinceNow) * 1_000_000_000)

        let slowResult = await slow

        #expect(slowResult.freshness == .fresh)
        #expect(fastResult.freshness == .fresh)
        // Pre-fix, `fastResult` couldn't start until the slow project's actor-blocking
        // computeSnapshot finished, so this would take roughly as long as the whole slow scan.
        #expect(fastElapsedNs < 100_000_000, "a different project's ensureIndexed must not wait on another project's computeSnapshot")
    }

    @Test func restoreSchedulersRegistersLoopWithoutBuilding() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "content".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let calls = LockedBox(0)
        let profiles: [ProjectRagProfile] = [CountingStubProfile(id: "generic-file-graph", version: 1, score: 10, calls: calls)]
        let coordinator = testCoordinator()
        let key = ProjectRagCoordinator.projectKey(for: root)
        defer { Task { await coordinator.cancelScheduler(key: key) } }

        await coordinator.restoreSchedulers(openProjects: [(projectKey: key, root: root, profiles: profiles)])

        #expect(await coordinator.schedulerTaskForTesting(key: key) != nil)
        #expect(calls.withLock { $0 } == 0, "restoring schedulers must never trigger a build")
    }
}
