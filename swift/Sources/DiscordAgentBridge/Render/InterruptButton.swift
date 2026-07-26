import Foundation

// Interrupt "stop" button pure builders (TS `src/discord/renderers/interruptButton.ts`).
// custom_id scheme: `interrupt:<guildId>:<channelId>` — snowflakes have no colons.
// Click cancels the CURRENT turn only; session/binding stay (≠ /stop).

public let interruptCustomIdPrefix = "interrupt"

public enum InterruptLabels {
    public static let button = "⏹️ 중단"
    public static let responding = "응답 중…"
    public static let done = "현재 작업을 중단했어요. 이어서 대화할 수 있어요."
    public static let none = "중단할 실행 중인 작업이 없어요."
    public static let denied = "권한이 없습니다."
    /// Control message after the turn ends (button disabled / removed).
    public static let finished = "응답 완료"
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
