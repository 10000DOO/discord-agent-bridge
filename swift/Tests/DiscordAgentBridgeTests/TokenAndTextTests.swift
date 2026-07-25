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
struct DiscordTextClipTests {
    @Test func shortStringUnchanged() {
        #expect(DiscordText.clip("hi") == "hi")
    }

    @Test func atLimitUnchanged() {
        let s = String(repeating: "x", count: DiscordText.maxLen)
        #expect(DiscordText.clip(s) == s)
        #expect(DiscordText.utf16Len(DiscordText.clip(s)) == DiscordText.maxLen)
    }

    @Test func overLimitClippedWithEllipsis() {
        let s = String(repeating: "x", count: DiscordText.maxLen + 5)
        let out = DiscordText.clip(s)
        // limit-1 UTF-16 units plus the ellipsis == limit total.
        #expect(DiscordText.utf16Len(out) == DiscordText.maxLen)
        #expect(out.hasSuffix("…"))
    }

    @Test func customLimit() {
        #expect(DiscordText.clip("abcdef", limit: 3) == "ab…")
        #expect(DiscordText.clip("abc", limit: 3) == "abc")
    }
}

@Suite("DiscordText.chunkMessage")
struct DiscordTextChunkTests {
    @Test func shortWholeEmptyAndLongFenceFree() {
        #expect(DiscordText.chunkMessage("short") == ["short"])
        #expect(DiscordText.chunkMessage("") == [])
        let long = String(repeating: "a", count: DiscordText.maxLen * 2 + 10)
        let chunks = DiscordText.chunkMessage(long)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { DiscordText.utf16Len($0) <= DiscordText.maxLen })
        #expect(chunks.joined() == long)
    }

    @Test func prefersNewlineBreak() {
        // First line fills nearly the whole limit; total exceeds it so a split is forced,
        // and the break lands on the newline (not mid-line).
        let line = String(repeating: "x", count: DiscordText.maxLen - 5)
        let text = line + "\n" + String(repeating: "y", count: 50)
        let chunks = DiscordText.chunkMessage(text)
        #expect(chunks[0] == line)
        #expect(chunks[1] == String(repeating: "y", count: 50))
    }

    /// 👍 is one Character but two UTF-16 code units (JS/Discord length). 1001 of them
    /// is 2002 UTF-16 units → must split under MSG_LIMIT=2000 (Character-count would not).
    @Test func utf16LimitSplitsEmojiLikeTS() {
        let text = String(repeating: "👍", count: 1001)
        #expect(text.count == 1001)
        #expect(DiscordText.utf16Len(text) == 2002)
        let chunks = DiscordText.chunkMessage(text)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { DiscordText.utf16Len($0) <= DiscordText.maxLen })
        #expect(chunks.joined() == text)
    }
}

@Suite("DiscordText.chunkMessage — code fence balancing")
struct DiscordTextChunkFenceTests {
    private func fenceCount(_ s: String) -> Int {
        var count = 0
        var search = s[s.startIndex...]
        while let range = search.range(of: "```") {
            count += 1
            search = search[range.upperBound...]
        }
        return count
    }

    private func balanced(_ s: String) -> Bool { fenceCount(s) % 2 == 0 }

    // All content except triple-backticks and newlines must survive in order. The only
    // characters the splitter adds or drops are ``` and \n (inserted markers, dropped
    // boundary newlines), so stripping both from either side must yield the same string.
    private func content(_ s: String) -> String {
        s.replacingOccurrences(of: "```", with: "").replacingOccurrences(of: "\n", with: "")
    }

    @Test func fenceFreeLongUnchanged() {
        let long = String(repeating: "a", count: DiscordText.maxLen * 2 + 10)
        let chunks = DiscordText.chunkMessage(long)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { DiscordText.utf16Len($0) <= DiscordText.maxLen })
        #expect(chunks.joined() == long)
    }

    @Test func closesAndReopensSpanningFence() {
        let code = (0..<200).map { i in "line \(i) \(String(repeating: "x", count: 20))" }.joined(separator: "\n")
        let text = "```js\n" + code + "\n```"
        #expect(DiscordText.utf16Len(text) > DiscordText.maxLen)
        let chunks = DiscordText.chunkMessage(text)
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { DiscordText.utf16Len($0) <= DiscordText.maxLen })
        #expect(chunks.allSatisfy(balanced))
        #expect(content(chunks.joined()) == content(text))
    }

    @Test func middleChunksReopenAndCloseWhen3Plus() {
        let lines = (0..<400).map { _ in String(repeating: "y", count: 50) }.joined(separator: "\n")
        let text = "```\n" + lines + "\n```"
        let chunks = DiscordText.chunkMessage(text)
        #expect(chunks.count >= 3)
        #expect(chunks.allSatisfy { DiscordText.utf16Len($0) <= DiscordText.maxLen })
        for (i, c) in chunks.enumerated() {
            #expect(balanced(c))
            if i > 0 && i < chunks.count - 1 {
                #expect(c.hasPrefix("```"))
                #expect(c.hasSuffix("```"))
            }
        }
        #expect(content(chunks.joined()) == content(text))
    }

    @Test func multipleFencesWithProseBetween() {
        func block(_ tag: String) -> String {
            "```" + tag + "\n" + String(repeating: tag + "\n", count: 300) + "```"
        }
        let text = block("alpha") + "\n\nsome prose paragraph between the blocks\n\n" + block("beta")
        #expect(DiscordText.utf16Len(text) > DiscordText.maxLen)
        let chunks = DiscordText.chunkMessage(text)
        #expect(chunks.allSatisfy { DiscordText.utf16Len($0) <= DiscordText.maxLen })
        #expect(chunks.allSatisfy(balanced))
        #expect(content(chunks.joined()) == content(text))
    }
}
