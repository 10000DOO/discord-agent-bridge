import Foundation

// Live stream status embed pure builders (TS `src/discord/renderers/streamEmbed.ts`).
// Yellow "응답 중…" while answer text streams; purple "생각 중…" for thinking deltas.
// Discord I/O lives in dab (StreamStatusHost sink); this file is format-only.

/// Discord embed description hard limit (TS `EMBED_DESC_LIMIT`).
public let streamEmbedDescLimit = 4096

public enum StreamEmbedLabels {
    public static var responding: String { InterruptLabels.responding }
    public static var responded: String { InterruptLabels.finished }
    /// TS `stream.thinking` / i18n.
    public static var thinking: String { I18n.t("stream.thinking") }
}

/// Which live stream phase the control embed shows (TS kind: text | thinking).
public enum StreamEmbedPhase: Sendable, Equatable {
    case responding
    case thinking
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
/// - Live responding: title "응답 중…", yellow, description = clipped partial answer text.
/// - Live thinking: title "생각 중…", purple (`DiscordColors.thinking`), description = thinking buffer.
/// - Finalized: title "응답 완료" (+ " · 🛠️ N"), no body (answer is posted separately).
public func formatStreamEmbed(
    partialText: String = "",
    toolCount: Int = 0,
    finalized: Bool = false,
    phase: StreamEmbedPhase = .responding
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
    switch phase {
    case .thinking:
        return StreamEmbedSpec(
            title: StreamEmbedLabels.thinking,
            description: desc,
            color: DiscordColors.thinking,
            footer: footer
        )
    case .responding:
        return StreamEmbedSpec(
            title: StreamEmbedLabels.responding,
            description: desc,
            color: DiscordColors.streaming,
            footer: footer
        )
    }
}
