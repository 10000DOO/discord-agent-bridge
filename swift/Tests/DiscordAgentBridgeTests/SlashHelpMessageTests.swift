import Foundation
import Testing
@testable import DiscordAgentBridge
@testable import dab

private func helpSample(_ names: [String]) -> [SlashCatalogEntry] {
    names.map { SlashCatalogEntry(name: $0, description: "does \($0)") }
}

/// A list the size of a real machine's (measured: 91 on this repo), with the long plugin names that
/// actually drive the length. Deliberately generated rather than asserted on by count (C12: catalog
/// size is cwd-dependent, so no test may pin it).
private func helpRealisticCatalog() -> [SlashCatalogEntry] {
    let builtins = ["compact", "context", "usage", "review", "security-review", "init", "model", "effort", "fast", "mcp", "config", "clear", "rename", "goal", "insights", "recap", "loop", "schedule", "doctor", "debug", "code-review", "simplify", "batch", "verify", "agents", "autocompact", "color", "heapdump", "reload-skills", "run"]
    let skills = (0..<39).map { "user-skill-with-a-longish-name-\($0)" }
    let plugins = (0..<22).map { "plugin-namespace-\($0):command-name-\($0)" }
    return helpSample(builtins + skills + plugins)
}

/// WO-10: `/command-list` — the spec, the assembled body, and the two orderings that decide whether a
/// cold channel ever gets a list. Locale is passed explicitly everywhere so this suite cannot race
/// the process-wide locale other suites flip (§8-1 C30). Channel ids are unique per test, so the
/// process-wide autocomplete cache needs no reset and the suite stays parallel-safe.
@Suite("WO-10 /command-list")
struct SlashHelpMessageTests {
    // MARK: - Spec registration

    @Test func registeredAmongAllSpecs() {
        #expect(allSlashCommandSpecs().contains { $0.name == "command-list" })
    }

    @Test func discordNameIsBareAndRoutesBack() {
        // Named to pair with `/command`. 12 characters, inside Discord's 32-char name bound.
        #expect(helpCommandSpec().name == "command-list")
        #expect(dabCommandName(helpCommandSpec().name) == "command-list")
        #expect(bareCommandName("command-list") == "command-list")
    }

    /// It lists what the channel binding already decides, so there is nothing to ask for — and
    /// reading what a channel can run is not an admin act.
    @Test func hasNoOptionsAndIsNotAdminGated() {
        let spec = helpCommandSpec()
        #expect(spec.options.isEmpty)
        #expect(spec.subcommands.isEmpty)
    }

    // MARK: - Grouping (only what the protocol actually tells us)

    /// A `:` is the ONE thing the backends distinguish. Everything else — built-in vs skill — is
    /// indistinguishable in the payload, so it must not be split by a hardcoded name list (R8).
    @Test func onlyColonNamesAreGroupedAsPlugins() {
        for locale in [AppLocale.ko, .en] {
            let body = slashHelpDescription(
                backend: .claude,
                commands: helpSample(["context", "codex:review", "compact", "ponytail:ponytail-help"]),
                locale: locale
            )
            // Position-based so the assertion never depends on a localized heading: every colon
            // name must sit after every plain name.
            let lastPlain = max(body.range(of: "`context`")!.lowerBound, body.range(of: "`compact`")!.lowerBound)
            let firstPlugin = min(
                body.range(of: "`codex:review`")!.lowerBound,
                body.range(of: "`ponytail:ponytail-help`")!.lowerBound
            )
            #expect(lastPlain < firstPlugin)
        }
    }

    /// Codex advertises skills only — never a namespaced name — so the plugin section must vanish
    /// entirely rather than leave its heading standing over nothing.
    @Test func aBackendWithNoPluginsLeavesNoEmptyHeading() {
        for locale in [AppLocale.ko, .en] {
            let body = slashHelpDescription(
                backend: .codex,
                commands: helpSample(["find-skills", "write-tests"]),
                locale: locale
            )
            #expect(!body.contains(I18n.t("help.plugins", locale: locale)))
            #expect(body.contains("`find-skills`"))
        }
    }

    // MARK: - Length ceiling (the reason this is an embed and not a message)

    @Test func aRealisticCatalogFitsTheEmbedWithoutDroppingAnything() {
        let commands = helpRealisticCatalog()
        for locale in [AppLocale.ko, .en] {
            let body = slashHelpDescription(backend: .claude, commands: commands, locale: locale)
            #expect(DiscordText.utf16Len(body) <= discordEmbedDescriptionLimit)
            for command in commands {
                #expect(body.contains("`\(command.name)`"))
            }
            #expect(!body.contains(I18n.t("help.more", ["count": "1"], locale: locale)))
        }
    }

