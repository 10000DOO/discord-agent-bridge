import Testing
import Foundation
@testable import DiscordAgentBridge

// WO-3 (docs/cli-slash-command-parity.md §3-5-3): grok's `available_commands_update` → SlashCatalogEntry.
// Machine-independent: no `grok` child, no GROK_HOME, no network — the fixtures below are the payload
// captured verbatim off a live `grok agent stdio` (0.2.118) on 2026-08-05.

/// Three entries copied byte-for-byte from the measured push. `compact`/`always-approve` carry an
/// `input.hint`; `context` has `input: null` (no argument) — the two shapes the mapper must tell apart.
private let measuredCatalogUpdate: JSONValue = .object([
    "update": .object([
        "sessionUpdate": .string("available_commands_update"),
        "availableCommands": .array([
            .object([
                "name": .string("compact"),
                "description": .string("Compress conversation history to save context window"),
                "input": .object(["hint": .string("optional context about what to preserve")]),
            ]),
            .object([
                "name": .string("always-approve"),
                "description": .string("Toggle always-approve mode (skip all permission prompts)"),
                "input": .object(["hint": .string("on|off")]),
            ]),
            .object([
                "name": .string("context"),
                "description": .string("Show context window usage and session stats"),
                "input": .null,
            ]),
        ]),
        "_meta": .object([:]),
    ]),
])

private func catalogUpdate(_ commands: [JSONValue]) -> JSONValue {
    .object(["update": .object([
        "sessionUpdate": .string("available_commands_update"),
        "availableCommands": .array(commands),
    ])])
}

private func notificationLine(method: String, params: JSONValue) -> String {
    let obj: JSONValue = .object([
        "jsonrpc": .string("2.0"),
        "method": .string(method),
        "params": params,
    ])
    return String(data: try! JSONEncoder().encode(obj), encoding: .utf8)! + "\n"
}

/// Minimal fake `grok agent stdio` that pushes the command catalog right after `session/new` —
/// i.e. BEFORE any turn, which is the whole point of WO-3.
private actor CatalogPushingGrokServer {
    private let transport: InMemorySidecarTransport
    private let catalog: JSONValue

    init(transport: InMemorySidecarTransport, catalog: JSONValue = measuredCatalogUpdate) {
        self.transport = transport
        self.catalog = catalog
    }

    func run() async {
        do { for try await line in transport.lines { await handle(line) } } catch {}
    }

    private func handle(_ line: String) async {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let msg) = v, let method = msg["method"]?.stringValue, let id = msg["id"]
        else { return }

        switch method {
        case "initialize":
            await write(["id": id, "result": .object(["protocolVersion": .number(1)])])
        case "session/new":
            await write(["id": id, "result": .object(["sessionId": .string("s1")])])
            // The catalog arrives unprompted, outside any turn (measured ordering).
            try? await transport.writeLine(notificationLine(method: "session/update", params: catalog))
        case "session/prompt":
            await write(["id": id, "result": .object(["stopReason": .string("end_turn")])])
        default:
            await write(["id": id, "error": .object([
                "code": .number(-32601), "message": .string("method not found: \(method)"),
            ])])
        }
    }

    private func write(_ obj: [String: JSONValue]) async {
        guard let d = try? JSONEncoder().encode(JSONValue.object(obj)),
              let s = String(data: d, encoding: .utf8) else { return }
        try? await transport.writeLine(s + "\n")
    }
}

