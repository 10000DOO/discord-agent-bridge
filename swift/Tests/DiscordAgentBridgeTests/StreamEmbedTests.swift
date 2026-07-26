import Testing
@testable import DiscordAgentBridge

@Suite("formatStreamEmbed")
struct FormatStreamEmbedTests {
    @Test func liveEmpty() {
        let e = formatStreamEmbed()
        #expect(e.title == "응답 중…")
        #expect(e.description == nil)
        #expect(e.footer == nil)
        #expect(e.color == DiscordColors.streaming)
    }

    @Test func livePartialText() {
        let e = formatStreamEmbed(partialText: "Hello world")
        #expect(e.title == StreamEmbedLabels.responding)
        #expect(e.description == "Hello world")
        #expect(e.footer == nil)
        #expect(e.color == DiscordColors.streaming)
    }

    @Test func liveToolCountInFooter() {
        let e = formatStreamEmbed(partialText: "…", toolCount: 3)
        #expect(e.title == "응답 중…")
        #expect(e.description == "…")
        #expect(e.footer == "🛠️ 3")
    }

    @Test func liveToolCountOnly() {
        let e = formatStreamEmbed(toolCount: 2)
        #expect(e.title == "응답 중…")
        #expect(e.description == nil)
        #expect(e.footer == "🛠️ 2")
    }

    @Test func liveTruncatesLongText() {
        let long = String(repeating: "a", count: streamEmbedDescLimit + 50)
        let e = formatStreamEmbed(partialText: long)
        #expect(e.description != nil)
        let desc = e.description!
        #expect(DiscordText.utf16Len(desc) <= streamEmbedDescLimit)
        #expect(desc.hasSuffix("…"))
    }

    @Test func finalizedNoTools() {
        let e = formatStreamEmbed(finalized: true)
        #expect(e.title == "응답 완료")
        #expect(e.description == nil)
        #expect(e.footer == nil)
        #expect(e.color == DiscordColors.streaming)
    }

    @Test func finalizedWithTools() {
        let e = formatStreamEmbed(toolCount: 5, finalized: true)
        #expect(e.title == "응답 완료 · 🛠️ 5")
        #expect(e.description == nil)
    }

    @Test func labelsMatchInterrupt() {
        #expect(StreamEmbedLabels.responding == InterruptLabels.responding)
        #expect(StreamEmbedLabels.responded == InterruptLabels.finished)
    }

    // G-P0-03: thinking phase → purple + "생각 중…"
    @Test func liveThinkingPhase() {
        let e = formatStreamEmbed(partialText: "hmm…", phase: .thinking)
        #expect(e.title == StreamEmbedLabels.thinking)
        #expect(e.title == "생각 중…")
        #expect(e.description == "hmm…")
        #expect(e.color == DiscordColors.thinking)
        #expect(e.footer == nil)
    }

    @Test func liveThinkingWithToolCount() {
        let e = formatStreamEmbed(partialText: "plan", toolCount: 1, phase: .thinking)
        #expect(e.title == "생각 중…")
        #expect(e.color == DiscordColors.thinking)
        #expect(e.footer == "🛠️ 1")
    }

    @Test func finalizedIgnoresThinkingPhase() {
        // Collapse always uses yellow "응답 완료" (answer path owns the control message).
        let e = formatStreamEmbed(partialText: "x", toolCount: 2, finalized: true, phase: .thinking)
        #expect(e.title == "응답 완료 · 🛠️ 2")
        #expect(e.color == DiscordColors.streaming)
        #expect(e.description == nil)
    }
}

@Suite("StreamStatusHost")
struct StreamStatusHostTests {
    @Test func notesNoOpWithoutBegin() async {
        let host = StreamStatusHost(minFlushInterval: 0.05)
        let edits = LockedBox<[StreamEmbedSpec]>([])
        await host.setUpdater { _, _, _, spec in
            edits.withLock { $0.append(spec) }
        }
        await host.noteText(channelId: "c1", delta: "hi")
        await host.noteThinking(channelId: "c1", delta: "hmm")
        await host.noteToolUse(channelId: "c1")
        #expect(edits.withLock { $0.isEmpty })
    }

