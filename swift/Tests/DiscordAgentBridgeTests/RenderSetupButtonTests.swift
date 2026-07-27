import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("RenderSetupButton")
struct RenderSetupButtonTests {
    // MARK: - customId round-trip

    @Test func buildAndParseRoundTrip() {
        #expect(parseRenderSetupId(buildRenderSetupId(.install)) == .install)
        #expect(parseRenderSetupId(buildRenderSetupId(.decline)) == .decline)
    }

    @Test func parseRejectsForeignOrMalformedIds() {
        #expect(parseRenderSetupId("render-setup") == nil) // missing action
        #expect(parseRenderSetupId("render-setup:bogus") == nil) // unknown action
        #expect(parseRenderSetupId("render-setup:install:extra") == nil) // extra segment
        #expect(parseRenderSetupId("dab-update:approve:1.0.0") == nil) // foreign prefix
    }

    // MARK: - maybePromptRenderSetup gating (TS `router.ts:266-276`)

    @Test func promptsOnlyWhenEnabledUndecidedAndNotInstalled() {
        #expect(shouldPromptRenderSetup(renderEnabled: true, chromiumDecision: "undecided", isInstalled: false))
    }

    @Test func doesNotPromptWhenRenderDisabled() {
        #expect(!shouldPromptRenderSetup(renderEnabled: false, chromiumDecision: "undecided", isInstalled: false))
    }

    @Test func doesNotPromptWhenAlreadyDecided() {
        #expect(!shouldPromptRenderSetup(renderEnabled: true, chromiumDecision: "accepted", isInstalled: false))
        #expect(!shouldPromptRenderSetup(renderEnabled: true, chromiumDecision: "declined", isInstalled: false))
    }

    @Test func doesNotPromptWhenAlreadyInstalled() {
        #expect(!shouldPromptRenderSetup(renderEnabled: true, chromiumDecision: "undecided", isInstalled: true))
    }
}
