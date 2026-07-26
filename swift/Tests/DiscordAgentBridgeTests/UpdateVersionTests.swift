import Testing
@testable import DiscordAgentBridge

@Suite("parseVersion")
struct ParseVersionTests {
    @Test func plainRelease() {
        #expect(parseVersion("1.2.3") == SemVer(major: 1, minor: 2, patch: 3, prerelease: []))
    }

    @Test func prereleaseIdentifiers() {
        #expect(parseVersion("1.2.3-beta.1") == SemVer(major: 1, minor: 2, patch: 3, prerelease: ["beta", "1"]))
    }

    @Test func ignoresBuildMetadata() {
        #expect(parseVersion("1.2.3+build.7") == SemVer(major: 1, minor: 2, patch: 3, prerelease: []))
        #expect(parseVersion("1.2.3-rc.1+build.7") == SemVer(major: 1, minor: 2, patch: 3, prerelease: ["rc", "1"]))
    }

    @Test func trimsWhitespace() {
        #expect(parseVersion("  0.12.0 ") == SemVer(major: 0, minor: 12, patch: 0, prerelease: []))
    }

    @Test func malformedReturnsNil() {
        for bad in ["", "v1.2.3", "1.2", "1.2.3.4", "latest", "1.x.0", "abc"] {
            #expect(parseVersion(bad) == nil)
        }
    }
}

@Suite("compareVersions")
struct CompareVersionsTests {
    private func v(_ s: String) -> SemVer { parseVersion(s)! }

    @Test func ordersCore() {
        #expect(compareVersions(v("1.0.0"), v("2.0.0")) == -1)
        #expect(compareVersions(v("1.2.0"), v("1.1.0")) == 1)
        #expect(compareVersions(v("1.1.1"), v("1.1.2")) == -1)
        #expect(compareVersions(v("1.1.1"), v("1.1.1")) == 0)
    }

    @Test func prereleaseBelowRelease() {
        #expect(compareVersions(v("1.2.3-beta.1"), v("1.2.3")) == -1)
        #expect(compareVersions(v("1.2.3"), v("1.2.3-beta.1")) == 1)
    }

    @Test func prereleaseIdentifiersOrder() {
        #expect(compareVersions(v("1.0.0-alpha.1"), v("1.0.0-alpha.2")) == -1)
        #expect(compareVersions(v("1.0.0-alpha"), v("1.0.0-beta")) == -1)
        #expect(compareVersions(v("1.0.0-1"), v("1.0.0-alpha")) == -1)
        #expect(compareVersions(v("1.0.0-alpha"), v("1.0.0-alpha.1")) == -1)
    }
}

@Suite("isNewerStable")
struct IsNewerStableTests {
    @Test func trueOnlyForNewerStable() {
        #expect(isNewerStable(current: "0.12.0", latest: "0.12.1"))
        #expect(isNewerStable(current: "0.12.0", latest: "0.13.0"))
        #expect(isNewerStable(current: "0.12.0", latest: "1.0.0"))
    }

    @Test func falseForEqualOrOlder() {
        #expect(!isNewerStable(current: "0.12.0", latest: "0.12.0"))
        #expect(!isNewerStable(current: "0.12.0", latest: "0.11.9"))
        #expect(!isNewerStable(current: "1.0.0", latest: "0.99.99"))
    }

    @Test func falseForPrereleaseLatest() {
        #expect(!isNewerStable(current: "0.12.0", latest: "0.13.0-beta.1"))
        #expect(!isNewerStable(current: "0.12.0", latest: "1.0.0-rc.1"))
    }

    @Test func falseForUnparseable() {
        #expect(!isNewerStable(current: "not-a-version", latest: "0.13.0"))
        #expect(!isNewerStable(current: "0.12.0", latest: "latest"))
    }
}
