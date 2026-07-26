import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("ChromiumDownload")
struct ChromiumDownloadTests {
    // MARK: - platform id

    @Test func platformIdIsOneOfTheSupportedValuesOrNil() {
        // Host-dependent (macOS arm64/x64, Linux, or nil elsewhere) — assert it's never a
        // typo'd value (e.g. "linix64") rather than asserting a specific host.
        let supported: Set<String?> = ["mac-arm64", "mac-x64", "linux64", nil]
        #expect(supported.contains(chromiumPlatformId()))
    }

    // MARK: - JSON decode (Chrome for Testing "last-known-good-versions-with-downloads" shape)

    private let fixture = """
    {
      "timestamp": "2026-01-01T00:00:00Z",
      "channels": {
        "Stable": {
          "channel": "Stable",
          "version": "151.0.7922.47",
          "revision": "abc123",
          "downloads": {
            "chrome": [
              {"platform": "linux64", "url": "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.47/linux64/chrome-linux64.zip"},
              {"platform": "mac-arm64", "url": "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.47/mac-arm64/chrome-mac-arm64.zip"},
              {"platform": "mac-x64", "url": "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.47/mac-x64/chrome-mac-x64.zip"}
            ],
            "chromedriver": [
              {"platform": "linux64", "url": "https://example.invalid/chromedriver-linux64.zip"}
            ]
          }
        },
        "Beta": {
          "channel": "Beta",
          "version": "152.0.0.0",
          "revision": "def456",
          "downloads": { "chrome": [] }
        }
      }
    }
    """

    @Test func decodesStableChromeDownloadsIgnoringUnusedFields() throws {
        let versions = try JSONDecoder().decode(ChromeForTestingVersions.self, from: Data(fixture.utf8))
        #expect(versions.channels["Stable"]?.version == "151.0.7922.47")
        #expect(versions.channels["Stable"]?.downloads.chrome.count == 3)
    }

    @Test func stableDownloadResolvesUrlAndVersionForKnownPlatform() throws {
        let versions = try JSONDecoder().decode(ChromeForTestingVersions.self, from: Data(fixture.utf8))
        let match = chromiumStableDownload(from: versions, platform: "mac-arm64")
        #expect(match?.version == "151.0.7922.47")
        #expect(match?.url == "https://storage.googleapis.com/chrome-for-testing-public/151.0.7922.47/mac-arm64/chrome-mac-arm64.zip")
    }

    @Test func stableDownloadIsNilForUnknownPlatform() throws {
        let versions = try JSONDecoder().decode(ChromeForTestingVersions.self, from: Data(fixture.utf8))
        #expect(chromiumStableDownload(from: versions, platform: "win64") == nil)
    }

    // MARK: - progress percent + throttle (TS `downloadProgressCallback` parity)

    @Test func downloadPercentFloorsAndCapsAt99() {
        #expect(chromiumDownloadPercent(downloaded: 0, total: 100) == 0)
        #expect(chromiumDownloadPercent(downloaded: 55, total: 100) == 55)
        #expect(chromiumDownloadPercent(downloaded: 999, total: 1000) == 99)
        #expect(chromiumDownloadPercent(downloaded: 1000, total: 1000) == 99) // 100 is reserved for post-unzip
        #expect(chromiumDownloadPercent(downloaded: 10, total: 0) == 0) // no total yet
    }

    @Test func progressOnlyReportsOnNewRoundTenPercent() {
        #expect(shouldReportChromiumProgress(pct: 10, lastReported: -1))
        #expect(shouldReportChromiumProgress(pct: 20, lastReported: 10))
        #expect(!shouldReportChromiumProgress(pct: 15, lastReported: 10)) // not a round 10%
        #expect(!shouldReportChromiumProgress(pct: 20, lastReported: 20)) // no change
    }
}