    /// The same catalog against a plain message's 2000-character budget: it does NOT fit. This is
    /// the measurement the embed choice rests on — if it ever starts fitting, the embed is optional.
    @Test func theSameCatalogWouldNotFitAPlainMessage() {
        let body = slashHelpDescription(
            backend: .claude,
            commands: helpRealisticCatalog(),
            limit: DiscordText.maxLen,
            locale: .ko
        )
        #expect(DiscordText.utf16Len(body) <= DiscordText.maxLen)
        #expect(body.contains("…"))
    }

    /// Overflow must truncate the list, never the guidance — the tip is the whole point of the
    /// command, and it is also what tells the user how to reach the commands that were dropped.
    @Test func overflowDropsTheListTailAndKeepsTheGuidance() {
        for locale in [AppLocale.ko, .en] {
            let body = slashHelpDescription(
                backend: .grok,
                commands: helpSample((0..<500).map { "a-fairly-long-command-name-\($0)" }),
                locale: locale
            )
            #expect(DiscordText.utf16Len(body) <= discordEmbedDescriptionLimit)
            #expect(body.hasSuffix(I18n.t("help.tip", locale: locale)))
            #expect(!body.contains("`a-fairly-long-command-name-499`"))
        }
    }

    // MARK: - Guidance content (the three things the user has to be told)

    /// The picker's 25-item cap, that typing searches past it, and that an unlisted name still runs
    /// when typed out. The first two are checkable verbatim in both locales.
    @Test func guidanceNamesThePickerCapAndThatTypingSearches() {
        for locale in [AppLocale.ko, .en] {
            let tip = I18n.t("help.tip", locale: locale)
            #expect(tip.contains("25"))
            #expect(tip.contains("/command"))
            #expect(tip != "help.tip")
        }
    }

    @Test func everyHelpStringIsTranslated() {
        for key in ["help.header", "help.plugins", "help.more", "help.tip"] {
            #expect(I18n.t(key, locale: .ko) != key)
            #expect(I18n.t(key, locale: .en) != key)
            #expect(I18n.t(key, locale: .ko) != I18n.t(key, locale: .en))
        }
    }

    // MARK: - Empty list (C1)

    /// A channel whose session has not spawned yet gets the picker's own wording, not a bare embed.
    @Test func anEmptyCatalogAnswersWithTheSameGuidanceThePickerUses() {
        for locale in [AppLocale.ko, .en] {
            #expect(
                slashHelpDescription(backend: .claude, commands: [], locale: locale)
                    == I18n.t("run.noSession", locale: locale)
            )
        }
    }

    @Test func theBodyNamesTheBackendItListed() {
        // An unbound channel falls back to claude; saying which backend was listed is what keeps
        // that fallback from reading like the channel's own answer.
        for backend in [Backend.claude, .codex, .grok] {
            let body = slashHelpDescription(backend: backend, commands: helpSample(["context"]), locale: .en)
            #expect(body.contains(backend.rawValue))
        }
    }

    // MARK: - Warm-then-read ordering (the trap the handler must not reverse)

    /// The handler's order: warm first, THEN read. The warm-up owns the round trip, so the read
    /// that follows serves a real list on the very first `/command-list`.
    @Test func warmingBeforeReadingFillsTheList() async {
        let fetch: SlashCatalogFetch = { _ in helpSample(["context", "review"]) }
        #expect(await warmSlashCatalog(channelId: "h-warm-first", backend: .claude, ensureLive: { _ in true }, fetch: fetch))
        let served = AutocompleteSlashCatalogCache.commands(channelId: "h-warm-first", backend: .claude, fetch: fetch)
        #expect(served.map(\.name) == ["context", "review"])
    }

    /// The same two calls in the opposite order, which is what a well-meaning "read first, warm only
    /// if empty" refactor produces. The read takes the channel's fill slot on its way out, so the
    /// warm-up finds it taken, does nothing, and the follow-up read is still empty — a channel with
    /// no session yet would sit on "still loading" forever.
    @Test func readingBeforeWarmingLosesTheFillSlot() async {
        let fetch: SlashCatalogFetch = { _ in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return helpSample(["context", "review"])
        }
        // The read claims the slot synchronously before it returns, so this is not a timing race.
        #expect(AutocompleteSlashCatalogCache.commands(channelId: "h-read-first", backend: .claude, fetch: fetch).isEmpty)
        #expect(await warmSlashCatalog(channelId: "h-read-first", backend: .claude, ensureLive: { _ in true }, fetch: fetch) == false)
        #expect(AutocompleteSlashCatalogCache.commands(channelId: "h-read-first", backend: .claude, fetch: fetch).isEmpty)
    }
}
