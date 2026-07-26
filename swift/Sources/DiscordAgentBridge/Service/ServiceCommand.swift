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

    public init(
        run: @escaping UpdateCommandRunner = { exe, args, env in
            await runUpdateCommand(executable: exe, args: args, extraEnv: env, timeoutMs: 10_000)
        },
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        home: String = NSHomeDirectory(),
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.run = run
        self.fileExists = fileExists
        self.home = home
        self.log = log
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
    deps.log("  install    swift/scripts/install.sh 를 실행하세요.")
    deps.log("  uninstall  swift/scripts/uninstall.sh 를 실행하세요.")
    deps.log("  status     등록/실행 상태를 출력합니다.")
    deps.log("  restart    서비스를 재시작합니다.")
}

private func serviceStatus(_ deps: ServiceCommandDeps) async -> Bool {
    let plist = launchdPlistPath(home: deps.home)
    let res = await deps.run("launchctl", ["list"], [:])
    let running = res.stdout.split(separator: "\n").contains { $0.contains(serviceLabel) }
    deps.log("자동 실행 등록: \(deps.fileExists(plist) ? "있음" : "없음") (\(plist))")
    deps.log("실행 중: \(running ? "예" : "아니오")")
    return true
}

private func serviceRestart(_ deps: ServiceCommandDeps) async -> Bool {
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
