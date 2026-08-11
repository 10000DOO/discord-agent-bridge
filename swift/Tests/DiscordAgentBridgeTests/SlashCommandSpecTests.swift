import Testing
@testable import DiscordAgentBridge
@testable import dab

// WO-2 (docs/i18n-locale-autodetect.md): applicationCommandPayload must carry ko/en
// name_localizations for every registered command, so Discord can pick the client's locale.
//
// description_localizations only carries locale values that are actually short enough:
// DiscordBM 1.16.2's ApplicationCommandCreate/Edit.validate() checks description_localizations
// values against the name field's 1-32 char bound instead of description's 100-char bound
// (Payloads.swift:1073, :1123), so any single locale description over 32 chars fails the whole
// bulk registration call. `localizations()` (SlashSupport.swift) drops only the over-limit locale
// values per command, keeping the rest so ko/en descriptions still register where they fit.
@Suite("SlashCommandSpecLocalization")
struct SlashCommandSpecTests {
    @Test func payloadIncludesKoreanNameLocalizationAndShortDescriptionLocalization() {
        let payload = applicationCommandPayload(agentCommandSpec())
        #expect(payload.name_localizations?.values[.korean] != nil)
        // agentCommandSpec's ko description is <=32 chars, its en description is not — only ko
        // should survive the per-locale length filter.
        #expect(payload.description_localizations?.values[.korean] != nil)
        #expect(payload.description_localizations?.values[.englishUS] == nil)
    }

    @Test func descriptionLocalizationsOmittedWhenBothLocalesExceedLimit() {
        let spec = SlashCommandSpec(
            name: "x",
            description: LocalizedText(
                ko: String(repeating: "가", count: 33),
                en: String(repeating: "a", count: 33)
            )
        )
        let payload = applicationCommandPayload(spec)
        #expect(payload.description_localizations == nil)
    }
}

// Commands register under their bare name — the `dab-` prefix was dropped deliberately
// (SlashCommandSpec.swift:5-14). The registration/dispatch pair still has to round-trip, and the
// legacy prefix still has to route, so both are pinned here.
@Suite("Slash command naming")
struct SlashCommandPrefixTests {
    @Test func everySpecRegistersUnderItsBareName() {
        for spec in allSlashCommandSpecs() {
            #expect(dabCommandName(spec.name) == spec.name)
            // Discord caps a command name at 32 chars.
            #expect(dabCommandName(spec.name).count <= 32)
        }
    }

    @Test func dispatchRoundTripsBackToTheSpecName() {
        for spec in allSlashCommandSpecs() {
            #expect(bareCommandName(dabCommandName(spec.name)) == spec.name)
        }
    }

    @Test func legacyPrefixedNameStillRoutes() {
        // Renaming a global command takes up to an hour to propagate (C33), so a client that still
        // has the old names cached must not fall through to the unknown-command branch.
        #expect(bareCommandName("dab-update") == "update")
        #expect(bareCommandName("dab-agent") == "agent")
        #expect(bareCommandName("update") == "update")
        #expect(bareCommandName("agent") == "agent")
    }

    @Test func onlyTheLeadingLegacyPrefixIsRemoved() {
        // Defensive: a bare name that merely contains the prefix text keeps it.
        #expect(bareCommandName("dab-dab-update") == "dab-update")
        #expect(bareCommandName("redmine-dab-x") == "redmine-dab-x")
    }
}

// WO-5 (docs/cli-slash-command-parity.md §3-5-1): /command carries exactly ONE autocomplete
// option. The args-free shape is a design decision, not an oversight — Discord string options
// cannot hold newlines, so multi-line prompts arrive through a modal instead. A second option
// added here would fork that into two input paths, so the option count is asserted.
@Suite("command spec")
struct RunCommandSpecTests {
    @Test func registeredAmongAllSpecs() {
        #expect(allSlashCommandSpecs().contains { $0.name == "command" })
    }

    @Test func discordNameIsBareAndRoutesBack() {
        // The Swift symbol still says `run`; only the Discord-visible name is `command`, paired
        // with `command-list`. The former `/dab-run` cannot be rescued by the legacy strip — the
        // name itself changed — so nothing here asserts that it still routes.
        #expect(runCommandSpec().name == "command")
        #expect(dabCommandName(runCommandSpec().name) == "command")
        #expect(bareCommandName("command") == "command")
    }

    @Test func exactlyOneAutocompleteOptionAndNoFreeTextOption() {
        let spec = runCommandSpec()
        #expect(spec.options.count == 1)
        #expect(spec.subcommands.isEmpty)
        let option = spec.options.first
        // `name`, not `command` — `/command command:…` stutters in Discord's UI.
        #expect(option?.name == "name")
        #expect(option?.autocomplete == true)
        #expect(option?.required == true)
        // Autocomplete and static choices are mutually exclusive on Discord (stringOption drops
        // choices when autocomplete is set) — an empty list keeps that unambiguous.
        #expect(option?.choices.isEmpty == true)
    }