    @Test func forceToolFlushUpdatesSpec() async {
        let host = StreamStatusHost(minFlushInterval: 0.05)
        let edits = LockedBox<[StreamEmbedSpec]>([])
        await host.setUpdater { channelId, messageId, guildId, spec in
            #expect(channelId == "c1")
            #expect(messageId == "m1")
            #expect(guildId == "g1")
            edits.withLock { $0.append(spec) }
        }
        await host.begin(channelId: "c1", guildId: "g1", messageId: "m1")
        await host.noteToolUse(channelId: "c1")
        // Force path flushes immediately (or after residual wait); give the task a tick.
        for _ in 0..<50 where edits.withLock({ $0.isEmpty }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let got = edits.withLock { $0 }
        #expect(!got.isEmpty)
        #expect(got.last?.footer == "🛠️ 1")
        #expect(got.last?.title == "응답 중…")
        await host.end(channelId: "c1")
        await host.noteToolUse(channelId: "c1") // inactive → no-op
        let after = edits.withLock { $0.count }
        try? await Task.sleep(nanoseconds: 80_000_000)
        #expect(edits.withLock { $0.count } == after)
    }

    @Test func textDebounceThenFlush() async {
        let host = StreamStatusHost(minFlushInterval: 0.05)
        let edits = LockedBox<[StreamEmbedSpec]>([])
        await host.setUpdater { _, _, _, spec in
            edits.withLock { $0.append(spec) }
        }
        await host.begin(channelId: "c2", guildId: "g", messageId: "m")
        await host.noteText(channelId: "c2", delta: "Hel")
        await host.noteText(channelId: "c2", delta: "lo")
        // Immediately after notes, debounce has not fired yet.
        #expect(edits.withLock { $0.isEmpty })
        // Wait past debounce (generous under parallel suite load).
        for _ in 0..<100 where edits.withLock({ $0.isEmpty }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let got = edits.withLock { $0 }
        #expect(got.count == 1)
        #expect(got.first?.description == "Hello")
        await host.dispose(channelId: "c2")
    }

    // G-P0-03: thinking buffer is separate from answer text; purple title while active.
    @Test func thinkingFlushIsPurpleAndSeparateFromText() async {
        let host = StreamStatusHost(minFlushInterval: 0.05)
        let edits = LockedBox<[StreamEmbedSpec]>([])
        await host.setUpdater { _, _, _, spec in
            edits.withLock { $0.append(spec) }
        }
        await host.begin(channelId: "c3", guildId: "g", messageId: "m")
        await host.noteThinking(channelId: "c3", delta: "ponder")
        await host.noteThinking(channelId: "c3", delta: "ing")
        for _ in 0..<100 where edits.withLock({ $0.isEmpty }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let thinkEdit = edits.withLock { $0.last }
        #expect(thinkEdit?.title == "생각 중…")
        #expect(thinkEdit?.color == DiscordColors.thinking)
        #expect(thinkEdit?.description == "pondering")

        // Answer text switches phase back to yellow responding; thinking not mixed in.
        await host.noteText(channelId: "c3", delta: "Final answer")
        var lastDesc: String?
        for _ in 0..<100 {
            lastDesc = edits.withLock { $0.last?.description }
            if lastDesc == "Final answer" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let answerEdit = edits.withLock { $0.last }
        #expect(answerEdit?.title == "응답 중…")
        #expect(answerEdit?.color == DiscordColors.streaming)
        #expect(answerEdit?.description == "Final answer")
        await host.dispose(channelId: "c3")
    }

    // G-P1-02: progress line surfaces as stream embed description (TS transcriptFeed parity).
    @Test func progressFlushShowsLabelAndDetail() async {
        let host = StreamStatusHost(minFlushInterval: 0.05)
        let edits = LockedBox<[StreamEmbedSpec]>([])
        await host.setUpdater { _, _, _, spec in
            edits.withLock { $0.append(spec) }
        }
        await host.begin(channelId: "c4", guildId: "g", messageId: "m")
        await host.noteProgress(channelId: "c4", label: "명령 실행 중", detail: "ls -la")
        for _ in 0..<100 where edits.withLock({ $0.isEmpty }) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let got = edits.withLock { $0.last }
        #expect(got?.title == "응답 중…")
        #expect(got?.description == "명령 실행 중: ls -la")
        await host.dispose(channelId: "c4")
    }
}
