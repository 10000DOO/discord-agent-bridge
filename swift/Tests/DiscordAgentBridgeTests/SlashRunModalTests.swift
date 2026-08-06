import Foundation
import Testing
@testable import DiscordAgentBridge
@testable import dab

/// WO-7: the `/command` modal — what opens it, what refuses to open it, what the submitted text
/// becomes, and the submit-time re-check. Channel ids are unique per test so the process-wide
/// autocomplete cache needs no reset and the suite stays parallel-safe.
@Suite("WO-7 /command modal")
struct SlashRunModalTests {
    // MARK: - Opening the modal (C7: string tests only, no backend anywhere near this)

    @Test func aPickedCommandOpensTheModalWithItsNameInTheCustomId() {
        #expect(
            slashRunOpenDecision(commandValue: "context")
                == .openModal(customId: "run:context", command: "context")
        )
        // Namespaced plugin commands keep the backend's own spelling, verbatim.
        #expect(
            slashRunOpenDecision(commandValue: "session-wrap:session-analyzer")
                == .openModal(customId: "run:session-wrap:session-analyzer", command: "session-wrap:session-analyzer")
        )
    }

    /// WO-6's C1 stand-in is guidance text, not a command — it must never reach a modal, and the
    /// test for it is a plain string comparison because that is all C7 allows before the ack.
    @Test func theNoSessionSentinelNeverOpensAModal() {
        #expect(slashRunOpenDecision(commandValue: slashCatalogNoSessionValue) == .noSession)
        #expect(slashRunOpenDecision(commandValue: "") == .noSession)
        #expect(slashRunOpenDecision(commandValue: "   ") == .noSession)
    }

    /// C21: today's longest installed plugin command is 29 chars, but that is a fact about THIS
    /// machine. A longer one must be refused out loud rather than silently truncated into a
    /// `custom_id` that would submit some other command.
    @Test func anOverlongCommandIsRefusedInsteadOfTruncated() {
        let fits = String(repeating: "x", count: discordCustomIdLimit - slashRunModalPrefix.count)
        #expect(slashRunOpenDecision(commandValue: fits) == .openModal(customId: "run:" + fits, command: fits))

        let overflows = fits + "x"
        #expect(slashRunOpenDecision(commandValue: overflows) == .nameTooLong)
    }

    @Test func theModalTitleShowsTheCommandAndRespectsDiscordsFortyFiveCharLimit() {
        #expect(slashRunModalTitle(command: "context") == "/context")
        let long = String(repeating: "y", count: 80)
        let title = slashRunModalTitle(command: long)
        #expect(title.count == discordModalTitleLimit)
        #expect(title.hasPrefix("/yyy"))
        #expect(title.hasSuffix("…"))
    }

    // MARK: - custom_id round trip

    @Test func theCustomIdRoundTripsBackToTheCommand() {
        guard case .openModal(let customId, _) = slashRunOpenDecision(commandValue: "ponytail:ponytail-help") else {
            Issue.record("expected a modal")
            return
        }
        #expect(parseSlashRunModalCustomId(customId) == "ponytail:ponytail-help")
    }

    /// Every other modal in the app must fall through untouched.
    @Test func otherModalsAreNotMistakenForRunModals() {
        #expect(parseSlashRunModalCustomId("dir:create") == nil)
        #expect(parseSlashRunModalCustomId("dir:manual") == nil)
        #expect(parseSlashRunModalCustomId("preset.name") == nil)
        #expect(parseSlashRunModalCustomId("redmine:config") == nil)
        #expect(parseSlashRunModalCustomId("run:") == nil)
    }

    // MARK: - Prompt composition (the reason this WO chose a modal at all)

    /// §3-5-1: a Discord string OPTION cannot carry a newline, which is why the prompt is typed in
    /// a `.paragraph` modal. If the newlines did not survive the trip, the modal bought nothing.
    @Test func interiorNewlinesSurviveIntact() {
        let multiline = "첫 줄\n둘째 줄\n\n네 번째 줄"
        let text = slashRunPromptText(command: "impact-analysis", prompt: multiline)
        #expect(text == "/impact-analysis\n첫 줄\n둘째 줄\n\n네 번째 줄")
        #expect(text.filter { $0 == "\n" }.count == 4)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == 5)
    }

    /// Outer whitespace goes (a stray trailing newline from the textarea is not content); the
    /// blank line the user deliberately left in the middle stays.
    @Test func onlyTheOuterWhitespaceIsTrimmed() {
        #expect(slashRunPromptText(command: "review", prompt: "\n\n  a\n\n  b  \n\n") == "/review\na\n\n  b")
    }

    @Test func anEmptyPromptRunsTheBareCommand() {
        #expect(slashRunPromptText(command: "context", prompt: "") == "/context")
        #expect(slashRunPromptText(command: "context", prompt: "   \n\n ") == "/context")
    }

    @Test func aSingleLinePromptIsAppendedOnItsOwnLine() {
        #expect(slashRunPromptText(command: "find-skills", prompt: "도커 배포") == "/find-skills\n도커 배포")
    }

    // MARK: - C8: submit-time re-check

    /// Nothing has ever answered for this channel, so a hand-typed command name (autocomplete
    /// options accept free text) must not be run on trust.
    @Test func anUnknownChannelHasNothingAvailable() {
        #expect(!slashRunCommandStillAvailable(channelId: "c-run-unknown", backend: .claude, command: "context"))
    }

    @Test func aCommandTheBackendAdvertisedIsAvailableAndOneItDidNotIsNot() async {
        let fetch: SlashCatalogFetch = { _ in
            [SlashCatalogEntry(name: "context", description: "context usage"),
             SlashCatalogEntry(name: "compact", description: "compact the thread")]
        }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-run-ok", backend: .grok, fetch: fetch)
        for _ in 0..<200 where !slashRunCommandStillAvailable(channelId: "c-run-ok", backend: .grok, command: "context") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(slashRunCommandStillAvailable(channelId: "c-run-ok", backend: .grok, command: "context"))
        #expect(!slashRunCommandStillAvailable(channelId: "c-run-ok", backend: .grok, command: "review"))
        // Exact match only — a prefix of a real command is not that command.
        #expect(!slashRunCommandStillAvailable(channelId: "c-run-ok", backend: .grok, command: "cont"))
    }

    /// The case C8 exists for: the picker was drawn for codex, then `/mode backend grok` ran
    /// before the modal was submitted. Running the codex skill anyway is the worst outcome.
    @Test func aBackendSwitchBetweenPickerAndSubmitBlocksTheStaleCommand() async {
        let codexFetch: SlashCatalogFetch = { _ in [SlashCatalogEntry(name: "codex-only-skill", description: "")] }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-run-switch", backend: .codex, fetch: codexFetch)
        for _ in 0..<200
        where !slashRunCommandStillAvailable(channelId: "c-run-switch", backend: .codex, command: "codex-only-skill") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(slashRunCommandStillAvailable(channelId: "c-run-switch", backend: .codex, command: "codex-only-skill"))
        #expect(!slashRunCommandStillAvailable(channelId: "c-run-switch", backend: .grok, command: "codex-only-skill"))
    }

    // MARK: - Discord surface strings

    /// Both locales must actually reach the user, and the modal's own strings must fit Discord's
    /// limits (label 45, placeholder 100) — DiscordBM validates the label but not the title.
    @Test func modalStringsExistInBothLocalesAndFitDiscordsLimits() {
        for locale in [AppLocale.ko, .en] {
            for key in ["run.modal.label", "run.modal.placeholder", "run.started", "run.unavailable", "run.nameTooLong"] {
                #expect(I18n.t(key, locale: locale) != key)
            }
            #expect(I18n.t("run.modal.label", locale: locale).count <= 45)
            #expect(I18n.t("run.modal.placeholder", locale: locale).count <= 100)
        }
        #expect(I18n.t("run.started", ["command": "context"], locale: .ko).contains("/context"))
        #expect(I18n.t("run.unavailable", ["command": "context"], locale: .en).contains("/context"))
    }
}
