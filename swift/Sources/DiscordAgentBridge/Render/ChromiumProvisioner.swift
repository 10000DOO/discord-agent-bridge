import Foundation

// Chromium provisioning (TS `chromiumProvisioner.ts`).
// System Chrome is preferred; otherwise optional download under cache via
// `npx @puppeteer/browsers install chrome@stable --path CACHE` when node is available.
// Concurrent install() callers join a single in-flight promise.

/// Injectable provision step (tests create a fake launchable binary without downloading).
public typealias ChromiumProvisionFn = @Sendable (
    _ cacheDir: String,
    _ onProgress: (@Sendable (Int) -> Void)?
) async throws -> Void

public struct ChromiumProvisionerDeps: Sendable {
    public var cacheDir: String
    public var systemChrome: @Sendable () -> String?
    public var provisionFn: ChromiumProvisionFn?
    public var logger: (@Sendable (String) -> Void)?

    public init(
        cacheDir: String,
        systemChrome: @escaping @Sendable () -> String? = { findChrome() },
        provisionFn: ChromiumProvisionFn? = nil,
        logger: (@Sendable (String) -> Void)? = nil
    ) {
        self.cacheDir = cacheDir
        self.systemChrome = systemChrome
        self.provisionFn = provisionFn
        self.logger = logger
    }
}

