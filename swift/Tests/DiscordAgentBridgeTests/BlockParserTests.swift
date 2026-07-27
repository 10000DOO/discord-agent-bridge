import Testing
@testable import DiscordAgentBridge

@Suite("BlockParser")
struct BlockParserTests {
    @Test func plainProseIsSingleTextSegment() {
        let segs = splitAnswerSegments("hello\nworld")
        #expect(segs == [.text("hello\nworld")])
    }

    @Test func extractsGfmTableBetweenProseInOrder() {
        let md = "before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter"
        let segs = splitAnswerSegments(md)
        #expect(segs.map(\.kind) == ["text", "table", "text"])
        #expect(segs[1] == .table(source: "| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(segs[0] == .text("before"))
        #expect(segs[2] == .text("after"))
    }

    @Test func extractsMermaidFenceAsCodeOnly() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```"
        #expect(splitAnswerSegments(md) == [.mermaid(code: "flowchart LR\n  A --> B")])
    }

    @Test func doesNotTreatPipesInsideNonMermaidFenceAsTable() {
        let md = "```js\nconst x = a | b;\n| not | a | table |\n```"
        let segs = splitAnswerSegments(md)
        #expect(segs.count == 1)
        #expect(segs[0].kind == "text")
        if case .text(let t) = segs[0] {
            #expect(t.contains("| not | a | table |"))
        } else {
            Issue.record("expected text")
        }
    }

    @Test func doesNotTreatStrayProsePipeAsTable() {
        #expect(splitAnswerSegments("use a | b to pipe") == [.text("use a | b to pipe")])
    }

    @Test func doesNotMistakeMermaidEdgeLabelsForTable() {
        let md = "```mermaid\nflowchart LR\n  A -->|yes| B\n  B -->|no| C\n```"
        let segs = splitAnswerSegments(md)
        #expect(segs.count == 1)
        #expect(segs[0].kind == "mermaid")
    }

    @Test func headerDelimiterWithZeroBodyRows() {
        let segs = splitAnswerSegments("| h1 | h2 |\n|---|---|")
        #expect(segs == [.table(source: "| h1 | h2 |\n|---|---|")])
    }

    @Test func unterminatedMermaidFenceToEof() {
        let segs = splitAnswerSegments("```mermaid\nflowchart LR\n  A --> B")
        #expect(segs == [.mermaid(code: "flowchart LR\n  A --> B")])
    }

    @Test func normalizesCrlfAndTildeMermaidFences() {
        let segs = splitAnswerSegments("~~~mermaid\r\ngraph TD\r\n  X --> Y\r\n~~~")
        #expect(segs == [.mermaid(code: "graph TD\n  X --> Y")])
    }

    @Test func dropsWhitespaceOnlyTextBetweenBlocks() {
        let md = "| a |\n|---|\n| 1 |\n\n\n| b |\n|---|\n| 2 |"
        #expect(splitAnswerSegments(md).map(\.kind) == ["table", "table"])
    }

    @Test func pipeProseOverLoneHorizontalRuleIsNotTable() {
        let md = "enable | disable\n---"
        let segs = splitAnswerSegments(md)
        #expect(segs.count == 1)
        #expect(segs[0].kind == "text")
        if case .text(let t) = segs[0] {
            #expect(t.contains("enable | disable"))
        }
    }

    @Test func singleColumnTableRecognized() {
        let segs = splitAnswerSegments("| only |\n|---|\n| x |")
        #expect(segs.map(\.kind) == ["table"])
        #expect(segs[0] == .table(source: "| only |\n|---|\n| x |"))
    }

    @Test func columnCountMismatchIsNotTable() {
        let segs = splitAnswerSegments("| a | b |\n|---|---|---|")
        #expect(segs.count == 1)
        #expect(segs[0].kind == "text")
    }

    @Test func splitRowTrimsAndDropsPipes() {
        #expect(splitRow("| a | b | c |") == ["a", "b", "c"])
    }

    @Test func splitRowHonorsEscapedPipes() {
        #expect(splitRow("| a \\| b | c |") == ["a | b", "c"])
    }

    @Test func tableCellCountBodyOnly() {
        #expect(tableCellCount("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |") == 4)
    }
}
