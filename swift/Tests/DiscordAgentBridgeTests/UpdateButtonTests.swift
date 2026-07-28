import Testing
@testable import DiscordAgentBridge

@Suite("buildUpdateId / parseUpdateId")
struct UpdateIdTests {
    @Test func roundTrips() {
        #expect(parseUpdateId(buildUpdateId(action: .approve, version: "1.2.3"))?.action == .approve)
        #expect(parseUpdateId(buildUpdateId(action: .approve, version: "1.2.3"))?.version == "1.2.3")
        #expect(parseUpdateId(buildUpdateId(action: .dismiss, version: "0.13.0"))?.action == .dismiss)
    }

    @Test func foreignPrefixNil() {
        #expect(parseUpdateId("perm:abc:allow") == nil)
        #expect(parseUpdateId("interrupt:g:c") == nil)
    }

    @Test func unknownActionNil() {
        #expect(parseUpdateId("dab-update:install:1.2.3") == nil)
    }

    @Test func malformedNil() {
        #expect(parseUpdateId("dab-update:approve") == nil)
        #expect(parseUpdateId("dab-update:approve:1.2.3:extra") == nil)
        #expect(parseUpdateId("dab-update:approve:") == nil)
        #expect(parseUpdateId("dab-update:decided") == nil)
    }
}

@Suite("buildUpdatePrompt / decided")
struct UpdatePromptTests {
    @Test func yesNoRow() {
        let (embed, rows) = buildUpdatePrompt(version: "1.1.0", currentVersion: "1.0.0")
        #expect(!embed.title.isEmpty)
        #expect(embed.description.contains("1.1.0"))
        #expect(embed.description.contains("1.0.0"))
        #expect(rows.count == 1)
        let buttons = rows[0].components
        #expect(buttons.map(\.customId) == ["dab-update:approve:1.1.0", "dab-update:dismiss:1.1.0"])
        #expect(buttons.map(\.style) == [.success, .secondary])
        #expect(buttons.allSatisfy { !$0.disabled })
    }

    @Test func decidedRowDisabled() {
        for action: UpdateAction in [.approve, .dismiss] {
            let row = buildUpdateDecidedRow(action: action)
            #expect(row.components.count == 1)
            #expect(row.components[0].disabled)
            #expect(parseUpdateId(row.components[0].customId) == nil)
        }
    }
}

@Suite("buildTurnTimeoutId / parseTurnTimeoutId")
struct TurnTimeoutIdTests {
    @Test func roundTrips() {
        #expect(parseTurnTimeoutId(buildTurnTimeoutId(action: .confirm)) == .confirm)
        #expect(parseTurnTimeoutId(buildTurnTimeoutId(action: .dismiss)) == .dismiss)
    }

    @Test func foreignPrefixNil() {
        #expect(parseTurnTimeoutId("dab-update:approve:1.2.3") == nil)
        #expect(parseTurnTimeoutId("perm:abc:allow") == nil)
    }

    @Test func malformedNil() {
        #expect(parseTurnTimeoutId("dab-turn-timeout") == nil)
        #expect(parseTurnTimeoutId("dab-turn-timeout:confirm:extra") == nil)
        #expect(parseTurnTimeoutId("dab-turn-timeout:unknown") == nil)
        #expect(parseTurnTimeoutId("dab-turn-timeout:decided") == nil)
    }
}

@Suite("buildTurnTimeoutRetryRow / buildTurnTimeoutDecidedRow")
struct TurnTimeoutPromptTests {
    @Test func retryRowYesNo() {
        let row = buildTurnTimeoutRetryRow()
        #expect(row.components.count == 2)
        #expect(row.components.map(\.customId) == ["dab-turn-timeout:confirm", "dab-turn-timeout:dismiss"])
        #expect(row.components.map(\.style) == [.success, .secondary])
        #expect(row.components.allSatisfy { !$0.disabled })
    }

    @Test func decidedRowDisabled() {
        for action: TurnTimeoutAction in [.confirm, .dismiss] {
            let row = buildTurnTimeoutDecidedRow(action: action)
            #expect(row.components.count == 1)
            #expect(row.components[0].disabled)
            #expect(parseTurnTimeoutId(row.components[0].customId) == nil)
        }
    }
}
