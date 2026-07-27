import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("JSONValue decode / encode / accessors")
struct JSONValueTests {
    private func decode(_ s: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    private func encodeString(_ v: JSONValue) throws -> String {
        String(data: try JSONEncoder().encode(v), encoding: .utf8)!
    }

    @Test func decodesEachType() throws {
        let root = try decode(#"{"b":true,"i":42,"d":1.5,"s":"hi","arr":[1,2],"obj":{"k":"v"},"n":null}"#)
        guard case .object(let o) = root else {
            Issue.record("expected object")
            return
        }
        #expect(o["b"] == .bool(true))
        #expect(o["i"] == .number(42))
        #expect(o["d"] == .number(1.5))
        #expect(o["s"] == .string("hi"))
        #expect(o["arr"]?.arrayValue?.count == 2)
        #expect(o["obj"]?["k"]?.stringValue == "v")
        #expect(o["n"] == .null)
    }

    @Test func integerNormalizationOnEncode() throws {
        // JSONValue.swift:38-43 — whole doubles encode as integers, fractional stay decimal.
        #expect(try encodeString(.array([.number(42)])) == "[42]")
        #expect(try encodeString(.array([.number(-7)])) == "[-7]")
        #expect(try encodeString(.array([.number(3.5)])) == "[3.5]")
    }

    @Test func integerNormalizationRoundtrips() throws {
        let back = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(JSONValue.array([.number(3.0)])))
        #expect(back == .array([.number(3.0)]))
    }

    @Test func accessorsReturnNilForWrongType() {
        #expect(JSONValue.string("x").numberValue == nil)
        #expect(JSONValue.string("x").boolValue == nil)
        #expect(JSONValue.string("x").objectValue == nil)
        #expect(JSONValue.string("x").arrayValue == nil)
        #expect(JSONValue.number(1).stringValue == nil)
        #expect(JSONValue.bool(true).numberValue == nil)
        #expect(JSONValue.null.stringValue == nil)
        #expect(JSONValue.array([]).objectValue == nil)
        #expect(JSONValue.object([:]).arrayValue == nil)
        #expect(JSONValue.string("x")["k"] == nil) // subscript on non-object
    }

    @Test func nestedSubscriptTraversal() {
        let v: JSONValue = .object([
            "a": .object(["b": .array([.number(0), .object(["c": .string("deep")])])]),
        ])
        let arr = v["a"]?["b"]?.arrayValue
        #expect(arr?.count == 2)
        #expect(arr?[1]["c"]?.stringValue == "deep")
    }
}
