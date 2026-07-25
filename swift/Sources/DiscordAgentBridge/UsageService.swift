import Foundation

// Claude usage/limits poller (TS `src/core/usageService.ts`). Polls the Anthropic OAuth
// usage endpoint for 5-hour + weekly limits. File credentials first, macOS Keychain
// fallback. NEVER throws into callers. Codex → `codexUsageUnavailable()`.

// MARK: - Public snapshot shapes

public struct UsageLimit: Sendable, Equatable {
    public var utilization: Double // 0-100
    public var resetsAt: String?

    public init(utilization: Double, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var fiveHour: UsageLimit?
    public var sevenDay: UsageLimit?
    public var sevenDayOpus: UsageLimit?
    public var sevenDaySonnet: UsageLimit?
    public var fetchedAt: Double // epoch ms

    public init(
        fiveHour: UsageLimit? = nil,
        sevenDay: UsageLimit? = nil,
        sevenDayOpus: UsageLimit? = nil,
        sevenDaySonnet: UsageLimit? = nil,
        fetchedAt: Double
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.fetchedAt = fetchedAt
    }
}

public enum UsageUnavailableReason: String, Sendable, Equatable {
    case noCredentials = "no-credentials"
    case codexUnsupported = "codex-unsupported"
}

public struct UsageUnavailable: Sendable, Equatable {
    public var available: Bool // always false
    public var reason: UsageUnavailableReason

    public init(reason: UsageUnavailableReason) {
        self.available = false
        self.reason = reason
    }
}

public enum UsageResult: Sendable, Equatable {
    case snapshot(UsageSnapshot)
    case unavailable(UsageUnavailable)

    public var isSnapshot: Bool {
        if case .snapshot = self { return true }
        return false
    }
}

/// Codex usage is structurally unsupported (no limits API in CLI).
public func codexUsageUnavailable() -> UsageResult {
    .unavailable(UsageUnavailable(reason: .codexUnsupported))
}

// MARK: - HTTP + credential seams (injectable for tests)

public protocol UsageHTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionUsageHTTP: UsageHTTPPerforming {
    public init() {}

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

// MARK: - Constants (TS usageService.ts)

private let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
private let usageAPIURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
private let oauthBetaHeader = "oauth-2025-04-20"
private let refreshSkewMs: Double = 300_000
private let backoffMultiplier: Double = 2
private let maxBackoffMs: Double = 600_000
private let keychainService = "Claude Code-credentials"

private enum CredentialSource: String {
    case file
    case keychain
}

private struct OAuthCredentials {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Double // epoch ms
    var source: CredentialSource
}

// MARK: - ClaudeUsageService

/// Claude OAuth usage poller. Actor so cache + backoff are race-safe.
public actor ClaudeUsageService {
    public static let shared = ClaudeUsageService()

    private let userAgent: String
    private let cacheMs: Double
    private let http: any UsageHTTPPerforming
    private let credentialsPath: String
    private let readKeychain: @Sendable () -> String?
    private let writeKeychain: @Sendable (String) -> Void
    private let nowMs: @Sendable () -> Double
    private let log: @Sendable (String) -> Void

    private var cached: UsageSnapshot?
    private var currentIntervalMs: Double

    public init(
        userAgentVersion: String = "unknown",
        cacheSec: Double = 15,
        http: any UsageHTTPPerforming = URLSessionUsageHTTP(),
        credentialsPath: String? = nil,
        readKeychain: (@Sendable () -> String?)? = nil,
        writeKeychain: (@Sendable (String) -> Void)? = nil,
        nowMs: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
        log: @escaping @Sendable (String) -> Void = { msg in fputs("dab usage: \(msg)\n", stderr) }
    ) {
        self.userAgent = "claude-code/\(userAgentVersion)"
        self.cacheMs = max(0, cacheSec) * 1000
        self.http = http
        self.credentialsPath = credentialsPath
            ?? NSHomeDirectory() + "/.claude/.credentials.json"
        self.readKeychain = readKeychain ?? defaultReadKeychain
        self.writeKeychain = writeKeychain ?? defaultWriteKeychain
        self.nowMs = nowMs
        self.log = log
        self.currentIntervalMs = max(0, cacheSec) * 1000
    }

    /// True when subscription OAuth credentials are readable.
    public func isAvailable() -> Bool {
        readCredentials() != nil
    }

    /// Serve cache within TTL; else fetch. NEVER throws.
    public func getUsage() async -> UsageResult {
        guard let creds = readCredentials() else {
            return .unavailable(UsageUnavailable(reason: .noCredentials))
        }
        let t = nowMs()
        if let cached, t - cached.fetchedAt < currentIntervalMs {
            return .snapshot(cached)
        }
        if let snap = await fetchUsage(creds: creds) {
            return .snapshot(snap)
        }
        if let cached { return .snapshot(cached) }
        return .unavailable(UsageUnavailable(reason: .noCredentials))
    }

    // MARK: credentials

    private func readCredentials() -> OAuthCredentials? {
        readCredentialsFromFile() ?? readCredentialsFromKeychain()
    }

    private func readCredentialsFromFile() -> OAuthCredentials? {
        guard let raw = try? String(contentsOfFile: credentialsPath, encoding: .utf8) else {
            return nil
        }
        return parseCredentials(raw, source: .file)
    }

    private func readCredentialsFromKeychain() -> OAuthCredentials? {
        guard let blob = readKeychain() else { return nil }
        return parseCredentials(blob, source: .keychain)
    }

    private func parseCredentials(_ raw: String, source: CredentialSource) -> OAuthCredentials? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty
        else {
            return nil
        }
        let expires: Double
        if let n = oauth["expiresAt"] as? Double {
            expires = n
        } else if let n = oauth["expiresAt"] as? Int {
            expires = Double(n)
        } else {
            expires = 0
        }
        return OAuthCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expires,
            source: source
        )
    }

