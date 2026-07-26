import Foundation

// npm registry probe for the latest published version (TS `src/update/registry.ts`).
// Injected fetch; NEVER throws — any failure resolves to nil so the caller silently skips.

public let updateRegistryURL = URL(string: "https://registry.npmjs.org/discord-agent-bridge/latest")!
public let updateRegistryDefaultTimeoutMs = 5000

/// Injectable HTTP GET: returns body data + HTTP status (or throws).
public typealias UpdateHTTPGet = @Sendable (URL, [String: String], TimeInterval) async throws -> (Data, Int)

/// Default URLSession-backed GET with timeout.
public let defaultUpdateHTTPGet: UpdateHTTPGet = { url, headers, timeout in
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.httpMethod = "GET"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
    return (data, status)
}

public struct FetchLatestOptions: Sendable {
    public var timeoutMs: Int
    public var userAgent: String?
    public var registryURL: URL
    public var httpGet: UpdateHTTPGet

    public init(
        timeoutMs: Int = updateRegistryDefaultTimeoutMs,
        userAgent: String? = nil,
        registryURL: URL = updateRegistryURL,
        httpGet: @escaping UpdateHTTPGet = defaultUpdateHTTPGet
    ) {
        self.timeoutMs = timeoutMs
        self.userAgent = userAgent
        self.registryURL = registryURL
        self.httpGet = httpGet
    }
}

/// Resolve the latest published version string, or nil on ANY failure.
public func fetchLatestVersion(opts: FetchLatestOptions = FetchLatestOptions()) async -> String? {
    var headers: [String: String] = ["Accept": "application/json"]
    if let ua = opts.userAgent, !ua.isEmpty {
        headers["User-Agent"] = ua
    }
    let timeout = max(0.001, Double(opts.timeoutMs) / 1000.0)
    let data: Data
    let status: Int
    do {
        (data, status) = try await opts.httpGet(opts.registryURL, headers, timeout)
    } catch {
        return nil
    }
    guard status >= 200, status < 300 else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = obj["version"] as? String,
          !version.isEmpty
    else { return nil }
    return version
}
