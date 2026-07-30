import Foundation
import Testing
@testable import DiscordAgentBridge
@testable import dab

@Suite("RedmineKickoffPrompt")
struct RedmineKickoffPromptTests {
    @Test func promptContainsIssueNumberSubjectAndDescriptionNotLink() {
        let issue = RedmineIssueDTO(
            id: 1,
            subject: "Long issue",
            description: "레드마인 이슈 설명입니다.",
            projectName: "Sample",
            projectId: 1,
            statusId: 1,
            createdOn: "2026-07-28T00:00:00Z",
            url: "https://redmine.example.com/issues/1"
        )
        let text = redmineKickoffPromptText(issue: issue)
        #expect(text.contains("#\(issue.id)"))
        #expect(text.contains(issue.subject))
        #expect(text.contains(issue.description))
        #expect(!text.contains(issue.url))
    }
}
