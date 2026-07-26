import Foundation

// Chromium provisioning (TS `chromiumProvisioner.ts`).
// System Chrome is preferred; otherwise optional download under cache — natively, via the
// Chrome for Testing distribution API (see ChromiumDownload.swift; H5: no Node/npx needed).
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

    // MARK: - Default install via Chrome for Testing (native download, no Node/npx)

    private static func defaultDownloadAndExtract(
        cacheDir: String,
        onProgress: (@Sendable (Int) -> Void)?,
        logger: (@Sendable (String) -> Void)?
    ) async throws {
        let fm = FileManager.default
        guard let platform = chromiumPlatformId() else {
            throw ChromiumProvisionError.unsupportedPlatform
        }

        let versions: ChromeForTestingVersions
        do {
            versions = try await fetchChromeForTestingVersions()
        } catch {
            throw ChromiumProvisionError.metadataFetchFailed
        }
        guard let match = chromiumStableDownload(from: versions, platform: platform),
              let downloadURL = URL(string: match.url)
        else {
            throw ChromiumProvisionError.metadataFetchFailed
        }

        let chromeDir = (cacheDir as NSString).appendingPathComponent("chrome")
        try fm.createDirectory(atPath: chromeDir, withIntermediateDirectories: true)
        let zipPath = (chromeDir as NSString).appendingPathComponent("\(platform)-\(match.version).zip")

        logger?("chromium: downloading \(match.url)")
        do {
            try await downloadChromiumZip(from: downloadURL, to: URL(fileURLWithPath: zipPath), onProgress: onProgress)
        } catch {
            throw ChromiumProvisionError.downloadFailed
        }

        // destDir layout matches scanProvisioned's expectations: the zip's own top-level
        // entry is already `<platform>/...`, so unzipping into `chrome/<platform>-<version>`
        // reproduces exactly `chrome/<dir>/chrome-mac-arm64/...` etc.
        let destDir = (chromeDir as NSString).appendingPathComponent("\(platform)-\(match.version)")
        try? fm.removeItem(atPath: destDir) // drop any broken stub from a prior failed attempt
        let ok = await runProcess(executable: "/usr/bin/unzip", args: ["-q", "-o", zipPath, "-d", destDir], timeoutSec: 120)
        try? fm.removeItem(atPath: zipPath)
        guard ok else {
            throw ChromiumProvisionError.installFailed
        }
        onProgress?(100)
        guard scanProvisioned(cacheDir: cacheDir) != nil else {
            throw ChromiumProvisionError.noExecutable
        }
        logger?("chromium provisioned under \(destDir)")
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
    case unsupportedPlatform
    case metadataFetchFailed
    case downloadFailed
    case installFailed
    case noExecutable

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "chromium download is unsupported on this platform (macOS mac-arm64/mac-x64 or Linux linux64 only)"
        case .metadataFetchFailed:
            return "failed to fetch Chrome for Testing version metadata"
        case .downloadFailed:
            return "chromium download failed"
        case .installFailed:
            return "chromium download/install failed"
        case .noExecutable:
            return "chromium install produced no executable"
        }
    }
}
