import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("parseEnvelope error branches")
struct ParseEnvelopeErrorTests {
    @Test func notObjectThrows() {
        // Valid JSON, but a top-level array is not an envelope object.
        #expect(throws: ProtocolParseError.notObject) {
            _ = try parseEnvelope("[1,2,3]")
        }
    }

    @Test func missingVersionThrows() {
        #expect(throws: ProtocolParseError.unsupportedVersion("missing")) {
            _ = try parseEnvelope(#"{"type":"notify","method":"x"}"#)
        }
    }

    @Test func invalidTypeThrows() {
        do {
            _ = try parseEnvelope(#"{"v":1,"type":"bogus"}"#)
            Issue.record("expected invalidType")
        } catch let err as ProtocolParseError {
            guard case .invalidType = err else {
                Issue.record("expected .invalidType, got \(err)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func validJsonButUndecodableThrowsInvalidJSON() {
        // Passes version + type gates, but id is a number where Envelope expects String → decode fails.
        #expect(throws: ProtocolParseError.invalidJSON) {
            _ = try parseEnvelope(#"{"v":1,"type":"req","id":123}"#)
        }
    }
}

@Suite("SessionStartParams.asParams serialization")
struct SessionStartParamsTests {
    @Test func fullSerialization() {
        let p = SessionStartParams(
            cwd: "/w",
            guildId: "g",
            channelId: "c",
            ownerId: "o",
            model: "m",
            effort: "high",
            permMode: "plan",
            config: .init(allowedTools: ["A", "B"], autoAllowClaudeTools: ["C"], permissionTimeoutSec: 30),
            env: ["K": "v", "N": nil]
        ).asParams()

        #expect(p["cwd"]?.stringValue == "/w")
        #expect(p["guildId"]?.stringValue == "g")
        #expect(p["channelId"]?.stringValue == "c")
        #expect(p["permMode"]?.stringValue == "plan")
        #expect(p["ownerId"]?.stringValue == "o")
        #expect(p["model"]?.stringValue == "m")
        #expect(p["effort"]?.stringValue == "high")

        let cfg = p["config"]?.objectValue
        #expect(cfg?["allowedTools"]?.arrayValue?.count == 2)
        #expect(cfg?["autoAllowClaudeTools"]?.arrayValue?.first?.stringValue == "C")
        #expect(cfg?["permissionTimeoutSec"]?.numberValue == 30)

        let env = p["env"]?.objectValue
        #expect(env?["K"]?.stringValue == "v")
        #expect(env?["N"] == .null) // nil value serializes as JSON null
    }

    @Test func emptyConfigAndOptionalsOmitted() {
        let p = SessionStartParams(
            cwd: "/w", guildId: "g", channelId: "c", permMode: "default", config: .init()
        ).asParams()
        #expect(p["config"] == nil) // all-nil config produces no key
        #expect(p["ownerId"] == nil)
        #expect(p["model"] == nil)
        #expect(p["effort"] == nil)
        #expect(p["env"] == nil)
    }
}

@Suite("SessionStartResult / SessionsListResult parsing")
struct SessionResultParsingTests {
    @Test func startResultVariants() throws {
        let ok = try SessionStartResult(from: .object(["session": .string("s1"), "backendSessionId": .string("b1")]))
        #expect(ok.session == "s1")
        #expect(ok.backendSessionId == "b1")

        let nullBackend = try SessionStartResult(from: .object(["session": .string("s2"), "backendSessionId": .null]))
        #expect(nullBackend.backendSessionId == nil)

        let noBackend = try SessionStartResult(from: .object(["session": .string("s3")]))
        #expect(noBackend.backendSessionId == nil)
    }

    @Test func startResultMissingSessionThrows() {
        #expect(throws: SidecarRpcError.self) {
            _ = try SessionStartResult(from: .object([:]))
        }
        #expect(throws: SidecarRpcError.self) {
            _ = try SessionStartResult(from: .string("not-an-object"))
        }
    }

    @Test func listResultParsesAndSkipsMalformed() throws {
        let list = try SessionsListResult(from: .object(["sessions": .array([
            .object(["sessionId": .string("a"), "cwd": .string("/w"), "label": .string("L"), "updatedAt": .string("t")]),
            .object(["sessionId": .string("b"), "cwd": .string("/x")]),
            .object(["cwd": .string("/y")]), // missing sessionId → dropped
        ])]))
        #expect(list.sessions.count == 2)
        #expect(list.sessions[0].label == "L")
        #expect(list.sessions[0].updatedAt == "t")
        #expect(list.sessions[1].label == nil)
    }

    @Test func listResultResilientToBadInput() throws {
        #expect(try SessionsListResult(from: .object([:])).sessions.isEmpty)
        #expect(try SessionsListResult(from: .string("x")).sessions.isEmpty)
    }
}
