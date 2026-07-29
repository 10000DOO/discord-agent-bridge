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
    /// Install succeeded — service relaunch is being requested (not yet confirmed running).
    public static var restartRequested: String { I18n.t("update.restartRequested") }
    /// Alias kept for older call sites/tests.
    public static var installed: String { restartRequested }
    /// New process confirmed up (READY marker or relaunch script verify).
    public static var restartConfirmed: String { I18n.t("update.restartConfirmed") }
    /// Install failed — process stays on the old binary; operator path.
    public static var installFailed: String { I18n.t("update.installFailed") }
    /// Approve path when install port / plan is unavailable.
    public static var manualOnly: String { I18n.t("update.manualOnly") }
    /// Install ok but relaunch could not be started or verified.
    public static var restartFailed: String { I18n.t("update.restartFailed") }
    /// Alias kept for older call sites/tests.
    public static var manualRestartRequired: String { restartFailed }
    /// Approve path delegated to a Homebrew tap's detached self-update script.
    public static var homebrewInProgress: String { I18n.t("update.homebrewInProgress") }
    /// `DAB_INSTALL_METHOD=homebrew` but self-update script missing — refuse in-process dual path.
    public static var homebrewUnavailable: String { I18n.t("update.homebrewUnavailable") }
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

// Redmine issue start/cancel buttons (WO-7) — reuses UpdateComponentRow/UpdateButtonSpec/
// UpdateButtonStyle above, no dedicated redmine spec type. custom_id scheme:
// `dab-redmine-issue:<action>:<issueId>` — 3 parts (start|cancel|session-pick|session-abort)
// `dab-redmine-issue:session-confirm:<issueId>:<targetChannelId>` — 4 parts (docs/redmine-session-confirm-kickoff.md)

public let redmineIssueCustomIdPrefix = "dab-redmine-issue"

public enum RedmineIssueAction: String, Sendable, Equatable {
    case start
    case cancel
    case sessionPick = "session-pick"
    /// Confirm kickoff into an already-picked existing session (4-part custom_id).
    case sessionConfirm = "session-confirm"
    /// Abort the confirm step (back out without writing to the session).
    case sessionAbort = "session-abort"
}

public func buildRedmineIssueId(action: RedmineIssueAction, issueId: Int) -> String {
    "\(redmineIssueCustomIdPrefix):\(action.rawValue):\(issueId)"
}

/// 4-part confirm id carrying the chosen session channel (snowflake has no `:`).
public func buildRedmineSessionConfirmId(issueId: Int, targetChannelId: String) -> String {
    "\(redmineIssueCustomIdPrefix):\(RedmineIssueAction.sessionConfirm.rawValue):\(issueId):\(targetChannelId)"
}

/// Parse `dab-redmine-issue:<action>:<issueId>` or `…:session-confirm:<issueId>:<channelId>`.
/// nil for foreign / malformed / decided placeholder.
public func parseRedmineIssueId(
    _ customId: String
) -> (action: RedmineIssueAction, issueId: Int, targetChannelId: String?)? {
    let parts = customId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3 || parts.count == 4, parts[0] == redmineIssueCustomIdPrefix else { return nil }
    guard let action = RedmineIssueAction(rawValue: parts[1]) else { return nil }
    guard let issueId = Int(parts[2]) else { return nil }
    if action == .sessionConfirm {
        guard parts.count == 4, !parts[3].isEmpty else { return nil }
        return (action, issueId, parts[3])
    }
    // All other actions are strictly 3-part.
    guard parts.count == 3 else { return nil }
    return (action, issueId, nil)
}

public func isRedmineIssueCustomId(_ customId: String) -> Bool {
    customId.hasPrefix("\(redmineIssueCustomIdPrefix):")
}

public func buildRedmineIssueButtons(issueId: Int) -> UpdateComponentRow {
    UpdateComponentRow(components: [
        UpdateButtonSpec(customId: buildRedmineIssueId(action: .start, issueId: issueId), label: I18n.t("redmine.issue.button.start"), style: .success),
        UpdateButtonSpec(customId: buildRedmineIssueId(action: .cancel, issueId: issueId), label: I18n.t("redmine.issue.button.cancel"), style: .secondary),
    ])
}

