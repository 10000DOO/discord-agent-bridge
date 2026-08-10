import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Interactive first-run setup. `dab --setup` used to print "open this file and edit it"
// guidance (C12) and do nothing; every step it described is now performed here — verify the
// token against Discord, list the guilds the bot is already in, persist to ~/.dab/env.
// Pure helpers (shape classification, env merge) are separated from the prompts so they are
// testable without a TTY; I/O is injected the same way ServiceCommandDeps does it.

public enum TokenShape: Equatable, Sendable {
    case botToken
    /// A single blob with no dots — what the OAuth2 tab's Client Secret looks like.
    case clientSecret
    case empty
    case malformed
}

/// A bot token is `<base64 app id>.<base64 timestamp>.<hmac>`. A client secret is one 32-char
/// blob. Classifying before the network call turns the single most common mistake into a
/// specific message instead of an opaque 401.
public func classifyTokenInput(_ raw: String) -> TokenShape {
    let stripped = normalizeTokenInput(raw)
    if stripped.isEmpty { return .empty }
    let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) { return .botToken }
    if !stripped.contains(".") { return .clientSecret }
    return .malformed
}

/// Copying from the portal (or from an Authorization header) commonly drags along a `Bot `
/// prefix, surrounding quotes, or a trailing newline.
public func normalizeTokenInput(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
        s = String(s.dropFirst().dropLast())
    }
    if s.lowercased().hasPrefix("bot ") {
        s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
    }
    return s
}

/// Rewrite `KEY=value` lines in place, appending the ones that are missing. Comments, blank
/// lines, ordering and unrelated keys survive untouched — the file also holds PATH hints and
/// the Redmine cipher secret, so a rewrite-from-scratch would silently drop them.
public func upsertEnvContent(_ existing: String, _ values: [String: String]) -> String {
    var remaining = values
    var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        guard let newValue = remaining[key] else { continue }
        lines[index] = "\(key)=\(newValue)"
        remaining.removeValue(forKey: key)
    }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
    }
    for key in remaining.keys.sorted() {
        lines.append("\(key)=\(remaining[key]!)")
    }
    return lines.joined(separator: "\n") + "\n"
}

public struct DiscordBotIdentity: Equatable, Sendable {
    public let id: String
    public let username: String

    public init(id: String, username: String) {
        self.id = id
        self.username = username
    }
}

public struct DiscordGuildSummary: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum SetupProbeError: Error, Equatable, Sendable {
    case unauthorized
    case http(Int)
    case transport(String)
}

/// Injectable HTTP GET returning body + status, mirroring `UpdateHTTPGet`.
public typealias SetupHTTPGet = @Sendable (URL, [String: String]) async throws -> (Data, Int)

public let defaultSetupHTTPGet: SetupHTTPGet = { url, headers in
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "GET"
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let (data, resp) = try await URLSession.shared.data(for: req)
    return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
}

private let discordAPIBase = "https://discord.com/api/v10"

private func discordGet(_ path: String, token: String, httpGet: SetupHTTPGet) async throws -> Data {
    guard let url = URL(string: discordAPIBase + path) else {
        throw SetupProbeError.transport("bad url: \(path)")
    }
    let (data, status): (Data, Int)
    do {
        (data, status) = try await httpGet(url, ["Authorization": "Bot \(token)"])
    } catch {
        throw SetupProbeError.transport(String(describing: error))
    }
    if status == 401 { throw SetupProbeError.unauthorized }
    guard status == 200 else { throw SetupProbeError.http(status) }
    return data
}

/// `GET /users/@me` with a bot token: the returned user id IS the application id, which is what
/// the invite URL needs — so one call covers both "is this token real" and "what is my client id".
public func probeBotIdentity(token: String, httpGet: SetupHTTPGet = defaultSetupHTTPGet) async throws -> DiscordBotIdentity {
    struct Me: Decodable { let id: String; let username: String }
    let me = try JSONDecoder().decode(Me.self, from: try await discordGet("/users/@me", token: token, httpGet: httpGet))
    return DiscordBotIdentity(id: me.id, username: me.username)
}

/// Guilds the bot is already a member of — this is what removes the "turn on Developer Mode and
/// right-click the server to copy its id" step from setup entirely.
public func probeBotGuilds(token: String, httpGet: SetupHTTPGet = defaultSetupHTTPGet) async throws -> [DiscordGuildSummary] {
    struct Guild: Decodable { let id: String; let name: String }
    let guilds = try JSONDecoder().decode([Guild].self, from: try await discordGet("/users/@me/guilds", token: token, httpGet: httpGet))
    return guilds.map { DiscordGuildSummary(id: $0.id, name: $0.name) }
}

public struct SetupWizardDeps: Sendable {
    public var output: @Sendable (String) -> Void
    public var readLine: @Sendable () -> String?
    /// Reads without echoing — the token is a password and would otherwise sit in scrollback.
    public var readSecret: @Sendable () -> String?
    public var httpGet: SetupHTTPGet
    public var envFileURL: URL
    public var serviceInstalled: @Sendable () -> Bool
    public var restartService: @Sendable () async -> Bool
    /// Decides which service the closing guidance names — `brew services start dab` vs the
    /// install.sh a Homebrew user has no checkout for.
    public var isHomebrew: Bool

