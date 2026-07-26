import Foundation

// Interrupt "stop" button pure builders (TS `src/discord/renderers/interruptButton.ts`).
// custom_id scheme: `interrupt:<guildId>:<channelId>` — snowflakes have no colons.
// Click cancels the CURRENT turn only; session/binding stay (≠ /stop).

public let interruptCustomIdPrefix = "interrupt"

public enum InterruptLabels {
    public static var button: String { I18n.t("cmd.interrupt.button") }
    public static var responding: String { I18n.t("stream.responding") }
    public static var done: String { I18n.t("cmd.interrupt.done") }
    public static var none: String { I18n.t("cmd.interrupt.none") }
    /// Generic deny without `{reason}` (interrupt / update button paths).
    public static var denied: String { I18n.t("auth.denied.bare") }
    /// Control message after the turn ends (button disabled / removed).
    public static var finished: String { I18n.t("stream.responded") }
}

/// Live control-message content while a turn runs (optional tool count HUD, W11-g slice4).
public func interruptRespondingContent(toolCount: Int = 0) -> String {
    if toolCount <= 0 { return InterruptLabels.responding }
    return "\(InterruptLabels.responding) · 🛠️ \(toolCount)"
}

/// Control-message content after the turn ends (optional tool count).
public func interruptFinishedContent(toolCount: Int = 0) -> String {
    if toolCount <= 0 { return InterruptLabels.finished }
    return "\(InterruptLabels.finished) · 🛠️ \(toolCount)"
}

public struct InterruptButtonSpec: Sendable, Equatable {
    public var customId: String
    public var label: String
    public var style: String // "secondary" — Discord mapping lives in dab
    public var disabled: Bool
    public init(customId: String, label: String, style: String = "secondary", disabled: Bool = false) {
        self.customId = customId
        self.label = label
        self.style = style
        self.disabled = disabled
    }
}

public func buildInterruptId(guildId: String, channelId: String) -> String {
    "\(interruptCustomIdPrefix):\(guildId):\(channelId)"
}

/// Parse `interrupt:<guildId>:<channelId>`. nil for foreign / malformed ids.
public func parseInterruptId(_ customId: String) -> (guildId: String, channelId: String)? {
    let parts = customId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts[0] == interruptCustomIdPrefix else { return nil }
    let guildId = parts[1]
    let channelId = parts[2]
    guard !guildId.isEmpty, !channelId.isEmpty else { return nil }
    return (guildId, channelId)
}

public func isInterruptCustomId(_ customId: String) -> Bool {
    customId.hasPrefix("\(interruptCustomIdPrefix):")
}

public func buildInterruptButton(
    guildId: String,
    channelId: String,
    disabled: Bool = false
) -> InterruptButtonSpec {
    InterruptButtonSpec(
        customId: buildInterruptId(guildId: guildId, channelId: channelId),
        label: InterruptLabels.button,
        style: "secondary",
        disabled: disabled
    )
}
