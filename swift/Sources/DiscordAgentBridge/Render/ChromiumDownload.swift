import Foundation

// Native Chromium download (H5 — replaces the npx/@puppeteer/browsers shellout so the
// runtime never needs Node.js). Source: Google's "Chrome for Testing" distribution API
// (https://googlechromelabs.github.io/chrome-for-testing/), which is exactly what
// @puppeteer/browsers itself resolves against — same binaries, no npx required.
//
// Split out of ChromiumProvisioner.swift so the pure pieces (platform id, JSON decode,
// progress-percent/throttle math) are unit-testable without touching the network; only
// `downloadChromiumZip` and `fetchChromeForTestingVersions` do real I/O.

let chromeForTestingMetadataURL = URL(
    string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
)!

/// Chrome for Testing platform id for this host. nil ⇒ unsupported (Windows is a dumb
/// per Q1 — this port only targets macOS mac-arm64/mac-x64 and Linux linux64).
func chromiumPlatformId() -> String? {
    #if os(macOS)
    #if arch(arm64)
    return "mac-arm64"
    #elseif arch(x86_64)
    return "mac-x64"
    #else
    return nil
    #endif
    #elseif os(Linux)
    return "linux64"
    #else
    return nil
    #endif
}

// MARK: - Chrome for Testing JSON

struct ChromeForTestingVersions: Decodable {
    let channels: [String: Channel]

    struct Channel: Decodable {
        let version: String
        let downloads: Downloads
    }

    struct Downloads: Decodable {
        let chrome: [PlatformDownload]
    }

    struct PlatformDownload: Decodable {
        let platform: String
        let url: String
    }
}

/// The Stable download matching `platform` (e.g. "mac-arm64"). nil when the channel or
/// platform entry is missing from the feed.
func chromiumStableDownload(
    from versions: ChromeForTestingVersions,
    platform: String
) -> (url: String, version: String)? {
    guard let stable = versions.channels["Stable"],
          let match = stable.downloads.chrome.first(where: { $0.platform == platform })
    else { return nil }
    return (match.url, stable.version)
}

func fetchChromeForTestingVersions() async throws -> ChromeForTestingVersions {
    let (data, _) = try await URLSession.shared.data(from: chromeForTestingMetadataURL)
    return try JSONDecoder().decode(ChromeForTestingVersions.self, from: data)
}

// MARK: - Download progress (TS `downloadProgressCallback` parity)

/// 0–99 while bytes stream in (100 is reserved for "unzip done" — reported by the caller).
func chromiumDownloadPercent(downloaded: Int64, total: Int64) -> Int {
    guard total > 0 else { return 0 }
    return min(99, Int(Double(downloaded) / Double(total) * 100))
}

/// TS `chromiumProvisioner.ts:106`: only fire onProgress on a new, round-10% value.
func shouldReportChromiumProgress(pct: Int, lastReported: Int) -> Bool {
    pct != lastReported && pct % 10 == 0
}

// MARK: - Download (URLSessionDownloadDelegate, bridged to async/await)

/// Downloads `url` to `destination` (moved atomically from the delegate's temp file),
/// reporting throttled 0–99% progress. Throws on any transport/move failure.
func downloadChromiumZip(
    from url: URL,
    to destination: URL,
    onProgress: (@Sendable (Int) -> Void)?
) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let delegate = ChromiumDownloadDelegate(destination: destination, onProgress: onProgress, continuation: cont)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        // Intentional retain cycle (delegate <-> session): a locally-scoped URLSession isn't
        // guaranteed to outlive this closure otherwise. Broken in didCompleteWithError below.
        delegate.session = session
        session.downloadTask(with: url).resume()
    }
}

private final class ChromiumDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (@Sendable (Int) -> Void)?
    private let continuation: CheckedContinuation<Void, Error>
    private var lastReportedPct = -1
    private var moveError: Error?
    var session: URLSession?

    init(
        destination: URL,
        onProgress: (@Sendable (Int) -> Void)?,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let onProgress else { return }
        let pct = chromiumDownloadPercent(downloaded: totalBytesWritten, total: totalBytesExpectedToWrite)
        guard shouldReportChromiumProgress(pct: pct, lastReported: lastReportedPct) else { return }
        lastReportedPct = pct
        onProgress(pct)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.session = nil }
        session.finishTasksAndInvalidate()
        if let error {
            continuation.resume(throwing: error)
        } else if let moveError {
            continuation.resume(throwing: moveError)
        } else {
            continuation.resume(returning: ())
        }
    }
}
