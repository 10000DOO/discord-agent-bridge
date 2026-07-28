import Foundation

// Pure semver helpers for the auto-updater (TS `src/update/version.ts`).
// No side effects; fully unit-tested. Build metadata is parsed but ignored (semver precedence).

public struct SemVer: Sendable, Equatable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated prerelease identifiers (`[]` for a stable release).
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }
}

/// Parse `MAJOR.MINOR.PATCH[-pre][+build]`. Returns nil for malformed input.
public func parseVersion(_ v: String) -> SemVer? {
    let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let regex = try? NSRegularExpression(
        pattern: #"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$"#
    ) else { return nil }
    let ns = trimmed as NSString
    guard let m = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges >= 4,
          let major = Int(ns.substring(with: m.range(at: 1))),
          let minor = Int(ns.substring(with: m.range(at: 2))),
          let patch = Int(ns.substring(with: m.range(at: 3)))
    else { return nil }
    var pre: [String] = []
    if m.range(at: 4).location != NSNotFound {
        let preStr = ns.substring(with: m.range(at: 4))
        if !preStr.isEmpty { pre = preStr.split(separator: ".").map(String.init) }
    }
    return SemVer(major: major, minor: minor, patch: patch, prerelease: pre)
}

/// Compare prerelease lists per semver §11. Returns -1/0/1.
private func comparePrerelease(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty && b.isEmpty { return 0 }
    if a.isEmpty { return 1 }  // stable outranks prerelease
    if b.isEmpty { return -1 }
    let len = min(a.count, b.count)
    for i in 0..<len {
        let ai = a[i]
        let bi = b[i]
        let an = ai.range(of: #"^\d+$"#, options: .regularExpression) != nil
        let bn = bi.range(of: #"^\d+$"#, options: .regularExpression) != nil
        if an && bn {
            let diff = (Int(ai) ?? 0) - (Int(bi) ?? 0)
            if diff != 0 { return diff < 0 ? -1 : 1 }
        } else if an != bn {
            return an ? -1 : 1  // numeric ranks below non-numeric
        } else if ai != bi {
            return ai < bi ? -1 : 1
        }
    }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
}

/// Total ordering: core then prerelease. -1 when a < b, 0 equal, 1 when a > b.
public func compareVersions(_ a: SemVer, _ b: SemVer) -> Int {
    if a.major != b.major { return a.major < b.major ? -1 : 1 }
    if a.minor != b.minor { return a.minor < b.minor ? -1 : 1 }
    if a.patch != b.patch { return a.patch < b.patch ? -1 : 1 }
    return comparePrerelease(a.prerelease, b.prerelease)
}

/// True only when `latest` is a STABLE release strictly greater than `current`.
public func isNewerStable(current: String, latest: String) -> Bool {
    guard let c = parseVersion(current), let l = parseVersion(latest) else { return false }
    if !l.prerelease.isEmpty { return false }
    return compareVersions(l, c) > 0
}

/// Running dab version: `DAB_VERSION` env, else a compile-time default (keep in sync with package.json when possible).
public func readAppVersion() -> String {
    if let env = ProcessInfo.processInfo.environment["DAB_VERSION"], !env.isEmpty {
        return env
    }
    return AppVersion.defaultValue
}

public enum AppVersion {
    /// Mirrors TS package.json version when the Swift port tracks the same release line.
    public static let defaultValue = "2.1.0"
}
