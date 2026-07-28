import Testing
@testable import DiscordAgentBridge

@Suite("buildRedmineIssueEmbed")
struct RedmineIssueEmbedSpecTests {
    private func issue(fixedVersionName: String? = "v1.0") -> RedmineIssueDTO {
        RedmineIssueDTO(
            id: 42,
            subject: "Something broke",
            description: "It broke on Tuesday",
            projectName: "Sample Project",
            projectId: 7,
            statusId: 1,
            fixedVersionName: fixedVersionName,
            createdOn: "2026-07-28T00:00:00Z",
            url: "https://redmine.example.com/issues/42"
        )
    }

    @Test func fillsAllR6Fields() {
        let spec = buildRedmineIssueEmbed(issue())
        #expect(spec.title == "#42 Something broke")
        #expect(spec.url == "https://redmine.example.com/issues/42")
        #expect(spec.description == "It broke on Tuesday")
        #expect(spec.fields.count == 2)
        #expect(spec.fields[0].name == "프로젝트")
        #expect(spec.fields[0].value == "Sample Project")
        #expect(spec.fields[1].name == "목표 버전")
        #expect(spec.fields[1].value == "v1.0")
    }

    @Test func missingFixedVersionFallsBackToDash() {
        let spec = buildRedmineIssueEmbed(issue(fixedVersionName: nil))
        #expect(spec.fields[1].value == "-")
    }
}

@Suite("buildRedmineIssueId / parseRedmineIssueId")
struct RedmineIssueIdTests {
    @Test func roundTrips() {
        #expect(parseRedmineIssueId(buildRedmineIssueId(action: .start, issueId: 42))?.action == .start)
        #expect(parseRedmineIssueId(buildRedmineIssueId(action: .start, issueId: 42))?.issueId == 42)
        #expect(parseRedmineIssueId(buildRedmineIssueId(action: .start, issueId: 42))?.targetChannelId == nil)
        #expect(parseRedmineIssueId(buildRedmineIssueId(action: .cancel, issueId: 7))?.action == .cancel)
        #expect(parseRedmineIssueId(buildRedmineIssueId(action: .sessionPick, issueId: 42))?.action == .sessionPick)
        #expect(parseRedmineIssueId(buildRedmineIssueId(action: .sessionAbort, issueId: 9))?.action == .sessionAbort)
    }

    @Test func sessionConfirmRoundTrip() {
        let id = buildRedmineSessionConfirmId(issueId: 241147, targetChannelId: "123456789012345678")
        let parsed = parseRedmineIssueId(id)
        #expect(parsed?.action == .sessionConfirm)
        #expect(parsed?.issueId == 241147)
        #expect(parsed?.targetChannelId == "123456789012345678")
    }

    @Test func sessionConfirmMissingChannelNil() {
        #expect(parseRedmineIssueId("dab-redmine-issue:session-confirm:42") == nil)
        #expect(parseRedmineIssueId("dab-redmine-issue:session-confirm:42:") == nil)
    }

    @Test func nonConfirmRejectsFourParts() {
        #expect(parseRedmineIssueId("dab-redmine-issue:start:42:extra") == nil)
        #expect(parseRedmineIssueId("dab-redmine-issue:session-pick:42:chan") == nil)
    }

    @Test func foreignPrefixNil() {
        #expect(parseRedmineIssueId("dab-update:approve:1.2.3") == nil)
        #expect(isRedmineIssueCustomId("dab-update:approve:1.2.3") == false)
    }

    @Test func ownPrefixRecognized() {
        #expect(isRedmineIssueCustomId(buildRedmineIssueId(action: .start, issueId: 42)))
        #expect(isRedmineIssueCustomId(buildRedmineSessionConfirmId(issueId: 1, targetChannelId: "99")))
    }

    @Test func malformedNil() {
        #expect(parseRedmineIssueId("dab-redmine-issue:start") == nil)
        #expect(parseRedmineIssueId("dab-redmine-issue:bogus:42") == nil)
        #expect(parseRedmineIssueId("dab-redmine-issue:start:not-a-number") == nil)
        #expect(parseRedmineIssueId("dab-redmine-issue:decided") == nil)
    }
}

@Suite("buildRedmineIssueButtons / decided / session confirm")
struct RedmineIssueButtonsTests {
    @Test func startCancelRow() {
        let row = buildRedmineIssueButtons(issueId: 42)
        #expect(row.components.map(\.customId) == ["dab-redmine-issue:start:42", "dab-redmine-issue:cancel:42"])
        #expect(row.components.map(\.style) == [.success, .secondary])
        #expect(row.components.allSatisfy { !$0.disabled })
    }

    @Test func sessionConfirmRow() {
        let row = buildRedmineSessionConfirmRow(issueId: 42, targetChannelId: "999")
        #expect(row.components.map(\.customId) == [
            "dab-redmine-issue:session-confirm:42:999",
            "dab-redmine-issue:session-abort:42",
        ])
        #expect(row.components.map(\.label) == ["확인", "취소"])
        #expect(row.components.map(\.style) == [.success, .secondary])
    }

    @Test func decidedRowDisabled() {
        for action: RedmineIssueAction in [.start, .cancel] {
            let row = buildRedmineIssueDecidedRow(action: action)
            #expect(row.components.count == 1)
            #expect(row.components[0].disabled)
            #expect(parseRedmineIssueId(row.components[0].customId) == nil)
        }
    }
}