    /// Discord enforces `default_member_permissions` on its own side: a tagged command never
    /// reaches this bot from a non-admin member, so no amount of opening up the Authorizer can
    /// rescue it. Everyone is an admin, so NO command may carry that tag (R8) — this is the guard.
    @Test func noCommandIsRegisteredWithAPermissionTag() {
        for spec in allSlashCommandSpecs() {
            #expect(applicationCommandPayload(spec).default_member_permissions == nil, "\(spec.name)")
        }
    }

    // The three commands that carried the tag before v3.7.3 get their own guards as well, so a
    // regression names the command instead of pointing at a loop over every spec.

    @Test func setupRegistersWithoutAPermissionTag() {
        #expect(applicationCommandPayload(setupCommandSpec()).default_member_permissions == nil)
    }

    @Test func configRegistersWithoutAPermissionTag() {
        #expect(applicationCommandPayload(configCommandSpec()).default_member_permissions == nil)
    }

    @Test func updateRegistersWithoutAPermissionTag() {
        #expect(applicationCommandPayload(updateCommandSpec()).default_member_permissions == nil)
    }

    @Test func bothLocalesReachUsers() {
        let payload = applicationCommandPayload(runCommandSpec())
        // ko survives only while it stays <=32 scalars — `localizations()` drops longer values
        // wholesale, which would silently show Korean clients the English text. This is the guard
        // against that silent regression when someone edits the wording.
        #expect(payload.description_localizations?.values[.korean] != nil)
        // en needs no localization entry: the base `description` IS the en string, so English
        // clients get it verbatim whatever the length filter does.
        #expect(payload.description == runCommandSpec().description.en)
    }
}

// C19 (docs/cli-slash-command-parity.md §8-1): repo-wide guard for the description length limits.
//
// Both ceilings have already bitten this repo — the production log records one boot where
// registration failed outright with fifteen `characterCountOutOfRange(description_localizations,
// max: 32)` plus one `tooManyCharacters(description, max: 100)`, i.e. NO command registered at all.
//
// The two limits fail differently, which is why both are checked:
//   • ko over 32   — silent. `localizations()` (SlashSupport.swift) drops that one locale value, so
//                    the command still registers and Korean clients quietly fall back to English.
//   • en over 100  — loud, and fatal to the WHOLE bulk call: `description` is the en string and
//                    Discord's real limit is 100, so one long en description takes every command
//                    down with it.
@Suite("Slash command description limits")
struct SlashCommandDescriptionLimitTests {
    /// Every description a spec can register: the command, its options, its subcommands, and their
    /// options — `applicationCommandPayload` covers all four (SlashSupport.swift:22,30,41,51,94).
    private func descriptions(_ spec: SlashCommandSpec) -> [(label: String, text: LocalizedText)] {
        var out = [(spec.name, spec.description)]
        out += spec.options.map { ("\(spec.name).\($0.name)", $0.description) }
        for sub in spec.subcommands {
            out.append(("\(spec.name) \(sub.name)", sub.description))
            out += sub.options.map { ("\(spec.name) \(sub.name).\($0.name)", $0.description) }
        }
        return out
    }

    @Test func everyKoreanDescriptionSurvivesTheLocalizationFilter() {
        for spec in allSlashCommandSpecs() {
            for entry in descriptions(spec) {
                let count = entry.text.ko.unicodeScalars.count
                #expect(
                    count <= 32,
                    "ko description for '\(entry.label)' is \(count) scalars; over 32 it is silently dropped and Korean clients see English"
                )
            }
        }
    }

    @Test func everyEnglishDescriptionStaysUnderDiscordsHardLimit() {
        for spec in allSlashCommandSpecs() {
            for entry in descriptions(spec) {
                let count = entry.text.en.unicodeScalars.count
                #expect(
                    count <= 100,
                    "en description for '\(entry.label)' is \(count) scalars; over 100 Discord rejects the ENTIRE bulk registration, so no command registers"
                )
            }
        }
    }

    /// Discord also bounds the command/option names themselves (1-32, lowercase). The registered
    /// name is what has to fit — `command-list` is the longest at 12.
    @Test func everyRegisteredNameFitsDiscordsNameRules() {
        for spec in allSlashCommandSpecs() {
            let registered = dabCommandName(spec.name)
            #expect(registered.count <= 32, "'\(registered)' is \(registered.count) chars; Discord allows 32")
            #expect(registered == registered.lowercased(), "'\(registered)' must be lowercase")
            for option in spec.options {
                #expect(option.name.count <= 32 && option.name == option.name.lowercased(), "option '\(spec.name).\(option.name)' breaks Discord's name rules")
            }
            for sub in spec.subcommands {
                #expect(sub.name.count <= 32 && sub.name == sub.name.lowercased(), "subcommand '\(spec.name) \(sub.name)' breaks Discord's name rules")
            }
        }
    }
}