/// Confirm/cancel row after an existing-session pick (docs/redmine-session-confirm-kickoff.md).
public func buildRedmineSessionConfirmRow(issueId: Int, targetChannelId: String) -> UpdateComponentRow {
    UpdateComponentRow(components: [
        UpdateButtonSpec(
            customId: buildRedmineSessionConfirmId(issueId: issueId, targetChannelId: targetChannelId),
            label: I18n.t("redmine.issue.button.confirm"),
            style: .success
        ),
        UpdateButtonSpec(
            customId: buildRedmineIssueId(action: .sessionAbort, issueId: issueId),
            label: I18n.t("redmine.issue.button.cancel"),
            style: .secondary
        ),
    ])
}

/// Single DISABLED button row after a decision (mirrors buildUpdateDecidedRow above). `.start`
/// gets a second, always-enabled restart (`redmine.issue.button.restart`) button next to the disabled placeholder — its
/// custom_id is identical to the original start button's, so the existing `.start` handling in
/// `handleRedmineIssueComponent` re-runs unchanged and lets the same issue be started again.
public func buildRedmineIssueDecidedRow(action: RedmineIssueAction, issueId: Int) -> UpdateComponentRow {
    let label: String
    switch action {
    case .start: label = I18n.t("redmine.issue.button.started")
    case .cancel: label = I18n.t("redmine.issue.button.cancelled")
    default: label = I18n.t("redmine.issue.button.done")
    }
    let placeholder = UpdateButtonSpec(
        customId: "\(redmineIssueCustomIdPrefix):decided",
        label: label,
        style: .secondary,
        disabled: true
    )
    if action == .start {
        let restart = UpdateButtonSpec(
            customId: buildRedmineIssueId(action: .start, issueId: issueId),
            label: I18n.t("redmine.issue.button.restart"),
            style: .secondary
        )
        return UpdateComponentRow(components: [placeholder, restart])
    }
    return UpdateComponentRow(components: [placeholder])
}

// Turn-timeout retry prompt buttons — reuses UpdateComponentRow/UpdateButtonSpec above.
// custom_id scheme: `dab-turn-timeout:<confirm|dismiss>` — no dynamic id needed, the button's
// effect (announce only) is scoped to whatever channel the interaction arrives on.

public let turnTimeoutCustomIdPrefix = "dab-turn-timeout"

public enum TurnTimeoutAction: String, Sendable, Equatable {
    case confirm
    case dismiss
}

public func buildTurnTimeoutId(action: TurnTimeoutAction) -> String {
    "\(turnTimeoutCustomIdPrefix):\(action.rawValue)"
}

public func parseTurnTimeoutId(_ customId: String) -> TurnTimeoutAction? {
    let parts = customId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, parts[0] == turnTimeoutCustomIdPrefix else { return nil }
    return TurnTimeoutAction(rawValue: parts[1])
}

public func isTurnTimeoutCustomId(_ customId: String) -> Bool {
    customId.hasPrefix("\(turnTimeoutCustomIdPrefix):")
}

public func buildTurnTimeoutRetryRow() -> UpdateComponentRow {
    UpdateComponentRow(components: [
        UpdateButtonSpec(customId: buildTurnTimeoutId(action: .confirm), label: I18n.t("turnTimeout.button.yes"), style: .success),
        UpdateButtonSpec(customId: buildTurnTimeoutId(action: .dismiss), label: I18n.t("turnTimeout.button.no"), style: .secondary),
    ])
}

/// Single DISABLED button row after a decision (mirrors buildUpdateDecidedRow/buildRedmineIssueDecidedRow).
public func buildTurnTimeoutDecidedRow(action: TurnTimeoutAction) -> UpdateComponentRow {
    UpdateComponentRow(components: [
        UpdateButtonSpec(
            customId: "\(turnTimeoutCustomIdPrefix):decided",
            label: action == .confirm ? I18n.t("turnTimeout.button.confirmed") : I18n.t("turnTimeout.button.no"),
            style: .secondary,
            disabled: true
        ),
    ])
}
