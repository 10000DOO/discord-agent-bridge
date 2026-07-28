import Testing
import Foundation
@testable import DiscordAgentBridge

private let testSection = RedmineSection(
    url: "https://redmine.example.com",
    apiKeyEncrypted: Data("cipher".utf8),
    projectId: nil,
    reportChannelId: "chan-redmine",
    lastCheckedAt: nil
)

private func issue(id: Int, statusId: Int, createdOn: String = "2026-07-28T00:00:00Z") -> RedmineIssueDTO {
    RedmineIssueDTO(
        id: id,
        subject: "Issue #\(id)",
        description: "desc",
        projectName: "Sample Project",
        projectId: 10,
        statusId: statusId,
        createdOn: createdOn,
        url: "https://redmine.example.com/issues/\(id)"
    )
}

@Suite("RedminePoller.checkNow")
struct RedminePollerCheckNowTests {
    @Test func noConfigReturnsZero() async {
        let postedBox = LockedBox<[RedmineIssueDTO]>([])
        let deps = RedminePollerDeps(
            guildId: "g1",
            loadConfig: { nil },
            decryptApiKey: { _ in "plain-key" },
            fetchIssues: { _, _, _ in [] },
            fetchStatuses: { _, _ in [] },
            saveLastCheckedAt: { _ in },
            postIssueCard: { issue in postedBox.withLock { $0.append(issue) } }
        )
        let poller = RedminePoller(deps: deps)
        let count = await poller.checkNow()
        #expect(count == 0)
        #expect(postedBox.withLock { $0 }.isEmpty)
    }

    @Test func postsMatchedIssuesOnly() async {
        let postedBox = LockedBox<[RedmineIssueDTO]>([])
        let savedBox = LockedBox<[Int]>([])
        let statuses = [
            RedmineStatusDTO(id: 1, name: "New"),
            RedmineStatusDTO(id: 2, name: "Closed"),
        ]
        let issues = [
            issue(id: 1, statusId: 1),
            issue(id: 2, statusId: 2),
        ]
        let deps = RedminePollerDeps(
            guildId: "g1",
            loadConfig: { testSection },
            decryptApiKey: { _ in "plain-key" },
            fetchIssues: { _, _, _ in issues },
            fetchStatuses: { _, _ in statuses },
            saveLastCheckedAt: { t in savedBox.withLock { $0.append(t) } },
            postIssueCard: { issue in postedBox.withLock { $0.append(issue) } },
            now: { 5_000 }
        )
        let poller = RedminePoller(deps: deps)
        let count = await poller.checkNow()
        #expect(count == 1)
        #expect(postedBox.withLock { $0 }.map(\.id) == [1])
        #expect(savedBox.withLock { $0 } == [5_000])
    }

    @Test func decryptFailureReturnsZeroAndLogs() async {
        let postedBox = LockedBox<[RedmineIssueDTO]>([])
        let logsBox = LockedBox<[String]>([])
        struct DecryptError: Error {}
        let deps = RedminePollerDeps(
            guildId: "g1",
            loadConfig: { testSection },
            decryptApiKey: { _ in throw DecryptError() },
            fetchIssues: { _, _, _ in [issue(id: 1, statusId: 1)] },
            fetchStatuses: { _, _ in [RedmineStatusDTO(id: 1, name: "New")] },
            saveLastCheckedAt: { _ in },
            postIssueCard: { issue in postedBox.withLock { $0.append(issue) } },
            onLog: { msg in logsBox.withLock { $0.append(msg) } }
        )
        let poller = RedminePoller(deps: deps)
        let count = await poller.checkNow()
        #expect(count == 0)
        #expect(postedBox.withLock { $0 }.isEmpty)
        #expect(!logsBox.withLock { $0 }.isEmpty)
    }

    @Test func fetchFailureReturnsZeroAndLogs() async {
        let postedBox = LockedBox<[RedmineIssueDTO]>([])
        let logsBox = LockedBox<[String]>([])
        struct FetchError: Error {}
        let deps = RedminePollerDeps(
            guildId: "g1",
            loadConfig: { testSection },
            decryptApiKey: { _ in "plain-key" },
            fetchIssues: { _, _, _ in throw FetchError() },
            fetchStatuses: { _, _ in [] },
            saveLastCheckedAt: { _ in },
            postIssueCard: { issue in postedBox.withLock { $0.append(issue) } },
            onLog: { msg in logsBox.withLock { $0.append(msg) } }
        )
        let poller = RedminePoller(deps: deps)
        let count = await poller.checkNow()
        #expect(count == 0)
        #expect(postedBox.withLock { $0 }.isEmpty)
        #expect(!logsBox.withLock { $0 }.isEmpty)
    }
}

@Suite("RedminePollerRegistry")
struct RedminePollerRegistryTests {
    @Test func replacingStopsPreviousPoller() async {
        let callsBox1 = LockedBox(0)
        let callsBox2 = LockedBox(0)

        func makeDeps(_ callsBox: LockedBox<Int>) -> RedminePollerDeps {
            RedminePollerDeps(
                guildId: "g1",
                intervalMs: 10,
                loadConfig: { callsBox.withLock { $0 += 1 }; return nil },
                decryptApiKey: { _ in "plain-key" },
                fetchIssues: { _, _, _ in [] },
                fetchStatuses: { _, _ in [] },
                saveLastCheckedAt: { _ in },
                postIssueCard: { _ in }
            )
        }

        let registry = RedminePollerRegistry()
        await registry.start(guildId: "g1", deps: makeDeps(callsBox1))

        for _ in 0..<20 where callsBox1.withLock({ $0 }) < 2 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(callsBox1.withLock { $0 } >= 2)

        await registry.start(guildId: "g1", deps: makeDeps(callsBox2))
        let callsAfterReplacement = callsBox1.withLock { $0 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(callsBox1.withLock { $0 } == callsAfterReplacement)
        #expect(callsBox2.withLock { $0 } >= 1)
        await registry.stop(guildId: "g1")
    }

    @Test func distinctGuildsGetIndependentPollers() async {
        let callsBoxA = LockedBox(0)
        let callsBoxB = LockedBox(0)

        let depsA = RedminePollerDeps(
            guildId: "guild-a",
            intervalMs: 10,
            loadConfig: { callsBoxA.withLock { $0 += 1 }; return nil },
            decryptApiKey: { _ in "plain-key" },
            fetchIssues: { _, _, _ in [] },
            fetchStatuses: { _, _ in [] },
            saveLastCheckedAt: { _ in },
            postIssueCard: { _ in }
        )
        let depsB = RedminePollerDeps(
            guildId: "guild-b",
            intervalMs: 10,
            loadConfig: { callsBoxB.withLock { $0 += 1 }; return nil },
            decryptApiKey: { _ in "plain-key" },
            fetchIssues: { _, _, _ in [] },
            fetchStatuses: { _, _ in [] },
            saveLastCheckedAt: { _ in },
            postIssueCard: { _ in }
        )

        let registry = RedminePollerRegistry()
        await registry.start(guildId: "guild-a", deps: depsA)
        await registry.start(guildId: "guild-b", deps: depsB)

        // Stopping guild-a must not affect guild-b's poller.
        await registry.stop(guildId: "guild-a")
        let callsBAfterStopA = callsBoxB.withLock { $0 }
        for _ in 0..<40 where callsBoxB.withLock({ $0 }) <= callsBAfterStopA {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(callsBoxB.withLock { $0 } > callsBAfterStopA)

        await registry.stop(guildId: "guild-b")
    }
}
