import Foundation

/// Host ↔ sidecar byte transport (one line = one NDJSON envelope).
public protocol SidecarTransport: Sendable {
    /// Host → sidecar (write one full line including trailing `\n`).
    func writeLine(_ line: String) async throws
    /// Sidecar → host lines (without trailing newline).
    var lines: AsyncThrowingStream<String, Error> { get }
    func close() async
}

// MARK: - Process transport (Foundation.Process)

/// Spawns a child process with stdin/stdout pipes for NDJSON.
public final class ProcessSidecarTransport: SidecarTransport, @unchecked Sendable {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let closed = LockedBox(false)
    public let lines: AsyncThrowingStream<String, Error>
    private let linesContinuation: AsyncThrowingStream<String, Error>.Continuation

    public init(spawn: SidecarSpawn, environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.resolveExecutable(spawn.command))
        process.arguments = spawn.args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError

        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (k, v) in environment { env[k] = v }
        }
        process.environment = env

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading

        var cont: AsyncThrowingStream<String, Error>.Continuation!
        self.lines = AsyncThrowingStream { continuation in
            cont = continuation
        }
        self.linesContinuation = cont

        try process.run()

        let handle = stdoutHandle
        let continuation = linesContinuation
        DispatchQueue.global(qos: .userInitiated).async {
            Self.readLines(from: handle, into: continuation)
        }
    }

    static func resolveExecutable(_ command: String) -> String {
        if command.contains("/") {
            return command
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return command
    }

    private static func readLines(
        from handle: FileHandle,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if let last = flushNDJSON(buffer: &buffer) {
                    continuation.yield(last)
                }
                continuation.finish()
                return
            }
            for line in splitNDJSON(chunk: chunk, buffer: &buffer) {
                continuation.yield(line)
            }
        }
    }

    /// Append `chunk` to `buffer` and return every complete `\n`-terminated line.
    /// Strips a trailing `\r` (CRLF), skips empty lines; a trailing partial line stays in `buffer`.
    static func splitNDJSON(chunk: Data, buffer: inout Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let s = String(data: lineData, encoding: .utf8) {
                let line = s.hasSuffix("\r") ? String(s.dropLast()) : s
                if !line.isEmpty {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    /// Flush the buffered partial line at EOF (no trailing newline). Empties `buffer`.
    /// Returns nil when the buffer is empty, undecodable, or blank after trimming newlines.
    static func flushNDJSON(buffer: inout Data) -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func writeLine(_ line: String) async throws {
        let isClosed = closed.withLock { $0 }
        if isClosed { throw SidecarRpcError(code: "internal", message: "transport closed") }
        var data = Data(line.utf8)
        if !line.hasSuffix("\n") {
            data.append(0x0A)
        }
        try stdinHandle.write(contentsOf: data)
    }

    public func close() async {
        closed.withLock { $0 = true }
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
        linesContinuation.finish()
    }
}

// MARK: - Duplex in-memory transport (tests)

/// Pair of linked transports for unit tests (A.writes → B.lines and vice versa).
public final class InMemorySidecarTransport: SidecarTransport, @unchecked Sendable {
    private struct State {
        var closed = false
        var peerWrite: ((String) -> Void)?
    }

    private let state = LockedBox(State())
    public let lines: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    public init() {
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        self.lines = AsyncThrowingStream { c in cont = c }
        self.continuation = cont
    }

    /// Connect two transports so each writeLine appears on the other's lines stream.
    public static func makePair() -> (host: InMemorySidecarTransport, sidecar: InMemorySidecarTransport) {
        let host = InMemorySidecarTransport()
        let sidecar = InMemorySidecarTransport()
        host.state.withLock { $0.peerWrite = { [weak sidecar] line in
            sidecar?.deliver(line)
        }}
        sidecar.state.withLock { $0.peerWrite = { [weak host] line in
            host?.deliver(line)
        }}
        return (host, sidecar)
    }

    private func deliver(_ line: String) {
        let closed = state.withLock { $0.closed }
        if closed { return }
        let trimmed = line.trimmingCharacters(in: .newlines)
        if !trimmed.isEmpty {
            continuation.yield(trimmed)
        }
    }

    public func writeLine(_ line: String) async throws {
        let (closed, peer) = state.withLock { ($0.closed, $0.peerWrite) }
        if closed { throw SidecarRpcError(code: "internal", message: "transport closed") }
        peer?(line)
    }

    public func close() async {
        state.withLock { $0.closed = true }
        continuation.finish()
    }
}
