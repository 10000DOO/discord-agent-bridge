import Testing
@testable import DiscordAgentBridge

@Suite("UsageFormat pure helpers")
struct UsageFormatTests {
    @Test func formatTokensCompact() {
        #expect(formatTokens(512) == "512")
        #expect(formatTokens(1500) == "1.5K")
        #expect(formatTokens(2_000_000) == "2.0M")
    }

    @Test func formatDurationCompact() {
        #expect(formatDuration(3000) == "3.0s")
        #expect(formatDuration(90_000) == "1.5m")
    }

    @Test func buildResultLineFullAndPartial() {
        let full = TurnUsage(costUsd: 0.0123, tokensIn: 1500, tokensOut: 512, durationMs: 3000)
        #expect(buildResultLine(full) == "완료 · 비용 $0.0123 · 토큰 1.5K↓ 512↑ · 소요 3.0s")

        let tokensOnly = TurnUsage(tokensIn: 100, tokensOut: nil)
        #expect(buildResultLine(tokensOnly) == "완료 · 토큰 100↓")

        let empty = TurnUsage()
        #expect(buildResultLine(empty) == nil)
        #expect(empty.hasMetrics == false)
    }

    @Test func turnUsageFromResultSkipsAllNil() {
        #expect(turnUsage(fromResult: nil, tokensIn: nil, tokensOut: nil, durationMs: nil) == nil)
        let u = turnUsage(fromResult: 0.5, tokensIn: 10, tokensOut: 20, durationMs: 30)
        #expect(u == TurnUsage(costUsd: 0.5, tokensIn: 10, tokensOut: 20, durationMs: 30))
    }

    @Test func turnUsageFromCodexCompleted() {
        let camel = JSONValue.object([
            "usage": .object([
                "inputTokens": .number(11),
                "outputTokens": .number(22),
            ]),
        ])
        #expect(turnUsage(fromCodexCompleted: camel) == TurnUsage(tokensIn: 11, tokensOut: 22))

        let nested = JSONValue.object([
            "turn": .object([
                "usage": .object([
                    "input_tokens": .number(3),
                    "output_tokens": .number(4),
                ]),
            ]),
        ])
        #expect(turnUsage(fromCodexCompleted: nested) == TurnUsage(tokensIn: 3, tokensOut: 4))

        #expect(turnUsage(fromCodexCompleted: nil) == nil)
        #expect(turnUsage(fromCodexCompleted: .object([:])) == nil)
    }

    @Test func turnUsageFromGrokPromptResultMetaAndLegacy() {
        let meta = JSONValue.object([
            "_meta": .object([
                "usage": .object([
                    "costUsdTicks": .number(1e10 * 0.25), // $0.25
                    "inputTokens": .number(100),
                    "outputTokens": .number(50),
                ]),
            ]),
        ])
        let u = turnUsage(fromGrokPromptResult: meta)
        #expect(u?.tokensIn == 100)
        #expect(u?.tokensOut == 50)
        #expect(u?.costUsd != nil)
        #expect(abs((u?.costUsd ?? 0) - 0.25) < 1e-9)

        let legacy = JSONValue.object([
            "usage": .object([
                "input_tokens": .number(7),
                "output_tokens": .number(8),
                "total_cost_usd": .number(0.01),
            ]),
        ])
        #expect(
            turnUsage(fromGrokPromptResult: legacy)
                == TurnUsage(costUsd: 0.01, tokensIn: 7, tokensOut: 8)
        )
        #expect(turnUsage(fromGrokPromptResult: nil) == nil)
    }

    @Test func discordColorsMatchTS() {
        #expect(DiscordColors.streaming == 0xfee75c)
        #expect(DiscordColors.thinking == 0x9b59b6)
        #expect(DiscordColors.permission == 0xe67e22)
        #expect(DiscordColors.idle == 0x57f287)
        #expect(DiscordColors.error == 0xed4245)
        #expect(DiscordColors.stopped == 0xed4245)
    }
}

@Suite("codexTurnStep usage on finished")
struct CodexTurnStepUsageTests {
    @Test func finishedCarriesUsage() {
        let params: JSONValue = .object([
            "usage": .object([
                "inputTokens": .number(9),
                "outputTokens": .number(8),
            ]),
        ])
        let step = codexTurnStep(method: "turn/completed", params: params)
        #expect(step == .finished(TurnUsage(tokensIn: 9, tokensOut: 8)))
        #expect(codexTurnStep(method: "turn/completed", params: nil) == .finished(nil))
    }
}
