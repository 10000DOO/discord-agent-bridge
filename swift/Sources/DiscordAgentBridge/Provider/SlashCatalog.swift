import Foundation

// MARK: - Backend slash-command catalog (WO-1, docs/cli-slash-command-parity.md §3-5-3)

/// One slash command the *backend* advertises for a live session — not a Discord command.
///
/// All three backends expose this same three-part shape, so they normalize to one type instead of
/// three parallel ones (§3-5-3):
///   • Claude — `query.supportedCommands()` → `{name, description, argumentHint}`
///   • Grok   — `available_commands_update` → `{name, description, input.hint}`
///   • Codex  — `skills/list` → `{name, description}` (no hint; codex skills take free-form text)
///
/// `name` carries the backend's own namespacing verbatim (`ponytail:ponytail-help`,
/// `session-wrap:wrap`) — it is what gets sent back as `/name`, so it is never rewritten here.
public struct SlashCatalogEntry: Sendable, Equatable {
    /// Command name WITHOUT the leading slash, exactly as the backend reports it.
    public var name: String
    /// One-line blurb shown next to the name in the Discord picker. May be empty.
    public var description: String
    /// Backend-supplied argument hint (`<file>`, `on|off`, …) when it advertises one.
    public var argumentHint: String?
    public init(name: String, description: String, argumentHint: String? = nil) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
    }
}

/// Filter backend commands by a partial query, then cap at `limit` (default Discord max 25).
/// Empty/whitespace query → unfiltered list. Pure helper: no I/O, no DiscordBM — mirrors
/// `filterAutocompleteChoices` so `/command` behaves exactly like `/model` at the surface.
///
/// The query matches the name **or** the description: a user who remembers "리뷰" but not
/// `code-review` still finds it.
public func filterSlashCatalogChoices(
    _ items: [SlashCatalogEntry],
    query: String,
    limit: Int = discordAutocompleteChoiceLimit
) -> [AutocompleteChoice] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let matches: [SlashCatalogEntry]
    if q.isEmpty {
        matches = items
    } else {
        matches = items.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }
    let capped = limit < 0 ? 0 : limit
    return matches.prefix(capped).map {
        AutocompleteChoice(name: slashChoiceName($0), value: $0.name)
    }
}

/// One-line suggestion text: name, the blurb when there is one, and the argument hint last.
/// The hint rides the choice NAME because Discord fixes an option's description at registration
/// time and cannot vary it per selected choice (§3-5-4). Clamped to Discord's 100-char limit.
private func slashChoiceName(_ entry: SlashCatalogEntry) -> String {
    var name = entry.name
    if !entry.description.isEmpty {
        name += " — \(entry.description)"
    }
    if let hint = entry.argumentHint, !hint.isEmpty {
        name += " · \(hint)"
    }
    return name.count <= 100 ? name : String(name.prefix(100))
}
