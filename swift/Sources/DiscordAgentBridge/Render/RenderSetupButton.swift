import Foundation

// Chromium install prompt UI pure builders (TS `renderers/renderSetupButton.ts`).
// custom_id scheme: `render-setup:<action>` — action ∈ install|decline. Host-wide decision
// (no ids needed — unlike interrupt/update, this isn't scoped to a guild/channel/version).

public let renderSetupCustomIdPrefix = "render-setup"

public enum RenderSetupAction: String, Sendable, Equatable {
    case install
    case decline
}

public enum RenderSetupButtonStyle: String, Sendable, Equatable {
    case primary
    case secondary
}

public struct RenderSetupButtonSpec: Sendable, Equatable {
    public var customId: String
    public var label: String
    public var style: RenderSetupButtonStyle
    public init(customId: String, label: String, style: RenderSetupButtonStyle) {
        self.customId = customId
        self.label = label
        self.style = style
    }
}

public enum RenderSetupLabels {
    public static var prompt: String { I18n.t("render.setup.prompt") }
    public static var install: String { I18n.t("render.setup.install") }
    public static var decline: String { I18n.t("render.setup.decline") }
    public static var unavailable: String { I18n.t("render.setup.unavailable") }
    public static var declined: String { I18n.t("render.setup.declined") }
    public static var already: String { I18n.t("render.setup.already") }
    public static var done: String { I18n.t("render.setup.done") }
    public static var failed: String { I18n.t("render.setup.failed") }

    /// `{bar}` = 10-cell block bar, `{pct}` = the raw percent (TS `slashCommands.ts:274-277`).
    public static func progress(pct: Int) -> String {
        let n = max(0, min(10, Int((Double(pct) / 10).rounded())))
        let bar = String(repeating: "▓", count: n) + String(repeating: "░", count: 10 - n)
        return I18n.t("render.setup.progress", ["bar": bar, "pct": String(pct)])
    }
}

public func buildRenderSetupId(_ action: RenderSetupAction) -> String {
    "\(renderSetupCustomIdPrefix):\(action.rawValue)"
}

/// Parse `render-setup:<action>`. nil for foreign / malformed ids.
public func parseRenderSetupId(_ customId: String) -> RenderSetupAction? {
    let parts = customId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, parts[0] == renderSetupCustomIdPrefix else { return nil }
    return RenderSetupAction(rawValue: parts[1])
}

public func buildRenderSetupButtons() -> [RenderSetupButtonSpec] {
    [
        RenderSetupButtonSpec(customId: buildRenderSetupId(.install), label: RenderSetupLabels.install, style: .primary),
        RenderSetupButtonSpec(customId: buildRenderSetupId(.decline), label: RenderSetupLabels.decline, style: .secondary),
    ]
}

/// Gate for the post-/setup prompt (TS `maybePromptRenderSetup`, `router.ts:266-276`): only
/// offer the install prompt when rendering is on, nothing has been decided yet, and nothing
/// is already installed. Pure — no I/O — so it's unit-testable without a live provisioner.
public func shouldPromptRenderSetup(renderEnabled: Bool, chromiumDecision: String, isInstalled: Bool) -> Bool {
    renderEnabled && chromiumDecision == "undecided" && !isInstalled
}
