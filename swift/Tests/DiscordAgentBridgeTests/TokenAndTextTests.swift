import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("DiscordToken.resolve priority")
struct DiscordTokenTests {
    @Test func botTokenWinsOverEverything() {
        let t = DiscordToken.resolve(
            environment: ["DISCORD_BOT_TOKEN": "bot", "DISCORD_TOKEN": "plain"],
            arguments: ["dab", "argtoken"]
        )
        #expect(t == "bot")
    }

    @Test func fallsBackToDiscordToken() {
        let t = DiscordToken.resolve(
            environment: ["DISCORD_TOKEN": "plain"],
            arguments: ["dab", "argtoken"]
        )
        #expect(t == "plain")
    }

    @Test func fallsBackToArgument() {
        let t = DiscordToken.resolve(environment: [:], arguments: ["dab", "argtoken"])
        #expect(t == "argtoken")
    }

    @Test func emptyEnvValuesSkipped() {
        // Empty BOT_TOKEN → skip to DISCORD_TOKEN; empty that too → arg.
        #expect(DiscordToken.resolve(environment: ["DISCORD_BOT_TOKEN": "", "DISCORD_TOKEN": "plain"], arguments: ["dab"]) == "plain")
        #expect(DiscordToken.resolve(environment: ["DISCORD_BOT_TOKEN": "", "DISCORD_TOKEN": ""], arguments: ["dab", "arg"]) == "arg")
    }

    @Test func nilWhenNothingProvided() {
        #expect(DiscordToken.resolve(environment: [:], arguments: ["dab"]) == nil)
        // Empty arg is not a token.
        #expect(DiscordToken.resolve(environment: [:], arguments: ["dab", ""]) == nil)
    }
}

@Suite("DiscordText.clip")
struct DiscordTextTests {
    @Test func shortStringUnchanged() {
        #expect(DiscordText.clip("hi") == "hi")
    }

    @Test func atLimitUnchanged() {
        let s = String(repeating: "x", count: DiscordText.maxLen)
        #expect(DiscordText.clip(s) == s)
        #expect(DiscordText.clip(s).count == DiscordText.maxLen)
    }

    @Test func overLimitClippedWithEllipsis() {
        let s = String(repeating: "x", count: DiscordText.maxLen + 5)
        let out = DiscordText.clip(s)
        // limit-1 characters plus the ellipsis == limit total.
        #expect(out.count == DiscordText.maxLen)
        #expect(out.hasSuffix("…"))
    }

    @Test func customLimit() {
        #expect(DiscordText.clip("abcdef", limit: 3) == "ab…")
        #expect(DiscordText.clip("abc", limit: 3) == "abc")
    }
}