    private func writeCredentials(_ creds: OAuthCredentials) {
        if creds.source == .keychain {
            let existing = readKeychain()
            let merged = mergeOauthInto(existingRaw: existing, creds: creds)
            if let data = try? JSONSerialization.data(withJSONObject: merged),
               let json = String(data: data, encoding: .utf8) {
                writeKeychain(json)
            }
            return
        }
        let existingRaw = try? String(contentsOfFile: credentialsPath, encoding: .utf8)
        let merged = mergeOauthInto(existingRaw: existingRaw, creds: creds)
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let json = String(data: data, encoding: .utf8)
        else { return }
        do {
            try json.write(toFile: credentialsPath, atomically: true, encoding: .utf8)
            // Best-effort 0600 (posix).
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: credentialsPath
            )
        } catch {
            log("failed to persist refreshed usage credentials")
        }
    }

    private func mergeOauthInto(existingRaw: String?, creds: OAuthCredentials) -> [String: Any] {
        var data: [String: Any] = [:]
        if let existingRaw,
           let rawData = existingRaw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
            data = obj
        }
        var prevOauth = (data["claudeAiOauth"] as? [String: Any]) ?? [:]
        prevOauth["accessToken"] = creds.accessToken
        prevOauth["refreshToken"] = creds.refreshToken
        prevOauth["expiresAt"] = creds.expiresAt
        data["claudeAiOauth"] = prevOauth
        return data
    }

    // MARK: token + fetch

    private func getValidToken(_ creds: OAuthCredentials) async -> String? {
        if creds.expiresAt < nowMs() + refreshSkewMs {
            return await refreshAccessToken(creds)?.accessToken
        }
        return creds.accessToken
    }

    private func refreshAccessToken(_ creds: OAuthCredentials) async -> OAuthCredentials? {
        var req = URLRequest(url: oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": clientID,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, http) = try await http.perform(req)
            guard (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String
            else {
                log("usage token refresh non-OK or bad shape")
                return nil
            }
            let refresh = (obj["refresh_token"] as? String) ?? creds.refreshToken
            let expiresIn: Double
            if let n = obj["expires_in"] as? Double { expiresIn = n }
            else if let n = obj["expires_in"] as? Int { expiresIn = Double(n) }
            else { expiresIn = 3600 }
            let refreshed = OAuthCredentials(
                accessToken: access,
                refreshToken: refresh,
                expiresAt: nowMs() + expiresIn * 1000,
                source: creds.source
            )
            writeCredentials(refreshed)
            return refreshed
        } catch {
            log("usage token refresh request failed")
            return nil
        }
    }

    private func fetchUsage(creds: OAuthCredentials) async -> UsageSnapshot? {
        guard let token = await getValidToken(creds) else { return nil }
        var req = URLRequest(url: usageAPIURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, http) = try await http.perform(req)
            if http.statusCode == 429 {
                currentIntervalMs = min(currentIntervalMs * backoffMultiplier, maxBackoffMs)
                log("usage endpoint rate-limited; backing off")
                return nil
            }
            guard (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                log("usage endpoint non-OK or bad JSON")
                return nil
            }
            currentIntervalMs = cacheMs
            let snap = toSnapshot(obj)
            cached = snap
            return snap
        } catch {
            log("usage fetch request failed")
            return nil
        }
    }

    private func toSnapshot(_ data: [String: Any]) -> UsageSnapshot {
        var snap = UsageSnapshot(fetchedAt: nowMs())
        if let l = toLimit(data["five_hour"]) { snap.fiveHour = l }
        if let l = toLimit(data["seven_day"]) { snap.sevenDay = l }
        if let l = toLimit(data["seven_day_opus"]) { snap.sevenDayOpus = l }
        if let l = toLimit(data["seven_day_sonnet"]) { snap.sevenDaySonnet = l }
        return snap
    }

    private func toLimit(_ raw: Any?) -> UsageLimit? {
        guard let dict = raw as? [String: Any] else { return nil }
        let util: Double?
        if let n = dict["utilization"] as? Double { util = n }
        else if let n = dict["utilization"] as? Int { util = Double(n) }
        else { util = nil }
        guard let util else { return nil }
        var limit = UsageLimit(utilization: util)
        if let r = dict["resets_at"] as? String { limit.resetsAt = r }
        // null resets_at → omit
        return limit
    }
}

// MARK: - Keychain defaults (darwin)

private func defaultReadKeychain() -> String? {
    #if os(macOS)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", keychainService, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        return s
    } catch {
        return nil
    }
    #else
    return nil
    #endif
}

private func defaultWriteKeychain(_ json: String) {
    #if os(macOS)
    let user = NSUserName()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = [
        "add-generic-password", "-U",
        "-s", keychainService,
        "-a", user,
        "-w", json,
    ]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    #endif
}
