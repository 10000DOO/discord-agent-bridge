import Testing
@testable import DiscordAgentBridge
@testable import dab

// WO-2 (docs/i18n-locale-autodetect.md): applicationCommandPayload must carry ko/en
// localizations for every registered command, so Discord can pick the client's locale.
@Suite("SlashCommandSpecLocalization")
struct SlashCommandSpecTests {
    @Test func payloadIncludesKoreanAndEnglishLocalizations() {
        let payload = applicationCommandPayload(agentCommandSpec())
        #expect(payload.name_localizations?.values[.korean] != nil)
        #expect(payload.description_localizations?.values[.korean] != nil)
        #expect(payload.description_localizations?.values[.englishUS] != nil)
    }
}
