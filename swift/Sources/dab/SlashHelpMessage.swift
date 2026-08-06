import DiscordAgentBridge
import Foundation

// MARK: - /command-list body (WO-10, docs/cli-slash-command-parity.md §3-5-4 · C1 · C12)

/// Discord's embed description cap — twice the 2000-character message body, which is why this
/// command answers with an embed rather than plain content: measured on this repo, 91 commands
/// come to ~1700 characters of bare names, so a plain message would start dropping commands after
/// a handful of new plugins. Dropping commands is the exact complaint `/command-list` exists to fix.
let discordEmbedDescriptionLimit = 4096

/// Everything this channel's backend advertises, names only, sized to fit one embed.
///
/// Names only on purpose: with the backends' own blurbs attached, 91 commands run past 6000
/// characters — over BOTH Discord caps. The blurb is one keystroke away in `/command`'s picker,
/// which is what the closing tip points at.
///
/// Grouping is limited to what the protocol actually says. A `:` in the name is a plugin namespace
/// (`codex:review`, `session-wrap:wrap`); built-ins and skills arrive indistinguishable from each
/// other, so they stay one block instead of being split by a hardcoded name list that would rot the
/// next time a backend ships a command (R8).
///
/// Scope: backend commands only. The bridge's own commands (`/agent`, `/model`, …) are already in
/// Discord's own picker and are not what `/command` can run, so they are deliberately absent.
///
/// Empty list → the same "still loading" line `/command`'s picker uses, for the same reason
/// (sessions spawn lazily, C1).
///
/// `locale` exists for tests only: a suite that asserts on this text would otherwise race the
/// process-wide locale other suites flip (§8-1 C30). Production passes nil and gets the ambient one.
func slashHelpDescription(
    backend: Backend,
    commands: [SlashCatalogEntry],
    limit: Int = discordEmbedDescriptionLimit,
    locale: AppLocale? = nil
) -> String {
    guard !commands.isEmpty else { return I18n.t("run.noSession", locale: locale) }
    let tip = I18n.t("help.tip", locale: locale)
    // Reserved BEFORE a single name is written, so an overlong list costs the user the tail of the
    // list and never the sentence that explains why the tail is missing. `help.more` is measured at
    // its longest possible rendering (every command dropped); the +4 covers the trailing joins.
    let reserve = DiscordText.utf16Len(tip)
        + DiscordText.utf16Len(I18n.t("help.more", ["count": "\(commands.count)"], locale: locale))
        + 4
    var body = I18n.t(
        "help.header",
        ["backend": backend.rawValue, "count": "\(commands.count)"],
        locale: locale
    )
    var dropped = 0

    // The section heading rides the first item that actually fits, so a backend with no plugins at
    // all (codex lists skills only) leaves no dangling heading over an empty block.
    func append(_ title: String?, _ items: [SlashCatalogEntry]) {
        var opened = false
        for item in items {
            let lead = opened ? " · " : (title.map { "\n\n**\($0)**\n" } ?? "\n\n")
            let piece = lead + "`\(item.name)`"
            guard DiscordText.utf16Len(body) + DiscordText.utf16Len(piece) + reserve <= limit else {
                dropped += 1
                continue
            }
            body += piece
            opened = true
        }
    }

    append(nil, commands.filter { !$0.name.contains(":") })
    append(I18n.t("help.plugins", locale: locale), commands.filter { $0.name.contains(":") })
    if dropped > 0 {
        body += "\n" + I18n.t("help.more", ["count": "\(dropped)"], locale: locale)
    }
    return body + "\n\n" + tip
}
