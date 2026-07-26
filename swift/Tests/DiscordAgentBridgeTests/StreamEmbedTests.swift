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
}
