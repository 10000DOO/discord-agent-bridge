import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("fetchLatestVersion")
struct FetchLatestVersionTests {
    @Test func returnsVersionOn200() async {
        let get: UpdateHTTPGet = { _, _, _ in
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v1.2.3"])
            return (data, 200)
        }
        let v = await fetchLatestVersion(opts: FetchLatestOptions(httpGet: get))
        #expect(v == "1.2.3")
    }

    @Test func returnsTagAsIsWhenNoVPrefix() async {
        let get: UpdateHTTPGet = { _, _, _ in
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": "1.2.3"])
            return (data, 200)
        }
        let v = await fetchLatestVersion(opts: FetchLatestOptions(httpGet: get))
        #expect(v == "1.2.3")
    }

    @Test func sendsAcceptAndUserAgent() async {
        let seen = LockedBox<(URL, [String: String])?>(nil)
        let get: UpdateHTTPGet = { url, headers, _ in
            seen.withLock { $0 = (url, headers) }
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v9.9.9"])
            return (data, 200)
        }
        _ = await fetchLatestVersion(opts: FetchLatestOptions(userAgent: "dab/1.0.0", httpGet: get))
        let snap = seen.withLock { $0 }
        #expect(snap?.0 == updateRegistryURL)
        #expect(snap?.1["User-Agent"] == "dab/1.0.0")
        #expect(snap?.1["Accept"] == "application/vnd.github+json")
    }

    @Test func nullOnNonOK() async {
        let get: UpdateHTTPGet = { _, _, _ in (Data("{}".utf8), 500) }
        let v = await fetchLatestVersion(opts: FetchLatestOptions(httpGet: get))
        #expect(v == nil)
    }

    @Test func nullOn404() async {
        let get: UpdateHTTPGet = { _, _, _ in
            let data = try JSONSerialization.data(withJSONObject: ["message": "Not Found"])
            return (data, 404)
        }
        let v = await fetchLatestVersion(opts: FetchLatestOptions(httpGet: get))
        #expect(v == nil)
    }

    @Test func nullWhenNoTagNameField() async {
        let get: UpdateHTTPGet = { _, _, _ in
            let data = try JSONSerialization.data(withJSONObject: ["name": "x"])
            return (data, 200)
        }
        let v = await fetchLatestVersion(opts: FetchLatestOptions(httpGet: get))
        #expect(v == nil)
    }

    @Test func nullOnThrow() async {
        struct Boom: Error {}
        let get: UpdateHTTPGet = { _, _, _ in throw Boom() }
        let v = await fetchLatestVersion(opts: FetchLatestOptions(httpGet: get))
        #expect(v == nil)
    }
}
