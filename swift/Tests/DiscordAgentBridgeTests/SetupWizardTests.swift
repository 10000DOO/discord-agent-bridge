import Testing
import Foundation
@testable import DiscordAgentBridge

// The wizard's pure decisions: which paste is a bot token, and how ~/.dab/env survives a rewrite.
// The prompt loop itself is I/O and is exercised by hand; these are the parts that silently
// corrupt a working install if they regress.

@Suite struct TokenShapeTests {
    @Test func realBotTokenIsAccepted() {
        #expect(classifyTokenInput("MTUyMjEyODEyNTA4Nzk3NzU1NQ.GhX9kq.aBcDeF") == .botToken)
    }

    @Test func clientSecretIsRejectedByShapeAlone() {
        // 32 chars, no dots — the OAuth2 tab's Client Secret, the most common wrong paste.
        #expect(classifyTokenInput("Xk3n8QpL2vR7sT1yU4wZ0aB6cD9eF5gH") == .clientSecret)
    }

    @Test func truncatedPasteIsMalformed() {
        #expect(classifyTokenInput("MTUyMjEyODEyNTA4Nzk3NzU1NQ.GhX9kq") == .malformed)
    }

    @Test func emptyInput() {
        #expect(classifyTokenInput("   ") == .empty)
    }

    @Test func headerAndQuoteNoiseIsStripped() {
        #expect(normalizeTokenInput("  \"Bot MTUy.GhX9kq.aBcDeF\"  ") == "MTUy.GhX9kq.aBcDeF")
        #expect(classifyTokenInput("Bot MTUy.GhX9kq.aBcDeF") == .botToken)
    }
}

@Suite struct EnvFileMergeTests {
    @Test func replacesInPlaceAndKeepsEverythingElse() {
        let existing = """
        # Discord Agent Bridge — deploy env.
        DISCORD_BOT_TOKEN=old.token.value
        DAB_CWD=/work

        DAB_REDMINE_KEY_SECRET=abc123
        """
        let merged = upsertEnvContent(existing, ["DISCORD_BOT_TOKEN": "new.token.value", "DAB_DEV_GUILD_ID": "42"])
        let parsed = parseEnvFile(merged)
        #expect(parsed["DISCORD_BOT_TOKEN"] == "new.token.value")
        #expect(parsed["DAB_DEV_GUILD_ID"] == "42")
        // A rewrite-from-scratch would drop these; the wizard must never eat the Redmine secret.
        #expect(parsed["DAB_CWD"] == "/work")
        #expect(parsed["DAB_REDMINE_KEY_SECRET"] == "abc123")
        #expect(merged.contains("# Discord Agent Bridge"))
        #expect(merged.hasSuffix("\n"))
    }

    @Test func commentedKeyIsNotTreatedAsTheRealOne() {
        let merged = upsertEnvContent("#DISCORD_BOT_TOKEN=commented\n", ["DISCORD_BOT_TOKEN": "real.tok.en"])
        #expect(merged.contains("#DISCORD_BOT_TOKEN=commented"))
        #expect(parseEnvFile(merged)["DISCORD_BOT_TOKEN"] == "real.tok.en")
    }

    @Test func emptyFileGetsBothKeys() {
        let parsed = parseEnvFile(upsertEnvContent("", ["DISCORD_BOT_TOKEN": "a.b.c", "DAB_DEV_GUILD_ID": "7"]))
        #expect(parsed == ["DISCORD_BOT_TOKEN": "a.b.c", "DAB_DEV_GUILD_ID": "7"])
    }

    @Test func quotedValuesAreUnwrappedLikeShellSourcingWould() {
        #expect(parseEnvFile("PATH=\"$NVM_BIN:$PATH\"\n")["PATH"] == "$NVM_BIN:$PATH")
    }
}

/// Drives the whole prompt loop with scripted answers and a fake Discord, covering the path a
/// first-time user actually takes: paste the wrong secret, paste the right token, invite the bot,
/// pick the server.
@Suite struct SetupWizardFlowTests {
    @Test func recoversFromAWrongPasteAndRecordsThePickedGuild() async throws {
        let envURL = FileManager.default.temporaryDirectory.appendingPathComponent("dab-env-\(UUID().uuidString)")
        try "# keep me\nDAB_CWD=/work\n".write(to: envURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: envURL) }

        let secrets = LockedBox<[String]>(["Xk3n8QpL2vR7sT1yU4wZ0aB6cD9eF5gH", "MTUy.GhX9kq.aBcDeF"])
        let lines = LockedBox<[String]>([""])   // one Enter: "I invited the bot"
        let guildCalls = LockedBox<Int>(0)
        let transcript = LockedBox<[String]>([])

