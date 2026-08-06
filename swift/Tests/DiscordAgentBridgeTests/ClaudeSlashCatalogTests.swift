import Testing
import Foundation
@testable import DiscordAgentBridge

/// WO-2b — `claude.slashCommands` response → `SlashCatalogEntry` mapping. Machine-independent: the
/// fixture is the wire shape WO-2 implemented and tested on the sidecar side, so no sidecar is
/// spawned. Counts are never asserted — the list is cwd-dependent (§3-5-3 footnote, C12).
@Suite("Claude slash catalog")
struct ClaudeSlashCatalogTests {
    private func result(_ commands: [JSONValue]) -> JSONValue {
        .object(["commands": .array(commands)])
    }

    /// The exact three-row sample from the confirmed wire contract: plain, hinted, and namespaced.
    @Test func mapsTheWireContractSample() {
        let entries = claudeSlashCatalog(result([
            .object(["name": .string("context"), "description": .string("Show context usage")]),
            .object([
                "name": .string("impact-analysis"),
                "description": .string("Trace callers"),
                "argumentHint": .string("<symbol>"),
            ]),
            .object([
                "name": .string("ponytail:ponytail-help"),
                "description": .string("Quick reference"),
            ]),
        ]))
        #expect(entries == [
            SlashCatalogEntry(name: "context", description: "Show context usage"),
            SlashCatalogEntry(name: "impact-analysis", description: "Trace callers", argumentHint: "<symbol>"),
            SlashCatalogEntry(name: "ponytail:ponytail-help", description: "Quick reference"),
        ])
    }

    /// The sidecar drops the key when the SDK reports an empty hint; a blank one from an older
    /// sidecar must read the same way, so both land on nil rather than an empty suffix in the picker.
    @Test func absentOrBlankArgumentHintBecomesNil() {
        let entries = claudeSlashCatalog(result([
            .object(["name": .string("no-key"), "description": .string("d")]),
            .object(["name": .string("blank"), "description": .string("d"), "argumentHint": .string("")]),
            .object(["name": .string("null-hint"), "description": .string("d"), "argumentHint": .null]),
        ]))
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.argumentHint == nil })
    }

    /// `{"commands":[]}` is the documented answer for a session with nothing to offer — an empty
    /// result, not an error.
    @Test func emptyCommandsArrayYieldsEmptyList() {
        #expect(claudeSlashCatalog(result([])).isEmpty)
    }

    /// Version skew is the only way to get a bad shape here, and it must degrade to "no
    /// suggestions" rather than throw — the caller is an autocomplete surface.
    @Test func malformedPayloadsYieldEmptyList() {
        #expect(claudeSlashCatalog(.object([:])).isEmpty)                        // no `commands`
        #expect(claudeSlashCatalog(.object(["commands": .string("nope")])).isEmpty)   // not an array
        #expect(claudeSlashCatalog(.null).isEmpty)
        #expect(claudeSlashCatalog(.array([])).isEmpty)                          // result not an object
        #expect(claudeSlashCatalog(result([.string("not-an-object")])).isEmpty)
        // Missing/blank `name` → skipped rather than emitted as an unusable "/" command.
        #expect(claudeSlashCatalog(result([
            .object(["description": .string("nameless")]),
            .object(["name": .string(""), "description": .string("blank")]),
        ])).isEmpty)
    }

    /// A row missing only `description` still works — the picker just shows the bare name.
    @Test func missingDescriptionBecomesEmptyString() {
        let entries = claudeSlashCatalog(result([.object(["name": .string("compact")])]))
        #expect(entries == [SlashCatalogEntry(name: "compact", description: "")])
    }

    /// Sessions spawn lazily on the first turn, so a bound-but-idle channel has nobody to ask.
    /// That is an empty list, not an error (`setModel(channelId:)` parity). No sidecar is spawned:
    /// the live-session guard returns before `makeClient` is ever reached.
    @Test func noLiveSessionReturnsEmptyList() async {
        let bridge = DabSessionBridge(store: freshTempStore())
        let entries = await bridge.slashCatalog(channelId: "chan-never-started")
        #expect(entries.isEmpty)
    }
}
