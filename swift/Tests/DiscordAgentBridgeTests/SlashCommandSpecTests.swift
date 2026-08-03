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

// The Discord-visible name carries the bot prefix; routing keeps the bare name.
@Suite("Slash command dab- prefix")
struct SlashCommandPrefixTests {
    @Test func everySpecGetsAPrefixedDiscordName() {
        for spec in allSlashCommandSpecs() {
            #expect(dabCommandName(spec.name) == "dab-\(spec.name)")
            // Discord caps a command name at 32 chars — the prefix must not push any over.
            #expect(dabCommandName(spec.name).count <= 32)
        }
    }

    @Test func dispatchStripsThePrefixBackToTheSpecName() {
        for spec in allSlashCommandSpecs() {
            #expect(bareCommandName(dabCommandName(spec.name)) == spec.name)
        }
    }

    @Test func unprefixedNameStillRoutes() {
        // A stale client cache (or a leftover unprefixed registration mid-propagation) must not
        // fall through to the unknown-command branch.
        #expect(bareCommandName("update") == "update")
        #expect(bareCommandName("agent") == "agent")
    }

    @Test func onlyTheLeadingPrefixIsRemoved() {
        // Defensive: a bare name that merely contains the prefix text keeps it.
        #expect(bareCommandName("dab-dab-update") == "dab-update")
        #expect(bareCommandName("redmine-dab-x") == "redmine-dab-x")
    }
}
