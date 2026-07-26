import Foundation

/// Host ↔ sidecar byte transport (one line = one NDJSON envelope).
public protocol SidecarTransport: Sendable {
    /// Host → sidecar (write one full line including trailing `\n`).
    func writeLine(_ line: String) async throws
    /// Sidecar → host lines (without trailing newline).
    var lines: AsyncThrowingStream<String, Error> { get }
    /// Bounded stderr capture when the transport supports it (Process); empty for in-memory.
    var stderrBuffer: String { get }
    func close() async
}

// MARK: - Process transport (Foundation.Process)

/// Spawns a child process with stdin/stdout pipes for NDJSON.
public final class ProcessSidecarTransport: SidecarTransport, @unchecked Sendable {
    /// Retain last ~8KB of stderr (TS acpClient STDERR_CAPTURE_CAP).
    private static let stderrCaptureCap = 8 * 1024

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let closed = LockedBox(false)
    /// Rolling stderr bytes (last `stderrCaptureCap`); UTF-8 decoded on read.
    private let stderrData = LockedBox(Data())
    public let lines: AsyncThrowingStream<String, Error>
    private let linesContinuation: AsyncThrowingStream<String, Error>.Continuation

    public var stderrBuffer: String {
        stderrData.withLock { data in
            String(data: data, encoding: .utf8) ?? ""
        }
    }

    public init(spawn: SidecarSpawn, environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.resolveExecutable(spawn.command))
        process.arguments = spawn.args

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        let errHandle = stderrPipe.fileHandleForReading
        let errBox = stderrData
        DispatchQueue.global(qos: .utility).async {
            Self.captureStderr(from: errHandle, into: errBox, cap: Self.stderrCaptureCap)
        }
    }

    /// Drain stderr into a rolling buffer of at most `cap` bytes (last window).
    private static func captureStderr(from handle: FileHandle, into box: LockedBox<Data>, cap: Int) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            box.withLock { data in
                data.append(chunk)
                if data.count > cap {
                    data = Data(data.suffix(cap))
                }
            }
        }
    }

    /// Resolve a bare CLI name (e.g. `grok`) to an absolute path when possible: `PATH` first,
    /// then well-known user/system bin dirs (mirrors TS `resolveCliCommand`, `resolveCli.ts:95-134`).
    /// Needed because launchd/systemd spawn with a minimal `PATH` (no Homebrew/cargo/grok-local
    /// dirs), so a bare command that works in a login shell can fail to resolve here.
    /// `env`/`homeDir`/`isExecutable` are injectable for tests; production call sites (all of
    /// them) pass none and get the real environment.
    static func resolveExecutable(
        _ command: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        homeDir: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if command.contains("/") {
            return command
        }
        let pathDirs = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for dir in pathDirs + wellKnownUserBinDirs(homeDir: homeDir) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(command)
            if isExecutable(candidate.path) {
                return candidate.path
            }
        }
        return command
    }

    /// Well-known user/system bin dirs searched when `PATH` misses (TS `wellKnownUserBinDirs`
    /// mirror, `resolveCli.ts:20-46`). Windows dirs are not ported (out of scope for this build).
    static func wellKnownUserBinDirs(homeDir: String) -> [String] {
        let common = ["\(homeDir)/.local/bin", "\(homeDir)/.grok/bin", "\(homeDir)/.cargo/bin"]
        #if os(macOS)
        return common + ["/opt/homebrew/bin", "/usr/local/bin"]
        #elseif os(Linux)
        return common + ["/usr/local/bin", "/home/linuxbrew/.linuxbrew/bin"]
        #else
        return common
        #endif
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
    /// In-memory pair has no child stderr.
    public var stderrBuffer: String { "" }

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