private func makeCatalogBridge() -> GrokSessionBridge {
    GrokSessionBridge(makeClient: { _, onPermission, _ in
        let pair = InMemorySidecarTransport.makePair()
        let server = CatalogPushingGrokServer(transport: pair.sidecar)
        Task { await server.run() }
        return GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000, onPermission: onPermission)
    },
    store: freshTempStore(),
    // Same isolation reasoning as GrokSessionBridgeTests: never read this machine's real
    // ~/.discord-agent-bridge/config.json or ~/.grok/models_cache.json.
    configStore: ConfigStore(baseDir: FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-cfg-missing-\(UUID().uuidString)", isDirectory: true)),
    attachGateway: NoopAttachGateway(),
    configSource: GrokConfigSource(grokHome: FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-home-missing-\(UUID().uuidString)", isDirectory: true).path))
}

@Suite("GrokSlashCatalog")
struct GrokSlashCatalogTests {

    // MARK: - Pure mapper

    @Test func mapsMeasuredPayload() {
        let entries = grokSlashCatalog(method: "session/update", params: measuredCatalogUpdate)
        #expect(entries == [
            SlashCatalogEntry(
                name: "compact",
                description: "Compress conversation history to save context window",
                argumentHint: "optional context about what to preserve"
            ),
            SlashCatalogEntry(
                name: "always-approve",
                description: "Toggle always-approve mode (skip all permission prompts)",
                argumentHint: "on|off"
            ),
            // input: null → no argument hint at all (not an empty string).
            SlashCatalogEntry(
                name: "context",
                description: "Show context window usage and session stats",
                argumentHint: nil
            ),
        ])
    }

    @Test func acceptsXaiPrefixedUpdates() {
        // The client treats `x.ai/session/update` as a live stream too (grokUpdateStep parity).
        #expect(grokSlashCatalog(method: "x.ai/session/update", params: measuredCatalogUpdate)?.count == 3)
    }

    /// nil ("not a catalog push") must stay distinguishable from [] ("a push listing no commands"),
    /// because grok re-pushes the WHOLE list on every change — [] means the list really is empty.
    @Test func nonCatalogNotificationsReturnNil() {
        let textUpdate: JSONValue = .object(["update": .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("hi")]),
        ])])
        #expect(grokSlashCatalog(method: "session/update", params: textUpdate) == nil)
        #expect(grokSlashCatalog(method: "session/prompt", params: measuredCatalogUpdate) == nil)
        #expect(grokSlashCatalog(method: "session/update", params: nil) == nil)
        // Right kind, but the array key is absent → nothing to map, so it is not a catalog push.
        #expect(grokSlashCatalog(method: "session/update", params: .object(["update": .object([
            "sessionUpdate": .string("available_commands_update"),
        ])])) == nil)
    }

    @Test func emptyListMapsToEmptyNotNil() {
        #expect(grokSlashCatalog(method: "session/update", params: catalogUpdate([])) == [])
    }

    @Test func skipsUnusableEntriesAndBlankHints() {
        let entries = grokSlashCatalog(method: "session/update", params: catalogUpdate([
            .object(["description": .string("no name at all")]),
            .object(["name": .string(""), "description": .string("blank name")]),
            // A blank hint is no hint — it would render as a dangling "· " in the picker.
            .object(["name": .string("loop"), "input": .object(["hint": .string("")])]),
            .object(["name": .string("goal")]),
        ]))
        #expect(entries == [
            SlashCatalogEntry(name: "loop", description: "", argumentHint: nil),
            SlashCatalogEntry(name: "goal", description: "", argumentHint: nil),
        ])
    }

    /// Regression guard for the original discard comment ("grok echoes its own slash-command list
    /// back as updates — not agent output; do not re-render"): the catalog must stay invisible to
    /// every path that produces Discord output.
    @Test func catalogPushNeverReachesARenderPath() {
        #expect(grokUpdateStep(method: "session/update", params: measuredCatalogUpdate) == .ignore)
        #expect(grokProgressEvents(method: "session/update", params: measuredCatalogUpdate).isEmpty)
        var seq = 0
        #expect(grokToolEvents(method: "session/update", params: measuredCatalogUpdate, mintId: &seq).isEmpty)
        #expect(seq == 0)
    }

    // MARK: - Client capture (outside any turn)

    @Test func clientCapturesCatalogWithNoTurnAndNoSubscriber() async throws {
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        #expect(client.availableCommands.isEmpty)

        // No onNotification subscriber, no prompt in flight — exactly the session/new-adjacent
        // conditions under which a turn-scoped subscriber would have missed this.
        try await pair.sidecar.writeLine(
            notificationLine(method: "session/update", params: measuredCatalogUpdate)
        )
        #expect(await waitUntil { client.availableCommands.count == 3 })
        #expect(client.availableCommands.first?.name == "compact")

        // A later push replaces the list wholesale rather than appending.
        try await pair.sidecar.writeLine(notificationLine(
            method: "session/update",
            params: catalogUpdate([.object(["name": .string("only-this")])])
        ))
        #expect(await waitUntil { client.availableCommands == [
            SlashCatalogEntry(name: "only-this", description: "", argumentHint: nil),
        ] })
        await client.close()
    }

    @Test func clientStillForwardsCatalogPushToSubscribers() async throws {
        // Capture must not swallow the notification: the fan-out is unchanged.
        let pair = InMemorySidecarTransport.makePair()
        let client = GrokAcpClient(transport: pair.host, requestTimeoutMs: 5_000)
        let seen = LockedBox<[String]>([])
        client.onNotification { method, _ in seen.withLock { $0.append(method) } }
        try await pair.sidecar.writeLine(
            notificationLine(method: "session/update", params: measuredCatalogUpdate)
        )
        #expect(await waitUntil { seen.withLock { $0 } == ["session/update"] })
        await client.close()
    }

    // MARK: - Bridge entry point

    /// Sessions spawn lazily on the first turn, so a bound-but-silent channel has nobody to ask.
    /// That is EMPTY, not an error (DabSessionBridge.setModel policy).
    @Test func noLiveSessionYieldsEmptyList() async {
        let bridge = makeCatalogBridge()
        #expect(await bridge.slashCatalog(channelId: "never-talked").isEmpty)
    }

    @Test func liveSessionExposesCatalog() async throws {
        let bridge = makeCatalogBridge()
        _ = try await bridge.runTurn(channelId: "c", text: "hi")
        let entries = await bridge.slashCatalog(channelId: "c")
        #expect(entries.map(\.name) == ["compact", "always-approve", "context"])
        #expect(entries.first?.argumentHint == "optional context about what to preserve")
        // Still scoped per channel — a different channel has no session of its own.
        #expect(await bridge.slashCatalog(channelId: "other").isEmpty)
    }

    /// The catalog is stored, not rendered: a turn whose only notification is the command list must
    /// still come back with no agent text (the reply path never sees it).
    @Test func catalogPushDoesNotLeakIntoTurnText() async throws {
        let bridge = makeCatalogBridge()
        let result = try await bridge.runTurn(channelId: "c", text: "hi")
        #expect(result.text == "(no text)")
    }
}
