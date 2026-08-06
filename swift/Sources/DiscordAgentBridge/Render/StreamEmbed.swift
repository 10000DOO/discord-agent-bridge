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
/// - `elapsedSeconds`: the live clock, appended to the *title* as " · 3분 34초". It sat in the footer
///   next to a raw delta count (H8, TS `streamEmbed.ts:219-222` `"{sec}s · {deltaCount}"`) — the
///   least legible spot in the embed for the one value that proves the session is still alive, and
///   `214.3s` is not a duration a person reads. Deliberate divergence from that TS footer contract;
///   the delta count went with it (a bare number nobody in a channel can interpret).
///   Absent (nil) until the current phase's kind has actually started (StreamStatusHost only passes
///   a value once a matching delta arrived), so a tool-only flush still shows tool-count-only. The
///   one exception is StreamStatusHost's heartbeat tick, which substitutes the turn's own start so a
///   turn that has produced NO event at all still renders a moving clock.
public func formatStreamEmbed(
    partialText: String = "",
    toolCount: Int = 0,
    finalized: Bool = false,
    phase: StreamEmbedPhase = .responding,
    elapsedSeconds: Int? = nil
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
    let clock = elapsedSeconds.map { " · \(formatDurationText(seconds: $0))" } ?? ""
    switch phase {
    case .thinking:
        return StreamEmbedSpec(
            title: StreamEmbedLabels.thinking + clock,
            description: desc,
            color: DiscordColors.thinking,
            footer: footer
        )
    case .responding:
        return StreamEmbedSpec(
            title: StreamEmbedLabels.responding + clock,
            description: desc,
            color: DiscordColors.streaming,
            footer: footer
        )
    }
}

/// "Thought for Ns" (TS `finalize()` kind:'thinking', `streamEmbed.ts:158-164`) — bare
/// `{ title, color }`, no description/footer (TS collapses the *separate* thinking message to
/// this once the turn ends). Swift merged thinking/text into one control message, so the only
/// point this is ever visible is the instant the phase leaves `.thinking` (StreamStatusHost
/// flashes it there before the message moves on to the responding content).
public func formatThoughtCompleteEmbed(elapsedSeconds: Int) -> StreamEmbedSpec {
    StreamEmbedSpec(
        title: I18n.t("stream.thought", ["sec": formatDurationText(seconds: elapsedSeconds)]),
        color: DiscordColors.thinking
    )
}
