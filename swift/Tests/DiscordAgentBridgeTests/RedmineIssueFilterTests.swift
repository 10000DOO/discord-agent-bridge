import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("RedmineIssueFilter")
struct RedmineIssueFilterTests {
    private func issue(
        id: Int,
        statusId: Int,
        createdOn: String = "2026-07-28T00:00:00Z"
    ) -> RedmineIssueDTO {
        RedmineIssueDTO(
            id: id,
            subject: "Issue \(id)",
            description: "desc",
            projectName: "Sample",
            projectId: 1,
            statusId: statusId,
            createdOn: createdOn,
            url: "https://redmine.example.com/issues/\(id)"
        )
    }

    @Test func excludesIssuesWithNonMatchingStatus() {
        let issues = [issue(id: 1, statusId: 1), issue(id: 2, statusId: 99)]
        let result = RedmineIssueFilter.match(issues: issues, resolvedStatusIds: [1], since: nil)
        #expect(result.map(\.id) == [1])
    }

    @Test func sinceNilPassesAllMatchingStatusRegardlessOfTime() {
        let issues = [
            issue(id: 1, statusId: 1, createdOn: "2000-01-01T00:00:00Z"),
            issue(id: 2, statusId: 1, createdOn: "2026-07-28T00:00:00Z"),
        ]
        let result = RedmineIssueFilter.match(issues: issues, resolvedStatusIds: [1], since: nil)
        #expect(result.map(\.id) == [1, 2])
    }

    @Test func sinceExcludesIssuesCreatedBeforeOrAtCutoff() {
        // 2026-07-28T00:00:00Z == 1785196800000 ms
        let cutoff = 1_785_196_800_000
        let issues = [
            issue(id: 1, statusId: 1, createdOn: "2026-07-28T00:00:00Z"), // == cutoff, excluded
            issue(id: 2, statusId: 1, createdOn: "2026-07-28T00:00:01Z"), // after cutoff, included
        ]
        let result = RedmineIssueFilter.match(issues: issues, resolvedStatusIds: [1], since: cutoff)
        #expect(result.map(\.id) == [2])
    }

    @Test func unparsableCreatedOnIsExcludedWhenSinceIsSet() {
        let issues = [issue(id: 1, statusId: 1, createdOn: "not-a-date")]
        let result = RedmineIssueFilter.match(issues: issues, resolvedStatusIds: [1], since: 0)
        #expect(result.isEmpty)
    }
}
