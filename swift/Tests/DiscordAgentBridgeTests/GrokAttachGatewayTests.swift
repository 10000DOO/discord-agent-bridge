import Testing
import Foundation
@testable import DiscordAgentBridge

/// Throwaway workspace dir for gateway /attach tests (mirrors FileAttachTests' fixture).
private func makeGatewayWorkspace() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-attach-gw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return URL(fileURLWithPath: realpathOrResolve(base.path))
}

@Suite("GrokAttachGateway")
struct GrokAttachGatewayTests {
    @Test func requestBodyLimitIsOneMiB() {
        #expect(GROK_ATTACH_GATEWAY_MAX_BODY_BYTES == 1_048_576)
    }

    @Test func rejectsRequestBodiesOverOneMiBBeforeRouting() async throws {
        let gateway = GrokAttachGateway()
        try await gateway.whenReady()
        var request = URLRequest(url: URL(string: await gateway.baseURL + "/attach")!)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 0x20, count: GROK_ATTACH_GATEWAY_MAX_BODY_BYTES + 1)
        do {
            _ = try await URLSession.shared.data(for: request)
            Issue.record("oversized gateway request must be rejected")
        } catch {
            // Gateway closes the connection before JSON routing; URLSession surfaces that close.
        }
    }

    @Test func healthCheckOk() async throws {
        let gateway = GrokAttachGateway()
        try await gateway.whenReady()
        let base = await gateway.baseURL
        let (status, body) = try await getAttachGatewayJSON(base + "/health")
        #expect(status == 200)
        #expect(body["ok"]?.boolValue == true)
    }

    @Test func attachRoundTripsToFileAttachHostWithChannelId() async throws {
        let host = FileAttachHost()
        let calls = LockedBox<[(channelId: String, path: String, name: String?)]>([])
        await host.setAttachHandler { channelId, path, name in
            calls.withLock { $0.append((channelId, path, name)) }
            return "Sent \(name ?? path) to the channel."
        }
        let gateway = GrokAttachGateway(fileAttachHost: host)
        try await gateway.whenReady()

        let workspace = try makeGatewayWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("hi".utf8).write(to: workspace.appendingPathComponent("a.txt"))
        await gateway.register(token: "tok-attach-1", channelId: "chan-1", workspaceRoot: workspace.path)

        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/attach",
            body: ["token": .string("tok-attach-1"), "path": .string("a.txt"), "filename": .string("custom.txt")]
        )
        #expect(status == 200)
        #expect(body["ok"]?.boolValue == true)
        #expect(body["text"]?.stringValue == "Sent custom.txt to the channel.")
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.channelId == "chan-1")
        #expect(recorded.first?.name == "custom.txt")
    }

    @Test func attachRefusesEscapeWithoutCallingHost() async throws {
        let host = FileAttachHost()
        let called = LockedBox(false)
        await host.setAttachHandler { _, _, _ in
            called.withLock { $0 = true }
            return "should not be reached"
        }
        let gateway = GrokAttachGateway(fileAttachHost: host)
        try await gateway.whenReady()

        let workspace = try makeGatewayWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        await gateway.register(token: "tok-attach-2", channelId: "chan-2", workspaceRoot: workspace.path)

        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/attach",
            body: ["token": .string("tok-attach-2"), "path": .string("../../etc/passwd")]
        )
        #expect(status == 400)
        #expect(body["ok"]?.boolValue == false)
        #expect(body["text"]?.stringValue?.contains("outside the session workspace") == true)
        #expect(called.withLock { $0 } == false)
    }

    @Test func unknownTokenIsUnauthorized() async throws {
        let gateway = GrokAttachGateway()
        try await gateway.whenReady()
        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/attach",
            body: ["token": .string("no-such-token"), "path": .string("a.txt")]
        )
        #expect(status == 401)
        #expect(body["ok"]?.boolValue == false)
    }

    @Test func unregisterMakesTokenUnauthorized() async throws {
        let gateway = GrokAttachGateway()
        try await gateway.whenReady()
        await gateway.register(token: "tok-unreg", channelId: "chan-3", workspaceRoot: NSTemporaryDirectory())
        await gateway.unregister(token: "tok-unreg")

        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/attach",
            body: ["token": .string("tok-unreg"), "path": .string("a.txt")]
        )
        #expect(status == 401)
        #expect(body["ok"]?.boolValue == false)
    }

    @Test func shareRoundTripsSuccessTextThroughDocumentShareHost() async throws {
        let docHost = DocumentShareHost()
        await docHost.setShareHandler { channelId, path in
            #expect(channelId == "chan-4")
            #expect(path == "notes.md")
            return ShareResult(ok: true, threadName: "📄 notes.md", path: "notes.md")
        }
        let gateway = GrokAttachGateway(documentShareHost: docHost)
        try await gateway.whenReady()
        await gateway.register(token: "tok-share-1", channelId: "chan-4", workspaceRoot: NSTemporaryDirectory())

        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/share",
            body: ["token": .string("tok-share-1"), "path": .string("notes.md")]
        )
        #expect(status == 200)
        #expect(body["ok"]?.boolValue == true)
        #expect(body["text"]?.stringValue == "Shared \"notes.md\" to thread 📄 notes.md")
    }

    @Test func shareMapsRejectionCodeToNeutralEnglishText() async throws {
        let docHost = DocumentShareHost()
        await docHost.setShareHandler { _, _ in .reject(.notMarkdown) }
        let gateway = GrokAttachGateway(documentShareHost: docHost)
        try await gateway.whenReady()
        await gateway.register(token: "tok-share-2", channelId: "chan-5", workspaceRoot: NSTemporaryDirectory())

        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/share",
            body: ["token": .string("tok-share-2"), "path": .string("readme.txt")]
        )
        #expect(status == 400)
        #expect(body["ok"]?.boolValue == false)
        #expect(body["text"]?.stringValue?.contains("not a markdown file") == true)
    }

    @Test func shareWithoutSinkIsRefused() async throws {
        // No share_document sink wired for this session (TS: absent shareDocument → gateway
        // refuses /share). Here that maps to DocumentShareHost's own unwired backstop
        // (`.noSession`, uncoded failure) rather than a gateway-level distinct rejection —
        // the observable outcome (neutral failure text, isError) matches TS intent.
        let gateway = GrokAttachGateway(documentShareHost: DocumentShareHost())
        try await gateway.whenReady()
        await gateway.register(token: "tok-share-3", channelId: "chan-6", workspaceRoot: NSTemporaryDirectory())

        let base = await gateway.baseURL
        let (status, body) = try await postAttachGatewayJSON(
            base + "/share",
            body: ["token": .string("tok-share-3"), "path": .string("notes.md")]
        )
        #expect(status == 400)
        #expect(body["ok"]?.boolValue == false)
        #expect(body["text"]?.stringValue?.contains("no active session for this channel") == true)
    }
}
