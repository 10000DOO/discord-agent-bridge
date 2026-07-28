import Foundation

// Redmine issue card spec (WO-7) — pure builder → RedmineIssueEmbedSpec.
// Reuses StatusEmbedField (Render/StatusEmbed.swift) instead of a new field type.
// Start/cancel buttons reuse UpdateComponentRow/UpdateButtonSpec/UpdateButtonStyle
// (Update/UpdateButton.swift) — the redmine-only customId scheme lives there (WO-7).

public struct RedmineIssueEmbedSpec: Sendable, Equatable {
    public var title: String
    public var url: String
    public var description: String
    public var fields: [StatusEmbedField]

    public init(title: String, url: String, description: String, fields: [StatusEmbedField]) {
        self.title = title
        self.url = url
        self.description = description
        self.fields = fields
    }
}

/// R6: 제목(이슈번호 포함)·링크·설명·소속 프로젝트·목표 버전.
public func buildRedmineIssueEmbed(_ issue: RedmineIssueDTO) -> RedmineIssueEmbedSpec {
    RedmineIssueEmbedSpec(
        title: "#\(issue.id) \(issue.subject)",
        url: issue.url,
        description: issue.description,
        fields: [
            StatusEmbedField(name: "프로젝트", value: issue.projectName, inline: true),
            StatusEmbedField(name: "목표 버전", value: issue.fixedVersionName ?? "-", inline: true),
        ]
    )
}
