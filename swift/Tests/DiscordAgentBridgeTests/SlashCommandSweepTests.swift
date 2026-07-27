import Testing
@testable import DiscordAgentBridge

// WO-2 (post-swift-cutover-issues.md §6): global-registration boots must sweep leftover
// guild-scoped commands (old TS bridge registered per-guild); dev boots (`DAB_DEV_GUILD_ID`
// set) must skip the sweep entirely, including for the guild just registered to.
@Suite("SlashCommandSweep")
struct SlashCommandSweepTests {
    @Test func sweepsEveryKnownGuildWhenNoDevGuildIsSet() async {
        var cleared: [String] = []
        await sweepStaleGuildCommands(knownGuildIds: ["1", "2", "3"], devGuildId: nil) { guildId in
            cleared.append(guildId)
        }
        #expect(cleared == ["1", "2", "3"])
    }

    @Test func skipsEntirelyWhenDevGuildIdIsSet() async {
        var cleared: [String] = []
        // The dev guild is itself in the known list — must still be skipped, not just excluded.
        await sweepStaleGuildCommands(knownGuildIds: ["1", "2"], devGuildId: "1") { guildId in
            cleared.append(guildId)
        }
        #expect(cleared.isEmpty)
    }

    @Test func noOpOnEmptyGuildList() async {
        var cleared: [String] = []
        await sweepStaleGuildCommands(knownGuildIds: [], devGuildId: nil) { guildId in
            cleared.append(guildId)
        }
        #expect(cleared.isEmpty)
    }
}
