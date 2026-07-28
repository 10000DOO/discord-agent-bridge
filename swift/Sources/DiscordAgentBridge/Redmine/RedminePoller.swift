import Foundation

/// Per-guild Redmine polling (WO-9, 3-3 D4). Mirrors `AutoUpdater`'s actor + `Task.sleep`
/// interval loop + closure-DI deps shape, but the registry below is a keyed dictionary
/// (`GuildAdminCache`/`WizardRegistry` cardinality), not `AutoUpdaterRegistry`'s single slot —
/// every guild has its own address/key/project, so every guild needs its own poller instance.

public let redmineDefaultIntervalMs = 5 * 60 * 1000

public struct RedminePollerDeps: Sendable {
    public var guildId: String
    public var intervalMs: Int
    public var loadConfig: @Sendable () async -> RedmineSection?
    public var decryptApiKey: @Sendable (Data) throws -> String
    public var fetchIssues: @Sendable (String, String, String?) async throws -> [RedmineIssueDTO]
    public var fetchStatuses: @Sendable (String, String) async throws -> [RedmineStatusDTO]
    public var saveLastCheckedAt: @Sendable (Int) async -> Void
    public var postIssueCard: @Sendable (RedmineIssueDTO) async -> Void
    public var now: @Sendable () -> Int
    public var onLog: @Sendable (String) -> Void

    public init(
        guildId: String,
        intervalMs: Int = redmineDefaultIntervalMs,
        loadConfig: @escaping @Sendable () async -> RedmineSection?,
        decryptApiKey: @escaping @Sendable (Data) throws -> String,
        fetchIssues: @escaping @Sendable (String, String, String?) async throws -> [RedmineIssueDTO],
        fetchStatuses: @escaping @Sendable (String, String) async throws -> [RedmineStatusDTO],
        saveLastCheckedAt: @escaping @Sendable (Int) async -> Void,
        postIssueCard: @escaping @Sendable (RedmineIssueDTO) async -> Void,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.guildId = guildId
        self.intervalMs = intervalMs
        self.loadConfig = loadConfig
        self.decryptApiKey = decryptApiKey
        self.fetchIssues = fetchIssues
        self.fetchStatuses = fetchStatuses
        self.saveLastCheckedAt = saveLastCheckedAt
        self.postIssueCard = postIssueCard
        self.now = now
        self.onLog = onLog
    }
}

public actor RedminePoller {
    private let deps: RedminePollerDeps
    private var loopTask: Task<Void, Never>?

    public init(deps: RedminePollerDeps) {
        self.deps = deps
    }

    /// Start scheduling. Idempotent — a second call while already running is a no-op (the
    /// registry is responsible for `stop()`-then-replace on reconfiguration, 3-3 D4).
    ///
    /// The initial check runs *inside* the spawned task, not awaited by the caller — `start()`
    /// is invoked synchronously from the interactive `/redmine` modal-submit handler, and a slow
    /// or unreachable Redmine server must never block that response (found live: an unreachable
    /// Redmine left the modal's followup message stuck pending until the first fetch timed out).
    public func start() async {
        guard loopTask == nil else { return }
        let interval = deps.intervalMs
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.checkNow()
            while !Task.isCancelled {
                let ns = UInt64(max(1, interval)) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                await self.checkNow()
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One check cycle. Never throws. Returns the number of issue cards posted (for tests).
    @discardableResult
    public func checkNow() async -> Int {
        guard let section = await deps.loadConfig() else { return 0 }

        let apiKey: String
        do {
            apiKey = try deps.decryptApiKey(section.apiKeyEncrypted)
        } catch {
            deps.onLog("redmine poller (\(deps.guildId)): decrypt failed: \(error)")
            return 0
        }

        let issues: [RedmineIssueDTO]
        let statuses: [RedmineStatusDTO]
        do {
            issues = try await deps.fetchIssues(section.url, apiKey, section.projectId)
            statuses = try await deps.fetchStatuses(section.url, apiKey)
        } catch {
            deps.onLog("redmine poller (\(deps.guildId)): fetch failed: \(error)")
            return 0
        }

        // Same status policy as /redmine-issue-select: 신규 | New | 진행 | Doing (+ bilingual forms).
        let resolvedStatusIds = RedmineStatusResolver.resolveTargetIds(statuses: statuses)
        let matched = RedmineIssueFilter.match(
            issues: issues,
            resolvedStatusIds: resolvedStatusIds,
            since: section.lastCheckedAt
        )
        for issue in matched {
            await deps.postIssueCard(issue)
        }
        await deps.saveLastCheckedAt(deps.now())
        return matched.count
    }
}

/// Keyed by guild id — every guild has its own address/key/project, so (unlike
/// `AutoUpdaterRegistry`'s single process-wide slot) this holds one `RedminePoller` per guild
/// (3-3 D4, 8장 주의사항: 절대 프로세스 전역 단일 인스턴스로 만들지 말 것).
public actor RedminePollerRegistry {
    public static let shared = RedminePollerRegistry()

    private var pollers: [String: RedminePoller] = [:]

    public init() {}

    /// Replaces (stopping the previous instance first) or creates the poller for `guildId`.
    public func start(guildId: String, deps: RedminePollerDeps) async {
        await pollers[guildId]?.stop()
        let poller = RedminePoller(deps: deps)
        pollers[guildId] = poller
        await poller.start()
    }

    public func stop(guildId: String) async {
        await pollers[guildId]?.stop()
        pollers.removeValue(forKey: guildId)
    }
}
