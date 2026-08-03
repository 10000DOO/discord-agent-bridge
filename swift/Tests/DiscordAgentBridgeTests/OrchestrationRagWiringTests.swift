import Foundation
import Testing
@testable import DiscordAgentBridge

/// WO-14 integration test (docs/project-rag-generic-indexing.md §6 WO-14, 3-2(A)/D13): exercises
/// the exact call sequence `DabMain.swift`'s `case "orchestration"` performs —
/// `ProjectRagCoordinator.ensureIndexed` BEFORE `SessionLifecycle.enableOrchestrationMode`, with
/// the ensure result's `projectRagEnabled` threaded straight into the rebind call — using the real
/// production types instead of a mock, since both are directly constructible/testable without any
/// Discord dependency.
@Suite("Orchestration RAG wiring (WO-14)")
struct OrchestrationRagWiringTests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-rag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func tempAudit() -> AuditLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-rag-audit-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl", isDirectory: false)
        return AuditLog(fileURL: url, now: { "T" })
    }

    @Test func ensureIndexedResultReachesEnableOrchestrationModeBeforeSessionRebind() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "print(1)".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        // Same 3-profile list DabMain.swift's "orchestration" case assembles (P10/D1).
        let profiles: [ProjectRagProfile] = [
            GenericFileGraphProfile(), AppleNativeProfile(), TypescriptNodeProfile(),
        ]
        let coordinator = ProjectRagCoordinator(refreshIntervalNs: 20_000_000, backoffStepsNs: [10_000_000])
        let key = ProjectRagCoordinator.projectKey(for: root)
        defer { Task { await coordinator.cancelScheduler(key: key) } }

        let notified = LockedBox<[String]>([])
        let ragResult = await coordinator.ensureIndexed(
            root: root, initiator: "c1", profiles: profiles,
            notify: { text in notified.withLock { $0.append(text) } }
        )

        // `.dab-index/CURRENT` must exist once ensureIndexed completes (§7 layout).
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".dab-index/CURRENT").path))
        #expect(ragResult.projectRagEnabled == true)
        #expect(notified.withLock { $0 }.last == I18n.t("orchestration.project.ragReady"))

        // Same session fixture shape as SessionLifecycleTests' enableOrchestrationMode coverage.
        let reg = SessionRegistry()
        let store = freshTempStore()
        await reg.bind(channelId: "c1", SessionConfig(backend: .claude))
        try await store.upsert(
            channelId: "c1",
            PersistedSession(backend: .claude, cwd: root.path, guildId: "g", updatedAt: "t0")
        )
        let life = SessionLifecycle(
            registry: reg, store: store, audit: tempAudit(),
            stopClaude: { _ in }, stopCodex: { _ in }, stopGrok: { _ in },
            interruptClaude: { _ in false }, interruptCodex: { _ in false }, interruptGrok: { _ in false }
        )

        // Mirrors DabMain.swift's `case "orchestration"`: enableOrchestrationMode is only called
        // AFTER ensureIndexed, threading its result straight through (D13/Q3) — the session must
        // never rebind with a stale/false projectRagEnabled.
        let enabled = await life.enableOrchestrationMode(
            channelId: "c1", actorId: "u", guildId: "g", defaultCwd: root.path,
            projectRagEnabled: ragResult.projectRagEnabled
        )
        #expect(enabled == true)
        #expect(await store.binding(channelId: "c1")?.projectRagEnabled == true)
        #expect(await reg.binding(channelId: "c1")?.projectRagEnabled == true)
    }
}
