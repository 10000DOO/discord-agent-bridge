import Testing
@testable import DiscordAgentBridge

@Suite("buildInterruptId / parseInterruptId")
struct InterruptIdTests {
    @Test func roundTrips() {
        let id = buildInterruptId(guildId: "g1", channelId: "c1")
        #expect(id == "interrupt:g1:c1")
        let parsed = parseInterruptId(id)
        #expect(parsed?.guildId == "g1")
        #expect(parsed?.channelId == "c1")
    }

    @Test func snowflakeIds() {
        let g = "123456789012345678"
        let c = "987654321098765432"
        let parsed = parseInterruptId(buildInterruptId(guildId: g, channelId: c))
        #expect(parsed?.guildId == g)
        #expect(parsed?.channelId == c)
    }

    @Test func foreignPrefixNil() {
        #expect(parseInterruptId("perm:abc:allow") == nil)
        #expect(parseInterruptId("dab-update:approve:1.0.0") == nil)
        #expect(parseInterruptId("wizard.back") == nil)
    }

    @Test func malformedNil() {
        #expect(parseInterruptId("interrupt") == nil)
        #expect(parseInterruptId("interrupt:g1") == nil)
        #expect(parseInterruptId("interrupt:g1:c1:extra") == nil)
        #expect(parseInterruptId("interrupt::c1") == nil)
        #expect(parseInterruptId("interrupt:g1:") == nil)
        #expect(parseInterruptId("") == nil)
    }

    @Test func prefixHelper() {
        #expect(isInterruptCustomId("interrupt:g:c"))
        #expect(!isInterruptCustomId("perm:x:allow"))
        #expect(!isInterruptCustomId("interrupt"))
    }
}

@Suite("buildInterruptButton")
struct InterruptButtonSpecTests {
    @Test func liveButton() {
        let b = buildInterruptButton(guildId: "g1", channelId: "c1")
        #expect(b.customId == "interrupt:g1:c1")
        #expect(b.label == InterruptLabels.button)
        #expect(b.style == "secondary")
        #expect(b.disabled == false)
    }

    @Test func disabledOnFinalize() {
        let b = buildInterruptButton(guildId: "g1", channelId: "c1", disabled: true)
        #expect(b.disabled)
        #expect(parseInterruptId(b.customId)?.channelId == "c1")
    }
}