        let deps = SetupWizardDeps(
            output: { line in transcript.withLock { $0.append(line) } },
            readLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
            readSecret: { secrets.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
            httpGet: { url, headers in
                #expect(headers["Authorization"] == "Bot MTUy.GhX9kq.aBcDeF")
                if url.path.hasSuffix("/users/@me") {
                    return (Data(#"{"id":"999","username":"my-agent-bot"}"#.utf8), 200)
                }
                // First look: not invited yet. After the user presses Enter, the guild is there.
                let first = guildCalls.withLock { count -> Bool in
                    count += 1
                    return count == 1
                }
                let body = first ? "[]" : #"[{"id":"777","name":"my-team"}]"#
                return (Data(body.utf8), 200)
            },
            envFileURL: envURL,
            serviceInstalled: { false },
            restartService: { false }
        )

        let result = await runSetupWizard(deps: deps, offerService: false)
        #expect(result?.token == "MTUy.GhX9kq.aBcDeF")
        #expect(result?.guildId == "777")

        let saved = parseEnvFile(try String(contentsOf: envURL, encoding: .utf8))
        #expect(saved["DISCORD_BOT_TOKEN"] == "MTUy.GhX9kq.aBcDeF")
        #expect(saved["DAB_DEV_GUILD_ID"] == "777")
        #expect(saved["DAB_CWD"] == "/work")

        let shown = transcript.withLock { $0.joined(separator: "\n") }
        #expect(shown.contains("Client Secret"))          // the wrong paste was named, not just refused
        #expect(shown.contains("my-agent-bot"))           // the verified bot name was shown back
        #expect(shown.contains("oauth2/authorize"))       // the invite link was generated for them
    }

    /// A Homebrew install has no checkout, so naming install.sh sends the user after a file that
    /// does not exist on their machine — the whole point of threading the install method here.
    @Test func closingGuidanceNamesTheServiceTheInstallActuallyUses() async throws {
        func transcriptOfWizard(isHomebrew: Bool) async throws -> String {
            let envURL = FileManager.default.temporaryDirectory.appendingPathComponent("dab-env-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: envURL) }
            let secrets = LockedBox<[String]>(["MTUy.GhX9kq.aBcDeF"])
            let lines = LockedBox<[String]>([""])
            let transcript = LockedBox<[String]>([])
            let deps = SetupWizardDeps(
                output: { line in transcript.withLock { $0.append(line) } },
                readLine: { lines.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                readSecret: { secrets.withLock { $0.isEmpty ? nil : $0.removeFirst() } },
                httpGet: { url, _ in
                    if url.path.hasSuffix("/users/@me") {
                        return (Data(#"{"id":"999","username":"my-agent-bot"}"#.utf8), 200)
                    }
                    return (Data(#"[{"id":"777","name":"my-team"}]"#.utf8), 200)
                },
                envFileURL: envURL,
                serviceInstalled: { false },
                restartService: { false },
                isHomebrew: isHomebrew
            )
            _ = await runSetupWizard(deps: deps, offerService: true)
            return transcript.withLock { $0.joined(separator: "\n") }
        }

        let brew = try await transcriptOfWizard(isHomebrew: true)
        #expect(brew.contains("brew services start dab"))
        #expect(!brew.contains("install.sh"))

        let source = try await transcriptOfWizard(isHomebrew: false)
        #expect(source.contains("bash swift/scripts/install.sh"))
        #expect(!source.contains("brew services"))
    }

    @Test func eofDuringTokenEntryAbortsWithoutWriting() async {
        let envURL = FileManager.default.temporaryDirectory.appendingPathComponent("dab-env-\(UUID().uuidString)")
        let deps = SetupWizardDeps(
            output: { _ in },
            readLine: { nil },
            readSecret: { nil },
            httpGet: { _, _ in (Data(), 500) },
            envFileURL: envURL,
            serviceInstalled: { false },
            restartService: { false }
        )
        #expect(await runSetupWizard(deps: deps, offerService: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: envURL.path))
    }
}

@Suite struct DabEnvLoadTests {
    @Test func processEnvWinsOverFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dab-env-\(UUID().uuidString)")
        try "DISCORD_BOT_TOKEN=from.the.file\nDAB_DEV_GUILD_ID=99\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var applied: [String: String] = [:]
        loadDabEnvFile(
            url: url,
            environment: ["DISCORD_BOT_TOKEN": "exported.by.shell"],
            setEnv: { applied[$0] = $1 }
        )
        #expect(applied["DISCORD_BOT_TOKEN"] == nil)
        #expect(applied["DAB_DEV_GUILD_ID"] == "99")
    }

    @Test func missingFileIsNotAnError() {
        var applied: [String: String] = [:]
        loadDabEnvFile(
            url: URL(fileURLWithPath: "/nonexistent/dab/env"),
            environment: [:],
            setEnv: { applied[$0] = $1 }
        )
        #expect(applied.isEmpty)
    }
}
