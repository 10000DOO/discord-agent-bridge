import Testing
import Foundation
@testable import DiscordAgentBridge

/// Pure NDJSON framing extracted from ProcessSidecarTransport.readLines.
@Suite("NDJSON framing")
struct TransportFramingTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func multipleLinesInOneChunk() {
        var buffer = Data()
        let lines = ProcessSidecarTransport.splitNDJSON(chunk: bytes("a\nb\nc\n"), buffer: &buffer)
        #expect(lines == ["a", "b", "c"])
        #expect(buffer.isEmpty)
    }

    @Test func chunkBoundarySplit() {
        // A line split across two chunks must not emit until the newline arrives.
        var buffer = Data()
        let first = ProcessSidecarTransport.splitNDJSON(chunk: bytes("hel"), buffer: &buffer)
        #expect(first.isEmpty)
        #expect(!buffer.isEmpty)
        let second = ProcessSidecarTransport.splitNDJSON(chunk: bytes("lo\nworld\n"), buffer: &buffer)
        #expect(second == ["hello", "world"])
        #expect(buffer.isEmpty)
    }

    @Test func crlfStripped() {
        var buffer = Data()
        let lines = ProcessSidecarTransport.splitNDJSON(chunk: bytes("a\r\nb\r\n"), buffer: &buffer)
        #expect(lines == ["a", "b"])
    }

    @Test func emptyLinesSkipped() {
        var buffer = Data()
        let lines = ProcessSidecarTransport.splitNDJSON(chunk: bytes("\n\nx\n\n"), buffer: &buffer)
        #expect(lines == ["x"])
    }

    @Test func partialLineHeldUntilNewline() {
        var buffer = Data()
        let lines = ProcessSidecarTransport.splitNDJSON(chunk: bytes("no newline yet"), buffer: &buffer)
        #expect(lines.isEmpty)
        // Still buffered — not lost.
        #expect(String(data: buffer, encoding: .utf8) == "no newline yet")
    }

    @Test func flushEmitsTrailingLineAtEOF() {
        var buffer = Data(bytes("trailing"))
        let last = ProcessSidecarTransport.flushNDJSON(buffer: &buffer)
        #expect(last == "trailing")
        #expect(buffer.isEmpty)
    }

    @Test func flushStripsTrailingNewline() {
        var buffer = Data(bytes("done\n"))
        #expect(ProcessSidecarTransport.flushNDJSON(buffer: &buffer) == "done")
    }

    @Test func flushEmptyBufferReturnsNil() {
        var buffer = Data()
        #expect(ProcessSidecarTransport.flushNDJSON(buffer: &buffer) == nil)
        var blank = Data(bytes("\n\n"))
        #expect(ProcessSidecarTransport.flushNDJSON(buffer: &blank) == nil)
    }
}
