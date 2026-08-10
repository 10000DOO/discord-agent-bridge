import Foundation

// `dab service <status|restart>` (C13) — macOS/launchd only (Q1: Linux/Windows out of
// scope). install/uninstall stay as swift/scripts/install.sh|uninstall.sh — this only
// fills the status/restart gap that had no implementation anywhere, not even a script.
// Mirrors src/service/index.ts + launchd.ts's status()/restart() 1:1: `status` runs bare
// `launchctl list` and substring-matches the label across all lines; `restart` does
// unload (best-effort) + `load -w` — the same sequence install.sh's own `load()` helper
// uses (NOT `launchctl kickstart -k`, which Installer.swift uses only for the running
// process's own auto-update self-restart, where unload would kill it mid-restart).

public struct ServiceCommandDeps: Sendable {
    public var run: UpdateCommandRunner
    public var fileExists: @Sendable (String) -> Bool
    public var home: String
    public var log: @Sendable (String) -> Void
    /// Homebrew kegs are supervised by `brew services`, not by install.sh's LaunchAgent —
    /// status/restart/usage all have to answer from the other one.
    public var isHomebrew: Bool

    public init(
        run: @escaping UpdateCommandRunner = { exe, args, env in
            await runUpdateCommand(executable: exe, args: args, extraEnv: env, timeoutMs: 10_000)
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        home: String = NSHomeDirectory(),
        log: @escaping @Sendable (String) -> Void = { print($0) },
        isHomebrew: Bool = isHomebrewInstall()
    ) {
        self.run = run
        self.fileExists = fileExists
        self.home = home
        self.log = log
        self.isHomebrew = isHomebrew
    }
}

private let serviceLabel = "com.discord-agent-bridge"

/// Dispatch `service <sub>`. Returns false on failure (caller maps to a non-zero exit).
public func runServiceCommand(_ argv: [String], deps: ServiceCommandDeps = ServiceCommandDeps()) async -> Bool {
    switch argv.first {
    case "status":
        return await serviceStatus(deps)
    case "restart":
        return await serviceRestart(deps)
    default:
        printServiceUsage(deps)
        return false
    }
}

private func printServiceUsage(_ deps: ServiceCommandDeps) {
    deps.log("사용법: dab service <status|restart>")
    if deps.isHomebrew {
        deps.log("  install    brew install 10000doo/discord-agent-bridge/dab 로 설치했습니다.")
        deps.log("  uninstall  brew services stop dab && brew uninstall dab 를 실행하세요.")
    } else {
        deps.log("  install    swift/scripts/install.sh 를 실행하세요.")
        deps.log("  uninstall  swift/scripts/uninstall.sh 를 실행하세요.")
    }
    deps.log("  status     등록/실행 상태를 출력합니다.")
    deps.log("  restart    서비스를 재시작합니다.")
}

private func serviceStatus(_ deps: ServiceCommandDeps) async -> Bool {
    if deps.isHomebrew {
        return await homebrewServiceStatus(deps)
    }
    let plist = launchdPlistPath(home: deps.home)
    let res = await deps.run("launchctl", ["list"], [:])
    let running = res.stdout.split(separator: "\n").contains { $0.contains(serviceLabel) }
    deps.log("자동 실행 등록: \(deps.fileExists(plist) ? "있음" : "없음") (\(plist))")
    deps.log("실행 중: \(running ? "예" : "아니오")")
    return true
}

/// `brew services list` prints `Name Status User File`; the `dab` row's status is `started`
/// while supervised and `none` when the formula is installed but was never started.
private func homebrewServiceStatus(_ deps: ServiceCommandDeps) async -> Bool {
    let plist = homebrewServicePlistPath(home: deps.home)
    let res = await deps.run("brew", ["services", "list"], [:])
    let status = brewServiceStatus(res.stdout, formula: "dab")
    deps.log("설치 방식: Homebrew")
    deps.log("자동 실행 등록: \(deps.fileExists(plist) ? "있음" : "없음") (\(plist))")
    deps.log("실행 중: \(status == "started" ? "예" : "아니오")\(status.map { " (brew services: \($0))" } ?? "")")
    if status == nil {
        deps.log("brew services 목록에서 dab 을 찾지 못했습니다 — `brew services list` 를 직접 확인해 주세요.")
    }
    return true
}

/// Second whitespace-separated column of the row whose first column is `formula`; nil when absent.
func brewServiceStatus(_ stdout: String, formula: String) -> String? {
    for line in stdout.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if fields.count >= 2, fields[0] == Substring(formula) { return String(fields[1]) }
    }
    return nil
}

private func serviceRestart(_ deps: ServiceCommandDeps) async -> Bool {
    if deps.isHomebrew {
        let res = await deps.run("brew", ["services", "restart", "dab"], [:])
        guard res.exitCode == 0 else {
            deps.log("서비스 재시작에 실패했습니다 (brew services restart dab).")
            deps.log("터미널에서 `brew services restart dab` 를 직접 실행해 보세요.")
            return false
        }
        deps.log("서비스를 재시작했습니다.")
        return true
    }
    let plist = launchdPlistPath(home: deps.home)
    _ = await deps.run("launchctl", ["unload", plist], [:])
    let res = await deps.run("launchctl", ["load", "-w", plist], [:])
    guard res.exitCode == 0 else {
        deps.log("서비스 재시작에 실패했습니다 (launchctl load).")
        deps.log("수동 방법은 README 를 참고하세요.")
        return false
    }
    deps.log("서비스를 재시작했습니다.")
    return true
}