public actor ChromiumProvisioner {
    private let cacheDir: String
    private let systemChrome: @Sendable () -> String?
    private let provisionFn: ChromiumProvisionFn
    private let logger: (@Sendable (String) -> Void)?
    /// In-flight install: concurrent callers join this task.
    private var installing: Task<String, Error>?

    public init(deps: ChromiumProvisionerDeps) {
        self.cacheDir = deps.cacheDir
        self.systemChrome = deps.systemChrome
        self.logger = deps.logger
        if let fn = deps.provisionFn {
            self.provisionFn = fn
        } else {
            let cache = deps.cacheDir
            let log = deps.logger
            self.provisionFn = { _, onProgress in
                try await Self.defaultDownloadAndExtract(
                    cacheDir: cache,
                    onProgress: onProgress,
                    logger: log
                )
            }
        }
    }

    /// Prefer system Chrome; else a previously provisioned binary under cacheDir.
    public func executablePath() -> String? {
        systemChrome() ?? provisionedPath()
    }

    /// True when something launchable exists (system or provisioned).
    public func isInstalled() -> Bool {
        executablePath() != nil
    }

    /// Download Chromium when nothing is available. No-op when already present.
    /// Concurrent callers share one in-flight install. Throws on failure.
    public func install(onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> String {
        if let existing = executablePath() { return existing }
        if let task = installing {
            return try await task.value
        }
        let task = Task<String, Error> {
            try await self.runInstall(onProgress: onProgress)
        }
        installing = task
        defer { installing = nil }
        return try await task.value
    }

    private func runInstall(onProgress: (@Sendable (Int) -> Void)?) async throws -> String {
        try await provisionFn(cacheDir, onProgress)
        guard let exe = provisionedPath() else {
            throw ChromiumProvisionError.noExecutable
        }
        return exe
    }

    /// Scan cache for a downloaded Chromium executable (cross-platform layout).
    public func provisionedPath() -> String? {
        Self.scanProvisioned(cacheDir: cacheDir)
    }

    public static func scanProvisioned(cacheDir: String) -> String? {
        let fm = FileManager.default
        let base = (cacheDir as NSString).appendingPathComponent("chrome")
        guard fm.fileExists(atPath: base) else { return nil }
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for dir in dirs {
            let inner = (base as NSString).appendingPathComponent(dir)
            let candidates = [
                (inner as NSString).appendingPathComponent(
                    "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
                ),
                (inner as NSString).appendingPathComponent(
                    "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
                ),
                (inner as NSString).appendingPathComponent("chrome-linux64/chrome"),
                (inner as NSString).appendingPathComponent("chrome-win64/chrome.exe"),
                // Flat layouts some extractors produce:
                (inner as NSString).appendingPathComponent(
                    "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
                ),
                (inner as NSString).appendingPathComponent("chrome"),
                (inner as NSString).appendingPathComponent("chrome.exe"),
            ]
            for c in candidates where fm.fileExists(atPath: c) {
                return c
            }
        }
        return nil
    }

    /// Default cache: `DAB_CHROMIUM_CACHE` → `DAB_HOME/chromium` → `~/.dab/chromium`.
    public static func defaultCacheDir(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let c = env["DAB_CHROMIUM_CACHE"], !c.isEmpty { return c }
        if let home = env["DAB_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("chromium")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".dab/chromium")
    }

    public static func cacheDirFor(appHome: String) -> String {
        (appHome as NSString).appendingPathComponent("chromium")
    }

    // MARK: - Default install via npx @puppeteer/browsers

    private static func defaultDownloadAndExtract(
        cacheDir: String,
        onProgress: (@Sendable (Int) -> Void)?,
        logger: (@Sendable (String) -> Void)?
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: cacheDir,
            withIntermediateDirectories: true
        )
        onProgress?(5)

        // Prefer project-local npx when node_modules exists; else PATH npx/node.
        let npx = resolveNpx()
        guard let npx else {
            throw ChromiumProvisionError.nodeUnavailable
        }

        logger?("chromium: installing via \(npx) @puppeteer/browsers …")
        onProgress?(10)

        let ok = await runProcess(
            executable: npx,
            args: [
                "--yes",
                "@puppeteer/browsers",
                "install",
                "chrome@stable",
                "--path",
                cacheDir,
            ],
            timeoutSec: 600
        )
        guard ok else {
            throw ChromiumProvisionError.installFailed
        }
        onProgress?(100)
        if scanProvisioned(cacheDir: cacheDir) == nil {
            // npx may nest differently — accept any chrome binary under cacheDir.
            if let found = findAnyChromeBinary(under: cacheDir) {
                logger?("chromium: found at \(found)")
                return
            }
            throw ChromiumProvisionError.noExecutable
        }
        logger?("chromium provisioned under \(cacheDir)")
    }

    private static func resolveNpx() -> String? {
        let fm = FileManager.default
        if let root = findRepoRoot() {
            let local = root.appendingPathComponent("node_modules/.bin/npx").path
            if fm.isExecutableFile(atPath: local) { return local }
        }
        // PATH lookup
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in pathEnv.split(separator: ":") {
            let p = "\(dir)/npx"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // node + npx module fallback
        for dir in pathEnv.split(separator: ":") {
            let p = "\(dir)/node"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func findAnyChromeBinary(under root: String) -> String? {
        let fm = FileManager.default
        let names = [
            "Google Chrome for Testing",
            "chrome",
            "chrome.exe",
            "Chromium",
            "google-chrome",
        ]
        guard let enumerator = fm.enumerator(atPath: root) else { return nil }
        while let rel = enumerator.nextObject() as? String {
            let base = (rel as NSString).lastPathComponent
            if names.contains(base) {
                let full = (root as NSString).appendingPathComponent(rel)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                    return full
                }
            }
        }
        return nil
    }

    private static func runProcess(
        executable: String,
        args: [String],
        timeoutSec: Int
    ) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                // When executable is `node`, we'd need different args — npx path only.
                proc.arguments = args
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: false)
                    return
                }
                let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
                while proc.isRunning {
                    if Date() > deadline {
                        proc.terminate()
                        cont.resume(returning: false)
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
                cont.resume(returning: proc.terminationStatus == 0)
            }
        }
    }
}

public enum ChromiumProvisionError: Error, CustomStringConvertible, Sendable {
    case nodeUnavailable
    case installFailed
    case noExecutable

    public var description: String {
        switch self {
        case .nodeUnavailable:
            return "node/npx not found — install Node.js or place Chrome on the system PATH"
        case .installFailed:
            return "chromium download/install failed"
        case .noExecutable:
            return "chromium install produced no executable"
        }
    }
}
