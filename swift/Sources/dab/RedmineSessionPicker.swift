import DiscordAgentBridge
import DiscordBM
import Foundation

// Redmine "착수" session dropdown (WO-5, docs/redmine-issue-session-start.md 3-1/3-3 D2/D3) —
// lists a guild's active sessions plus a trailing "신규 세션" sentinel, chunked to Discord's
// 25-option select-menu cap (R7).

/// Sentinel `value` for the "신규 세션" option. Travels via `comp.values` (not the custom_id), so
/// it follows the existing `"__none__"`(`DirectoryBrowser.swift`)/`"__raw__"`(`ChannelWizard.swift`)
/// sentinel convention rather than a new namespace.
public let newSessionSentinel = "__new__"

/// One guild's active sessions, labeled for the dropdown (3-3 D2). Label prefers the real channel
/// name (what the user actually sees in Discord); falls back to the `cwd` slug only if the channel
/// lookup fails (e.g. the channel was deleted but the binding wasn't cleaned up).
func redmineSessionSelectOptions(
    client: any DiscordClient, guildId: String
) async -> [(channelId: String, label: String, cwd: String, backend: String)] {
    let sessions = await SessionStore.shared.active(guildId: guildId)
    var out: [(channelId: String, label: String, cwd: String, backend: String)] = []
    for channelId in sessions.keys.sorted() {
        let session = sessions[channelId]!
        let label: String
        if let channel = try? await client.getChannel(id: ChannelSnowflake(channelId)).decode(),
           let name = channel.name {
            label = name
        } else {
            label = sessionChannelName(session.cwd)
        }
        out.append((channelId: channelId, label: label, cwd: session.cwd, backend: session.backend.rawValue))
    }
    return out
}

/// Session dropdown(s) for the given issue, chunked to Discord's 25-option cap (R7). The "🆕 신규
/// 세션" option is appended to EVERY chunk (WO-5c, 2026-07-28 user directive reversing 3-3 D3 — a
/// user looking at any page can pick "신규 세션" without paging to the last one); an empty
/// `sessions` list still yields one menu (the sentinel alone), so a guild with no active sessions
/// still gets "신규 세션" (R1).
func buildRedmineSessionSelectMenus(
    sessions: [(channelId: String, label: String, cwd: String, backend: String)],
    issueId: Int
) -> [Interaction.ActionRow.StringSelectMenu] {
    // WO-5b: chunk at (cap - 1), not the full 25-cap — the sentinel below adds 1 more option to
    // the last chunk, so chunking at the full cap let a session count that's an exact multiple of
    // 25 push the last menu to 26 options (Discord rejects it, and the followup post was silently
    // dropped via `try?`).
    let chunks = RedmineIssueChunker.chunk(sessions, size: RedmineIssueChunker.maxOptionsPerMenu - 1)
    let sessionChunks = chunks.isEmpty ? [[]] : chunks
    let customId = buildRedmineIssueId(action: .sessionPick, issueId: issueId)
    return sessionChunks.enumerated().map { index, chunk in
        var options = chunk.map {
            Interaction.ActionRow.StringSelectMenu.Option(
                label: $0.label, value: $0.channelId, description: "\($0.cwd) · \($0.backend)"
            )
        }
        options.append(
            Interaction.ActionRow.StringSelectMenu.Option(label: I18n.t("redmine.session.newSession"), value: newSessionSentinel)
        )
        let placeholder = sessionChunks.count > 1
            ? I18n.t("redmine.session.placeholder.paged", ["index": "\(index + 1)", "total": "\(sessionChunks.count)"])
            : I18n.t("redmine.session.placeholder.single")
        return Interaction.ActionRow.StringSelectMenu(custom_id: customId, options: options, placeholder: placeholder)
    }
}
