import Crypto
import Foundation

/// Per-project build coalescing + hourly refresh scheduling for the project RAG feature (WO-12,
/// docs/project-rag-generic-indexing.md §6 WO-12). Mirrors `Redmine/RedminePoller.swift`'s
/// `Task.sleep` interval loop (P1) and `RedminePollerRegistry`'s `[key: ...]` dictionary (P2) —
/// but unlike that pair, `ProjectRagBuilder` carries no state of its own, so this is a single actor
/// holding one dictionary of per-project task handles instead of two separate types (D2).
///
/// Discord notifications are never sent from inside this actor — `ensureIndexed` takes a `notify`
/// closure instead, so this file has no Discord/DiscordBM import (actor purity, 3-3 "D-신규").
public actor ProjectRagCoordinator {
    public static let shared = ProjectRagCoordinator()

    /// Per-project in-memory bookkeeping: at most one build task and one scheduler task alive at
    /// any time (§4 "projectKey당 build/scheduler task가 2개 이상 동시 존재 금지").
    private struct ProjectRagState {
        var buildTask: Task<BuildOutcome, Never>?
        var schedulerTask: Task<Void, Never>?
    }

    /// What a (possibly shared) build task produced, so every caller joining it — not just the one
    /// that created it — can render its own `notify()` message.
    private struct BuildOutcome: Sendable {
        var manifest: ProjectRagManifest?
        var errorSummary: String?
    }

    private var states: [String: ProjectRagState] = [:]
    private let refreshIntervalNs: UInt64
    private let backoffStepsNs: [UInt64]

    public init() {
        self.refreshIntervalNs = 3600 * 1_000_000_000 // 1h (원 설계 §8.2, R4)
        self.backoffStepsNs = [300, 900, 3600].map { UInt64($0) * 1_000_000_000 } // 5m/15m/60m (WO-12 §3)
    }

    /// Test-only injection point — lets scheduler-loop tests use very short intervals instead of
    /// the real 1h/5m/15m/60m ones (WO-12 완료 판정 "Task.sleep 대신 매우 짧은 interval을 테스트 훅으로
    /// 주입"). Not `public`: production always goes through `.shared`, only `@testable` tests in
    /// this module construct a second instance directly.
    init(refreshIntervalNs: UInt64, backoffStepsNs: [UInt64]) {
        self.refreshIntervalNs = refreshIntervalNs
        self.backoffStepsNs = backoffStepsNs
    }

    // MARK: - ensureIndexed (3-2(A), WO-12 §2)

    public func ensureIndexed(
        root: URL,
        initiator: String,
        profiles: [ProjectRagProfile],
        notify: @Sendable (String) async -> Void
    ) async -> ProjectRagEnsureResult {
        await notify(I18n.t("orchestration.project.ragBuilding"))
        _ = ProjectRagStore.removeLegacyCacheIfPresent(root: root) // D11 — before any freshness check

        let key = Self.projectKey(for: root)

        let snapshot: ProjectRagSnapshot
        do {
            // ponytail: previousFiles always nil (full rehash every call) — `build()` itself
            // currently ignores its own `previousManifest` fast-path too (ProjectRagBuilder.swift),
            // so this matches present behavior rather than regressing it. Wire a
            // `ProjectRagStore` reader for the previous `files.ndjson` if large-project rehash cost
            // becomes a measured problem.
            // Task.detached — computeSnapshot is a heavy synchronous file walk + hash with no
            // await points; run it off the actor so one project's scan can't block every other
            // project's ensureIndexed/scheduler (D2 says "per-project serialization", not "one
            // shared execution window" — see docs/project-rag-generic-indexing.md §3 D2).
            snapshot = try await Task.detached(priority: .utility) {
                try computeSnapshot(root: root, previousFiles: nil)
            }.value
        } catch {
            let summary = "\(error)"
            await notify(I18n.t("orchestration.project.ragFailed", ["reason": summary]))
            return ProjectRagEnsureResult(freshness: .failed, projectRagEnabled: false, errorSummary: summary)
        }

        let identity = Self.resolveIdentity(root: root, files: snapshot.files, profiles: profiles)
        let freshness = ProjectRagStore.freshness(
            root: root,
            profileId: identity.profileId,
            profileVersion: identity.profileVersion,
            configDigest: identity.configDigest,
            snapshotDigest: snapshot.digest
        )

        if freshness == .fresh {
            await notify(I18n.t("orchestration.project.ragReadyFresh"))
            scheduleNextRefresh(key: key, root: root, profiles: profiles)
            return ProjectRagEnsureResult(freshness: .fresh, projectRagEnabled: true, errorSummary: nil)
        }

        let outcome = await runOrJoinBuild(key: key, root: root, profiles: profiles)
        guard outcome.manifest != nil else {
            let summary = outcome.errorSummary ?? "unknown error"
            await notify(I18n.t("orchestration.project.ragFailed", ["reason": summary]))
            return ProjectRagEnsureResult(freshness: .failed, projectRagEnabled: false, errorSummary: summary)
        }

        await notify(I18n.t("orchestration.project.ragReady"))
        scheduleNextRefresh(key: key, root: root, profiles: profiles)
        return ProjectRagEnsureResult(freshness: .fresh, projectRagEnabled: true, errorSummary: nil)
    }

    // MARK: - build coalescing

    /// Joins an already-running build for `key` instead of starting a second one, so N concurrent
    /// `ensureIndexed` calls for the same project produce exactly one `build()` + `publish()`
    /// (§4). Only the caller that actually creates the task clears it afterward — joiners just
    /// await the shared result.
    private func runOrJoinBuild(key: String, root: URL, profiles: [ProjectRagProfile]) async -> BuildOutcome {
        if let existing = states[key]?.buildTask {
            return await existing.value
        }
        let previousManifest = ProjectRagStore.currentManifest(root: root)
        let task = Task<BuildOutcome, Never> {
            do {
                let result = try await build(root: root, previousManifest: previousManifest, profiles: profiles)
                try ProjectRagStore.publish(root: root, tmpVersionDir: result.tmpVersionDir)
                ProjectRagStore.pruneOldVersions(root: root)
                return BuildOutcome(manifest: result.manifest, errorSummary: nil)
            } catch {
                return BuildOutcome(manifest: nil, errorSummary: "\(error)")
            }
        }
        states[key, default: ProjectRagState()].buildTask = task
        let outcome = await task.value
        states[key]?.buildTask = nil
        return outcome
    }

    // MARK: - scheduler (P1, R4, WO-12 §3/§4)

    /// Re-registers only the hourly scheduler loop for each already-indexed open project after a
    /// process restart — never triggers a build (design §6 WO-12 "빌드는 다시 하지 않음").
    public func restoreSchedulers(openProjects: [(projectKey: String, root: URL, profiles: [ProjectRagProfile])]) async {
        for entry in openProjects {
            scheduleNextRefresh(key: entry.projectKey, root: entry.root, profiles: entry.profiles)
        }
    }

    /// Cancels any previous scheduler for `key` before starting a new one — "reconfigure = stop 후
    /// replace" (P2), so repeated `ensureIndexed` calls for the same project never leave more than
    /// one timer loop alive.
    private func scheduleNextRefresh(key: String, root: URL, profiles: [ProjectRagProfile]) {
        cancelScheduler(key: key)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runSchedulerLoop(key: key, root: root, profiles: profiles)
        }
        states[key, default: ProjectRagState()].schedulerTask = task
    }

    /// `internal` (not `private`) purely so `@testable` tests can tear down the short-interval
    /// loops they spin up — production code never calls this directly (a project's scheduler runs
    /// for the process lifetime once `/orchestration` starts it, mirroring `RedminePoller`).
    func cancelScheduler(key: String) {
        states[key]?.schedulerTask?.cancel()
        states[key]?.schedulerTask = nil
    }

    /// One project's recurring refresh loop (P1 mirror — sleep-then-check, unlike `RedminePoller`'s
    /// immediate-first-check shape, since `ensureIndexed` just confirmed freshness before scheduling
    /// this). Skips publish entirely when the digest is unchanged (R4 — no CURRENT touch, no
    /// notify); on a real change or a build failure, backs off 5m/15m/60m before retrying, then
    /// returns to the normal 1h cadence once a build succeeds.
    private func runSchedulerLoop(key: String, root: URL, profiles: [ProjectRagProfile]) async {
        var failureStreak = 0
        while !Task.isCancelled {
            let waitNs = failureStreak == 0 ? refreshIntervalNs : backoffStepsNs[min(failureStreak - 1, backoffStepsNs.count - 1)]
            try? await Task.sleep(nanoseconds: waitNs)
            if Task.isCancelled { break }

            guard let snapshot = try? await Task.detached(priority: .utility, operation: {
                try computeSnapshot(root: root, previousFiles: nil)
            }).value else {
                failureStreak += 1
                continue
            }
            guard let current = ProjectRagStore.currentManifest(root: root) else { continue }
            if snapshot.digest == current.snapshotDigest {
                failureStreak = 0
                continue // R4 — unchanged: no rebuild, no CURRENT touch, no notify.
            }

            let outcome = await runOrJoinBuild(key: key, root: root, profiles: profiles)
            failureStreak = outcome.manifest != nil ? 0 : failureStreak + 1
        }
    }

    /// Test-only accessor (`@testable`) so scheduler tests can assert a superseded task was
    /// actually cancelled, not just replaced.
    func schedulerTaskForTesting(key: String) -> Task<Void, Never>? {
        states[key]?.schedulerTask
    }

    // MARK: - identity

    private struct RagIdentity: Sendable {
        var profileId: String
        var profileVersion: Int
        var configDigest: String
    }

    /// Stable per-root key for `states` (D4 — reuses `swift-crypto`, no new dependency). Also
    /// usable by callers assembling `restoreSchedulers`' `projectKey` argument the same way.
    static func projectKey(for root: URL) -> String {
        let normalized = root.standardizedFileURL.resolvingSymlinksInPath().path
        return sha256Hex(normalized)
    }

    /// Mirrors `build`'s primary-profile tie-break (`ProjectRagBuilder.swift`: highest `matches`
    /// score wins; later entries in `profiles` win ties, 원 설계 §5.2) so freshness can be judged
    /// *before* an actual build runs. `build()` may still end up publishing under
    /// `generic-file-graph`'s identity instead if this primary's `discover` throws (a fallback only
    /// `build()` itself decides) — a rare profile-parse-failure edge where this pre-build identity
    /// can transiently disagree with the last published manifest until the next successful build
    /// reconciles it (an extra, harmless rebuild attempt on `ensureIndexed` in the meantime).
    ///
    /// ponytail: `configDigest` re-derives `.dab-index/config.json`'s hash the same way
    /// `ProjectRagBuilder`'s own private `configDigest(root:)` does — duplicated here rather than
    /// extracted into a shared helper because this WO is scoped to touching only
    /// Coordinator/Store, not Builder. `.dab-index/config.json` itself is an existing, already-read
    /// concept in `ProjectRagBuilder` (not a speculative feature being added here).
    private static func resolveIdentity(root: URL, files: [ProjectFileRecord], profiles: [ProjectRagProfile]) -> RagIdentity {
        let configPath = root.appendingPathComponent(".dab-index/config.json")
        let configData = (try? Data(contentsOf: configPath)) ?? Data()
        let configDigest = sha256Hex(configData)

        let scored = profiles.map { (profile: $0, score: $0.matches(root: root, files: files)) }
        guard var primary = scored.first?.profile else {
            // No profiles configured — build() itself throws .noProfiles; this identity simply
            // disagrees with whatever is on disk and falls through to that failure via a real
            // build attempt.
            return RagIdentity(profileId: "", profileVersion: 0, configDigest: configDigest)
        }
        var bestScore = scored[0].score
        for entry in scored.dropFirst() where entry.score >= bestScore {
            bestScore = entry.score
            primary = entry.profile
        }
        return RagIdentity(profileId: primary.id, profileVersion: primary.version, configDigest: configDigest)
    }

    private static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
