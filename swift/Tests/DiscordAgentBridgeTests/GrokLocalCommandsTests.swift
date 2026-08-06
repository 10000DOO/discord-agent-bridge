import Foundation
import Testing
@testable import DiscordAgentBridge

/// Grok's `/context` returns nothing over ACP (verified against grok 0.2.118 with
/// `grok -p "/context" --output-format streaming-json`: available_commands, then end, no text).
@Suite("Grok local command screens")
struct GrokLocalCommandsTests {
    @Test func contextScreenIsRebuiltFromTheTurnsOwnUsageFacts() {
        let out = grokLocalCommandScreen(prompt: "/context", model: "grok-4.5", totalTokens: 9411, maxTokens: 500_000)
        #expect(out?.contains("Context Usage") == true)
        #expect(out?.contains("grok-4.5") == true)
        #expect(out?.contains("9.4k / 500k (2%)") == true)
    }

    /// The command arrives as "/context\n<prompt>" when it came through the `/command` modal.
    @Test func aPromptTypedUnderTheCommandStillCounts() {
        #expect(grokLocalCommandScreen(prompt: "/context\nwhat is loaded?", model: "grok-4.5", totalTokens: nil, maxTokens: nil) != nil)
    }

    /// Without usage numbers the screen still names the model rather than claiming a token count.
    @Test func missingTokenFactsDropTheContextLineInsteadOfGuessing() {
        let out = grokLocalCommandScreen(prompt: "/context", model: "grok-4.5", totalTokens: nil, maxTokens: 0)
        #expect(out?.contains("grok-4.5") == true)
        #expect(out?.contains("  Context ") == false)
    }

    /// An ordinary turn that produced no text must keep the plain stand-in, not gain a screen.
    @Test func onlyContextGetsAScreen() {
        #expect(grokLocalCommandScreen(prompt: "hello", model: "grok-4.5", totalTokens: 1, maxTokens: 2) == nil)
        #expect(grokLocalCommandScreen(prompt: "/compact", model: "grok-4.5", totalTokens: 1, maxTokens: 2) == nil)
        #expect(grokLocalCommandScreen(prompt: "/context-window", model: "grok-4.5", totalTokens: 1, maxTokens: 2) == nil)
    }
}
