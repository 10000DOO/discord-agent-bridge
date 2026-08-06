import Testing
import Foundation
@testable import DiscordAgentBridge

/// WO-4 — `skills/list` → `SlashCatalogEntry` mapping. Machine-independent: the fixture is the
/// measured 2026-08-05 wire shape (codex 0.146.0 `app-server generate-json-schema`), so no codex
/// child is spawned.
@Suite("Codex slash catalog")
struct CodexSlashCatalogTests {
    /// One `data` group with the fields the schema marks required, plus the optional ones we read.
    private func skillsListResult(_ skills: [JSONValue]) -> JSONValue {
        .object([
            "data": .array([
                .object([
                    "cwd": .string("/ws"),
                    "skills": .array(skills),
                    "errors": .array([]),
                ]),
            ]),
        ])
    }

    private func skill(
        name: String,
        description: String,
        enabled: Bool = true,
        shortDescription: JSONValue? = nil
    ) -> JSONValue {
        var obj: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "enabled": .bool(enabled),
            "path": .string("/ws/.agents/skills/\(name)/SKILL.md"),
            "scope": .string("user"),
        ]
        if let shortDescription {
            obj["interface"] = .object(["shortDescription": shortDescription])
        }
        return .object(obj)
    }

    @Test func dropsDisabledSkills() {
        let entries = codexSlashCatalog(skillsListResult([
            skill(name: "find-skills", description: "Find a skill"),
            skill(name: "orca-cli", description: "Drive Orca", enabled: false),
            skill(name: "orchestration", description: "Coordinate agents"),
        ]))
        #expect(entries.map(\.name) == ["find-skills", "orchestration"])
    }

    @Test func shortDescriptionWinsOverDescription() {
        let entries = codexSlashCatalog(skillsListResult([
            skill(
                name: "computer-use",
                description: "A very long paragraph explaining the whole skill in detail.",
                shortDescription: .string("Operate desktop apps")
            ),
        ]))
        #expect(entries.first?.description == "Operate desktop apps")
    }

    /// Absent, null, and empty `interface.shortDescription` all fall back to `description`.
    @Test func fallsBackToDescriptionWhenNoShortDescription() {
        let entries = codexSlashCatalog(skillsListResult([
            skill(name: "no-interface", description: "from description"),
            skill(name: "null-short", description: "from description", shortDescription: .null),
            skill(name: "empty-short", description: "from description", shortDescription: .string("")),
        ]))
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.description == "from description" })
    }

    /// Namespaced names are sent back verbatim as `/name` — never rewritten or split.
    @Test func keepsNamespacedNameVerbatim() {
        let entries = codexSlashCatalog(skillsListResult([
            skill(name: "browser-use:browser", description: "Drive a browser"),
        ]))
        #expect(entries.first?.name == "browser-use:browser")
    }

    /// codex advertises no argument hint (§3-5-3) — the field is always nil for this backend.
    @Test func argumentHintIsAlwaysNil() {
        let entries = codexSlashCatalog(skillsListResult([
            skill(name: "find-skills", description: "Find a skill", shortDescription: .string("Find a skill")),
        ]))
        #expect(entries.allSatisfy { $0.argumentHint == nil })
    }

    @Test func mergesEveryCwdGroup() {
        let result = JSONValue.object([
            "data": .array([
                .object(["cwd": .string("/a"), "skills": .array([skill(name: "one", description: "1")]), "errors": .array([])]),
                .object(["cwd": .string("/b"), "skills": .array([skill(name: "two", description: "2")]), "errors": .array([])]),
            ]),
        ])
        #expect(codexSlashCatalog(result).map(\.name) == ["one", "two"])
    }

    /// Empty, missing, or wrong-shaped payloads yield an empty list instead of throwing — this
    /// feeds an autocomplete surface that can only ever show "nothing".
    @Test func malformedPayloadsYieldEmptyList() {
        #expect(codexSlashCatalog(.object(["data": .array([])])).isEmpty)
        #expect(codexSlashCatalog(.object([:])).isEmpty)
        #expect(codexSlashCatalog(.null).isEmpty)
        #expect(codexSlashCatalog(.object(["data": .string("nope")])).isEmpty)
        #expect(codexSlashCatalog(skillsListResult([.string("not-an-object")])).isEmpty)
        // Required `name` missing/blank → skipped rather than emitted as an unusable "/" command.
        #expect(codexSlashCatalog(skillsListResult([
            .object(["description": .string("nameless"), "enabled": .bool(true)]),
            .object(["name": .string(""), "description": .string("blank"), "enabled": .bool(true)]),
        ])).isEmpty)
    }

    /// Sessions spawn lazily on the first turn, so a bound-but-idle channel has nobody to ask.
    /// That is an empty list, not an error (`DabSessionBridge.setModel` parity).
    @Test func noLiveSessionReturnsEmptyList() async {
        let bridge = CodexSessionBridge(store: freshTempStore())
        let entries = await bridge.slashCatalog(channelId: "chan-never-started")
        #expect(entries.isEmpty)
    }
}