    public init(
        output: @escaping @Sendable (String) -> Void = { print($0) },
        readLine: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) },
        readSecret: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) },
        httpGet: @escaping SetupHTTPGet = defaultSetupHTTPGet,
        envFileURL: URL = RedmineKeySecret.defaultEnvFileURL(),
        serviceInstalled: @escaping @Sendable () -> Bool = {
            let plist = isHomebrewInstall()
                ? homebrewServicePlistPath(home: NSHomeDirectory())
                : launchdPlistPath(home: NSHomeDirectory())
            return FileManager.default.fileExists(atPath: plist)
        },
        restartService: @escaping @Sendable () async -> Bool = { await runServiceCommand(["restart"]) },
        isHomebrew: Bool = isHomebrewInstall()
    ) {
        self.output = output
        self.readLine = readLine
        self.readSecret = readSecret
        self.httpGet = httpGet
        self.envFileURL = envFileURL
        self.serviceInstalled = serviceInstalled
        self.restartService = restartService
        self.isHomebrew = isHomebrew
    }
}

public struct SetupWizardResult: Equatable, Sendable {
    public let token: String
    public let guildId: String?
    /// True when the wizard handed the process off to the service — the caller must not also boot.
    public let serviceStarted: Bool
}

/// Runs the interactive setup. Returns nil when the user aborts or input runs out (EOF).
/// - Parameter offerService: `--setup` offers to (re)start the background service afterwards;
///   the bare-`dab` fallback path does not, because it boots in the foreground itself.
public func runSetupWizard(deps: SetupWizardDeps = SetupWizardDeps(), offerService: Bool) async -> SetupWizardResult? {
    let out = deps.output
    out("")
    out("dab 설정을 시작합니다. 물어보는 대로 답하면 나머지는 알아서 처리합니다.")
    out("")

    guard let identity = await resolveToken(deps: deps) else { return nil }
    let token = identity.token

    out("")
    let guild: DiscordGuildSummary?
    switch await resolveGuild(token: token, applicationId: identity.bot.id, deps: deps) {
    case .aborted: return nil
    case .skipped: guild = nil
    case .picked(let g): guild = g
    }

    var values = ["DISCORD_BOT_TOKEN": token]
    if let guild { values["DAB_DEV_GUILD_ID"] = guild.id }
    do {
        try writeEnvFile(url: deps.envFileURL, values: values)
    } catch {
        out("")
        out("✗ \(deps.envFileURL.path) 저장에 실패했습니다: \(error)")
        return nil
    }
    out("")
    out("저장했습니다 → \(deps.envFileURL.path)")

    var serviceStarted = false
    if offerService {
        if deps.serviceInstalled() {
            if askYesNo("백그라운드 서비스를 재시작해서 지금 적용할까요?", deps: deps, defaultYes: true) {
                serviceStarted = await deps.restartService()
                if !serviceStarted {
                    out("서비스 재시작에 실패했습니다. `dab` 을 직접 실행해도 됩니다.")
                }
            }
        } else {
            out("")
            out("백그라운드 서비스로 항상 켜두려면: \(deps.isHomebrew ? "brew services start dab" : "bash swift/scripts/install.sh")")
            out("지금 바로 써보려면: dab")
        }
    }

    out("")
    if guild != nil {
        out("끝났습니다. 디스코드의 \(guild!.name) 서버에서 /setup 을 쳐보세요.")
    } else {
        out("끝났습니다. 봇을 서버에 초대한 뒤 /setup 을 쳐보세요 (명령이 보이기까지 최대 1시간).")
    }
    return SetupWizardResult(token: token, guildId: guild?.id, serviceStarted: serviceStarted)
}

// MARK: - Steps

private struct ResolvedToken {
    let token: String
    let bot: DiscordBotIdentity
}

