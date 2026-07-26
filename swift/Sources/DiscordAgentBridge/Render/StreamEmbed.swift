import Foundation

// Live stream status embed pure builders (TS `src/discord/renderers/streamEmbed.ts`).
// Yellow "응답 중…" while a turn runs; collapse to "응답 완료" on finalize.
// Discord I/O lives in dab (StreamStatusHost sink); this file is format-only.

/// Discord embed description hard limit (TS `EMBED_DESC_LIMIT`).
public let streamEmbedDescLimit = 4096

public enum StreamEmbedLabels {
    public static let responding = InterruptLabels.responding
    public static let responded = InterruptLabels.finished
}

/// Pure embed payload for the live/final stream control message.
public struct StreamEmbedSpec: Sendable, Equatable {
    public var title: String
    public var description: String?
    public var color: Int
    public var footer: String?

    public init(
        title: String,
        description: String? = nil,
        color: Int,
        footer: String? = nil
    ) {
        self.title = title
        self.description = description
        self.color = color
        self.footer = footer
    }
}

/// Live or finalized stream status embed.
/// - Live: title "응답 중…", description = clipped partial text, footer = tool count when > 0.
/// - Finalized: title "응답 완료" (+ " · 🛠️ N"), no body (answer is posted separately).
public func formatStreamEmbed(
    partialText: String = "",
    toolCount: Int = 0,
    finalized: Bool = false
) -> StreamEmbedSpec {
    if finalized {
        return StreamEmbedSpec(
            title: interruptFinishedContent(toolCount: toolCount),
            description: nil,
            color: DiscordColors.streaming,
            footer: nil
        )
    }
    let desc: String?
    if partialText.isEmpty {
        desc = nil
    } else {
        desc = DiscordText.truncate(partialText, streamEmbedDescLimit)
    }
    let footer: String? = toolCount > 0 ? "🛠️ \(toolCount)" : nil
    return StreamEmbedSpec(
        title: StreamEmbedLabels.responding,
        description: desc,
        color: DiscordColors.streaming,
        footer: footer
    )
}
