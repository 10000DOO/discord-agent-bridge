import Foundation

// Chrome/Chromium detection (TS `chrome.ts`). Kept separate so callers can check
// availability without constructing BrowserImageRenderer.

/// Candidate browser executables (env overrides first). Order matches TS + CHROME_PATH.
public func chromeCandidates(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    var list: [String] = []
    if let p = env["PUPPETEER_EXECUTABLE_PATH"], !p.isEmpty { list.append(p) }
    if let p = env["CHROME_PATH"], !p.isEmpty { list.append(p) }
    list.append(contentsOf: [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
    ])
    return list
}

/// First existing candidate, or nil.
public func findChrome(
    env: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    for c in chromeCandidates(env: env) {
        if fileExists(c) { return c }
    }
    return nil
}

/// Session-start / render gate: true when a system browser path exists.
public func chromeAvailable(
    env: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> Bool {
    findChrome(env: env, fileExists: fileExists) != nil
}