private func resolveToken(deps: SetupWizardDeps) async -> ResolvedToken? {
    let out = deps.output
    if let existing = readEnvValue(url: deps.envFileURL, key: "DISCORD_BOT_TOKEN"), !existing.isEmpty {
        out("저장된 토큰이 있습니다. 확인 중…")
        if let bot = try? await probeBotIdentity(token: existing, httpGet: deps.httpGet) {
            if askYesNo("현재 봇은 \(bot.username) 입니다. 이 봇을 계속 쓸까요?", deps: deps, defaultYes: true) {
                return ResolvedToken(token: existing, bot: bot)
            }
        } else {
            out("저장된 토큰이 더 이상 유효하지 않습니다. 새로 입력해 주세요.")
        }
        out("")
    }

    out("1) 봇 토큰을 붙여넣고 엔터를 누르세요. (입력은 화면에 보이지 않습니다)")
    out("   Discord Developer Portal → 내 애플리케이션 → 왼쪽 [Bot] 탭 → [Reset Token]")
    out("   ⚠️ OAuth2 탭의 Client Secret 이 아닙니다 — 점(.)이 2개 들어간 70자 내외 문자열입니다.")
    while true {
        deps.output("")
        guard let raw = deps.readSecret() else { return nil }
        let token = normalizeTokenInput(raw)
        switch classifyTokenInput(raw) {
        case .empty:
            out("   비어 있습니다. 다시 붙여넣어 주세요. (중단하려면 Ctrl+C)")
            continue
        case .clientSecret:
            out("   ✗ 이건 봇 토큰이 아닙니다 — 점(.)이 없는 걸 보니 OAuth2 탭의 Client Secret 같습니다.")
            out("     [Bot] 탭의 [Reset Token] 으로 받은 값을 넣어주세요.")
            continue
        case .malformed:
            out("   ✗ 봇 토큰 형태가 아닙니다 (점으로 나뉜 세 조각이어야 합니다). 복사가 잘렸는지 확인해 주세요.")
            continue
        case .botToken:
            break
        }
        out("   확인 중…")
        do {
            let bot = try await probeBotIdentity(token: token, httpGet: deps.httpGet)
            out("   ✓ 확인 완료 — 봇 이름: \(bot.username)")
            return ResolvedToken(token: token, bot: bot)
        } catch SetupProbeError.unauthorized {
            out("   ✗ 디스코드가 거절했습니다. 토큰이 만료됐거나(Reset Token 을 다시 눌렀거나) 잘못 복사됐습니다.")
        } catch {
            out("   ✗ 디스코드에 연결하지 못했습니다: \(error). 네트워크를 확인하고 다시 시도해 주세요.")
        }
    }
}

private enum GuildChoice {
    case picked(DiscordGuildSummary)
    /// No guild recorded — slash commands fall back to global registration (~1h).
    case skipped
    case aborted
}

private func resolveGuild(token: String, applicationId: String, deps: SetupWizardDeps) async -> GuildChoice {
    let out = deps.output
    out("2) 이 봇을 쓸 서버를 고릅니다.")
    while true {
        let guilds: [DiscordGuildSummary]
        do {
            guilds = try await probeBotGuilds(token: token, httpGet: deps.httpGet)
        } catch {
            out("   서버 목록을 가져오지 못했습니다: \(error)")
            out("   서버 선택을 건너뜁니다 — 슬래시 명령이 보이기까지 최대 1시간 걸립니다.")
            return .skipped
        }
        if guilds.isEmpty {
            out("")
            out("   이 봇이 들어가 있는 서버가 없습니다. 아래 주소를 열어 서버에 초대해 주세요:")
            out("")
            out("   \(botReinviteURL(applicationId: applicationId))")
            out("")
            out("   초대를 마쳤으면 엔터를 누르세요. (건너뛰려면 s 입력)")
            guard let answer = deps.readLine() else { return .aborted }
            if answer.trimmingCharacters(in: .whitespaces).lowercased() == "s" {
                out("   건너뜁니다 — 슬래시 명령이 보이기까지 최대 1시간 걸립니다.")
                return .skipped
            }
            continue
        }
        if guilds.count == 1 {
            out("   ✓ \(guilds[0].name)")
            return .picked(guilds[0])
        }
        out("")
        for (i, g) in guilds.enumerated() {
            out("   \(i + 1)) \(g.name)")
        }
        out("")
        out("   번호를 입력하세요.")
        guard let answer = deps.readLine() else { return .aborted }
        guard let pick = Int(answer.trimmingCharacters(in: .whitespaces)), pick >= 1, pick <= guilds.count else {
            out("   1 부터 \(guilds.count) 사이의 번호를 입력해 주세요.")
            continue
        }
        out("   ✓ \(guilds[pick - 1].name)")
        return .picked(guilds[pick - 1])
    }
}

private func askYesNo(_ question: String, deps: SetupWizardDeps, defaultYes: Bool) -> Bool {
    deps.output("\(question) [\(defaultYes ? "Y/n" : "y/N")]")
    guard let answer = deps.readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
        return defaultYes
    }
    if answer.isEmpty { return defaultYes }
    return answer.hasPrefix("y")
}

// MARK: - Env file

func readEnvValue(url: URL, key: String) -> String? {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return parseEnvFile(content)[key]
}

/// `KEY=value` per line; `#` comments and blanks skipped. Values are used verbatim except for
/// one layer of surrounding quotes, which `set -a; . env` would have stripped too.
public func parseEnvFile(_ content: String) -> [String: String] {
    var result: [String: String] = [:]
    for rawLine in content.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { continue }
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        result[key] = value
    }
    return result
}

func writeEnvFile(url: URL, values: [String: String]) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let merged = upsertEnvContent(existing, values)
    try Data(merged.utf8).write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

/// Load `~/.dab/env` into the process environment so a foreground `dab` behaves like the
/// service, which gets the same file sourced by the generated run.sh. Existing process env
/// wins — an explicit `export` in the caller's shell must stay authoritative.
public func loadDabEnvFile(
    url: URL = RedmineKeySecret.defaultEnvFileURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    setEnv: (String, String) -> Void = { name, value in _ = setenv(name, value, 1) }
) {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
    for (key, value) in parseEnvFile(content) where !value.isEmpty {
        if let existing = environment[key], !existing.isEmpty { continue }
        setEnv(key, value)
    }
}
