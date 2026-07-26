import Testing
@testable import DiscordAgentBridge

@Suite("FindChrome")
struct FindChromeTests {
    @Test func prefersPuppeteerExecutablePath() {
        let env = [
            "PUPPETEER_EXECUTABLE_PATH": "/fake/chrome-a",
            "CHROME_PATH": "/fake/chrome-b",
        ]
        let path = findChrome(env: env) { $0 == "/fake/chrome-a" || $0 == "/fake/chrome-b" }
        #expect(path == "/fake/chrome-a")
    }

    @Test func fallsBackToChromePath() {
        let env = ["CHROME_PATH": "/fake/chrome-b"]
        let path = findChrome(env: env) { $0 == "/fake/chrome-b" }
        #expect(path == "/fake/chrome-b")
    }

    @Test func returnsNilWhenNothingExists() {
        let path = findChrome(env: [:]) { _ in false }
        #expect(path == nil)
        #expect(chromeAvailable(env: [:], fileExists: { _ in false }) == false)
    }

    @Test func candidatesIncludeSystemPaths() {
        let c = chromeCandidates(env: [:])
        #expect(c.contains("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
        #expect(c.contains("/usr/bin/chromium"))
    }
}
