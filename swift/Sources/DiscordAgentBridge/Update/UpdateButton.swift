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
    public static var title: String { I18n.t("update.title") }
    public static func body(current: String, latest: String) -> String {
        I18n.t("update.body", ["current": current, "latest": latest])
    }
    public static var yes: String { I18n.t("update.button.yes") }
    public static var no: String { I18n.t("update.button.no") }
    public static var decidedApproved: String { I18n.t("update.decided.approved") }
    public static var decidedDismissed: String { I18n.t("update.decided.dismissed") }
    public static var busy: String { I18n.t("update.busy") }
    public static var dismissed: String { I18n.t("update.dismissed") }
    public static var denied: String { I18n.t("update.denied") }
    /// Install succeeded — about to restart into the new binary.
    public static var installed: String { I18n.t("update.installed") }
    /// Install failed — process stays on the old binary; operator path.
    public static var installFailed: String { I18n.t("update.installFailed") }
    /// Approve path when install port / plan is unavailable.
    public static var manualOnly: String { I18n.t("update.manualOnly") }
    /// Install succeeded but the current process could not prove a safe replacement handoff.
    public static var manualRestartRequired: String { I18n.t("update.manualRestartRequired") }
    /// Approve path delegated to a Homebrew tap's detached self-update script.
    public static var homebrewInProgress: String { I18n.t("update.homebrewInProgress") }
    public static var upToDate: String { I18n.t("update.upToDate") }
    public static var checkFailed: String { I18n.t("update.checkFailed") }
    public static var disabled: String { I18n.t("update.disabled") }
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
