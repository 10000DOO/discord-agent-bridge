import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - W11-b2 slice3: macOS native folder picker (TS folderPanel.ts parity)
//
// Host-side "choose folder" via osascript (no System Events — avoids TCC Automation).
// Produces a path only; confinement is still DirectoryBrowser.goTo. Injectable `run`
// keeps unit tests free of live GUI.

/// Default host-picker timeout (TS `folderPanelTimeoutMs` = 120s).
public let folderPanelTimeoutMs: Int = 120_000

/// Finder panel prompt (TS `dir.panel.prompt`). A computed property, not a stored
/// constant — a top-level `let` in Swift is lazily computed ONCE and cached forever,
/// which would freeze this at whatever locale was active on first access and never
/// follow a later `I18n.setLocale` (it is read as a default parameter value in
/// `openMacFolderPanel`, e.g. `DabMain.swift`'s native-panel call site).
public var folderPanelPrompt: String { I18n.t("dir.panel.prompt") }

public enum FolderPanelError: Error, Equatable, Sendable {
    case timeout
    case failed(String)
}

/// Outcome of one osascript choose-folder run (pure interpretation for tests).
public enum FolderPanelOutcome: Equatable, Sendable {
    case picked(String)
    case cancelled
    case timeout
    case failed(String)
}

/// Captured child process I/O (injectable for tests).
public struct ProcessCapture: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32?
    public var timedOut: Bool

    public init(stdout: String = "", stderr: String = "", exitCode: Int32? = nil, timedOut: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

/// `(command, args, timeoutMs) → capture`. Production uses `runOsascriptCapture`.
public typealias PanelRunner = @Sendable (String, [String], Int) async -> ProcessCapture

/// AppleScript string literal escape: `\` then `"`.
public func escapeAppleScript(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Build the `osascript -e` script body (choose folder → POSIX path).
public func chooseFolderScript(startDir: String, prompt: String) -> String {
    "POSIX path of (choose folder with prompt \"\(escapeAppleScript(prompt))\""
        + " default location (POSIX file \"\(escapeAppleScript(startDir))\"))"
}

/// Pure mapping from process exit to panel outcome (TS createMacFolderPanelOpener close handler).
public func interpretFolderPanelResult(
    stdout: String,
    stderr: String,
    exitCode: Int32?,
    timedOut: Bool
) -> FolderPanelOutcome {
    if timedOut { return .timeout }
    if exitCode == 0 {
        return .picked(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if stderr.contains("-128") {
        return .cancelled
    }
    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if msg.isEmpty {
        return .failed("osascript exited \(exitCode.map(String.init) ?? "nil")")
    }
    return .failed(msg)
}

/// Open a macOS folder panel. Resolves the picked path, `nil` on Cancel, throws on timeout/error.
/// `run` is injectable — CI never opens a live dialog.
public func openMacFolderPanel(
    startDir: String,
    prompt: String = folderPanelPrompt,
    timeoutMs: Int = folderPanelTimeoutMs,
    run: PanelRunner = runOsascriptCapture
) async throws -> String? {
    let script = chooseFolderScript(startDir: startDir, prompt: prompt)
    let cap = await run("osascript", ["-e", script], timeoutMs)
    switch interpretFolderPanelResult(
        stdout: cap.stdout,
        stderr: cap.stderr,
        exitCode: cap.exitCode,
        timedOut: cap.timedOut
    ) {
    case .picked(let path):
        return path
    case .cancelled:
        return nil
    case .timeout:
        throw FolderPanelError.timeout
    case .failed(let msg):
        throw FolderPanelError.failed(msg)
    }
}

/// Production runner: spawn `command args`, harvest stdout/stderr, SIGKILL on timeout.
public func runOsascriptCapture(
    command: String,
    args: [String],
    timeoutMs: Int
) async -> ProcessCapture {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                cont.resume(returning: ProcessCapture(
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: nil,
                    timedOut: false
                ))
                return
            }

            let box = LockedBox<Process?>(process)
            let timedOutBox = LockedBox(false)
            let timeout = max(0.001, Double(timeoutMs) / 1000.0)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                box.withLock { proc in
                    if let p = proc, p.isRunning {
                        timedOutBox.withLock { $0 = true }
                        // Match TS SIGKILL so the panel actually closes.
                        #if canImport(Darwin)
                        kill(p.processIdentifier, SIGKILL)
                        #else
                        p.terminate()
                        #endif
                    }
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()
            box.withLock { $0 = nil }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            cont.resume(returning: ProcessCapture(
                stdout: stdout,
                stderr: stderr,
                exitCode: process.terminationStatus,
                timedOut: timedOutBox.withLock { $0 }
            ))
        }
    }
}

// MARK: - One panel per channel (TS folderPanels set)

/// Prevents concurrent native pickers on the same wizard channel.
public actor FolderPanelBusy {
    public static let shared = FolderPanelBusy()
    private var busy: Set<String> = []

    public init() {}

    /// true if this channel may open a panel now (and is marked busy).
    public func tryBegin(_ channelId: String) -> Bool {
        if busy.contains(channelId) { return false }
        busy.insert(channelId)
        return true
    }

    public func end(_ channelId: String) {
        busy.remove(channelId)
    }
}
