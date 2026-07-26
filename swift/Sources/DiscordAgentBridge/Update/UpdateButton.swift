import Foundation

// Update prompt UI pure builders (TS `src/discord/renderers/updateButton.ts`).
// custom_id scheme: `dab-update:<action>:<version>` — action ∈ approve|dismiss.

public let updateCustomIdPrefix = "dab-update"

public enum UpdateAction: String, Sendable, Equatable {
    case approve
    case dismiss
}

public struct UpdateEmbedSpec: Sendable, Equatable {
    public var title: String
    public var description: String
    public var color: Int
    public init(title: String, description: String, color: Int) {
        self.title = title
        self.description = description
        self.color = color
    }
}

public enum UpdateButtonStyle: String, Sendable, Equatable {
    case success
    case secondary
}

public struct UpdateButtonSpec: Sendable, Equatable {
    public var customId: String
    public var label: String
    public var style: UpdateButtonStyle
    public var disabled: Bool
    public init(customId: String, label: String, style: UpdateButtonStyle, disabled: Bool = false) {
        self.customId = customId
        self.label = label
        self.style = style
        self.disabled = disabled
    }
}

public struct UpdateComponentRow: Sendable, Equatable {
    public var components: [UpdateButtonSpec]
    public init(components: [UpdateButtonSpec]) { self.components = components }
}

public enum UpdateLabels {
    public static let title = "🔄 새 버전이 있어요"
    public static func body(current: String, latest: String) -> String {
        "`discord-agent-bridge` \(latest) 버전이 나왔어요 (현재 \(current)).\n지금 업데이트할까요? 관리자만 결정할 수 있어요.\n**예**를 누르면 안내를 표시합니다 (Swift 바이너리 자동 교체는 아직 없어요).\n**아니오**를 누르면 이 버전 알림을 끕니다."
    }
    public static let yes = "예, 업데이트"
    public static let no = "아니오"
    public static let decidedApproved = "업데이트 안내"
    public static let decidedDismissed = "이 버전 건너뜀"
    public static let busy = "이미 업데이트가 진행 중이에요."
    public static let dismissed = "이 버전 알림을 껐어요. 더 새 버전이 나오면 다시 알려드릴게요."
    public static let denied = "자동 업데이트는 서버 관리자(Administrator) 또는 admin 티어만 결정할 수 있어요."
    /// Approve path when self-replace is not available (Swift shippable slice).
    public static let manualOnly =
        "Swift dab는 자동 설치·재시작을 아직 지원하지 않아요. `swift/scripts/install.sh` 또는 최신 소스로 수동 업데이트하세요."
    public static let upToDate = "최신 버전이에요."
    public static let checkFailed = "버전 확인에 실패했어요 (네트워크/레지스트리)."
    public static let disabled = "자동 업데이트가 꺼져 있어요 (`autoUpdate.enabled=false`)."
}

public func buildUpdateId(action: UpdateAction, version: String) -> String {
    "\(updateCustomIdPrefix):\(action.rawValue):\(version)"
}

/// Parse `dab-update:<action>:<version>`. nil for foreign / malformed / decided placeholder.
public func parseUpdateId(_ customId: String) -> (action: UpdateAction, version: String)? {
    let parts = customId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts[0] == updateCustomIdPrefix else { return nil }
    guard let action = UpdateAction(rawValue: parts[1]) else { return nil }
    let version = parts[2]
    guard !version.isEmpty else { return nil }
    return (action, version)
}

public func isUpdateCustomId(_ customId: String) -> Bool {
    customId.hasPrefix("\(updateCustomIdPrefix):")
}

public func buildUpdatePrompt(version: String, currentVersion: String) -> (embed: UpdateEmbedSpec, rows: [UpdateComponentRow]) {
    let embed = UpdateEmbedSpec(
        title: UpdateLabels.title,
        description: UpdateLabels.body(current: currentVersion, latest: version),
        color: DiscordColors.permission
    )
    let buttons = [
        UpdateButtonSpec(customId: buildUpdateId(action: .approve, version: version), label: UpdateLabels.yes, style: .success),
        UpdateButtonSpec(customId: buildUpdateId(action: .dismiss, version: version), label: UpdateLabels.no, style: .secondary),
    ]
    return (embed, [UpdateComponentRow(components: buttons)])
}

/// Single DISABLED button row after a decision (keeps the prompt non-reclickable).
public func buildUpdateDecidedRow(action: UpdateAction) -> UpdateComponentRow {
    UpdateComponentRow(components: [
        UpdateButtonSpec(
            customId: "\(updateCustomIdPrefix):decided",
            label: action == .approve ? UpdateLabels.decidedApproved : UpdateLabels.decidedDismissed,
            style: .secondary,
            disabled: true
        ),
    ])
}
