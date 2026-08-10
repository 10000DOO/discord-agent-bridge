import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("ServiceCommand (C13 dab service status/restart)")
struct ServiceCommandTests {
    // Mirrors src/service/service.test.ts's launchd describe block — no real launchctl
    // spawn, no real filesystem touch.

    private func makeDeps(
        home: String = "/home/tester",
        plistExists: Bool = false,
        isHomebrew: Bool = false,
        calls: LockedBox<[(String, [String])]>? = nil,
        logs: LockedBox<[String]>? = nil,
        result: @escaping @Sendable (String, [String]) -> ProcessCapture = { _, _ in ProcessCapture(exitCode: 0) }
    ) -> ServiceCommandDeps {
        ServiceCommandDeps(
            run: { exe, args, _ in
                calls?.withLock { $0.append((exe, args)) }
                return result(exe, args)
            },
            fileExists: { _ in plistExists },
            home: home,
            log: { message in logs?.withLock { $0.append(message) } },
            isHomebrew: isHomebrew
        )
    }

    private func plist(_ home: String = "/home/tester") -> String {
        "\(home)/Library/LaunchAgents/com.discord-agent-bridge.plist"
    }

    @Test func statusReportsRunningWhenLaunchctlListContainsLabel() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(plistExists: true, logs: logs) { _, _ in
            ProcessCapture(stdout: "123\t0\tcom.discord-agent-bridge\n", exitCode: 0)
        }
        let ok = await runServiceCommand(["status"], deps: deps)
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("실행 중: 예"))
        #expect(text.contains("있음"))
    }

    @Test func statusReportsNotRunningWhenLabelAbsent() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(plistExists: false, logs: logs) { _, _ in
            ProcessCapture(stdout: "PID\tStatus\tLabel\n", exitCode: 0)
        }
        let ok = await runServiceCommand(["status"], deps: deps)
        #expect(ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("실행 중: 아니오"))
        #expect(text.contains("없음"))
    }

    @Test func restartUnloadsThenLoads() async {
        let calls = LockedBox<[(String, [String])]>([])
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(calls: calls, logs: logs)
        let ok = await runServiceCommand(["restart"], deps: deps)
        #expect(ok)
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 2)
        #expect(recorded[0] == ("launchctl", ["unload", plist()]))
        #expect(recorded[1] == ("launchctl", ["load", "-w", plist()]))
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("재시작"))
    }

    @Test func restartFailsCleanlyWhenLoadReturnsNonZero() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(logs: logs) { _, args in
            args.first == "load" ? ProcessCapture(exitCode: 1) : ProcessCapture(exitCode: 0)
        }
        let ok = await runServiceCommand(["restart"], deps: deps)
        #expect(!ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("실패"))
        #expect(text.contains("README"))
    }

    @Test func unknownSubcommandPrintsUsageAndFails() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(logs: logs)
        let ok = await runServiceCommand(["install"], deps: deps)
        #expect(!ok)
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("사용법: dab service"))
        #expect(text.contains("install.sh"))
    }

    // A Homebrew keg is supervised by `brew services` under homebrew.mxcl.dab — reading
    // launchctl for com.discord-agent-bridge reports a running bot as absent.

    @Test func homebrewStatusReadsBrewServicesNotLaunchctl() async {
        let calls = LockedBox<[(String, [String])]>([])
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(plistExists: true, isHomebrew: true, calls: calls, logs: logs) { _, _ in
            ProcessCapture(stdout: "Name Status User        File\ndab  started leegeonjoon ~/Library/LaunchAgents/homebrew.mxcl.dab.plist\n", exitCode: 0)
        }
        let ok = await runServiceCommand(["status"], deps: deps)
        #expect(ok)
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first! == ("brew", ["services", "list"]))
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("설치 방식: Homebrew"))
        #expect(text.contains("실행 중: 예"))
        #expect(text.contains("homebrew.mxcl.dab.plist"))
    }

    @Test func homebrewStatusReportsStoppedService() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(plistExists: false, isHomebrew: true, logs: logs) { _, _ in
            ProcessCapture(stdout: "Name Status User File\ndab  none\n", exitCode: 0)
        }
        #expect(await runServiceCommand(["status"], deps: deps))
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("실행 중: 아니오"))
        #expect(text.contains("자동 실행 등록: 없음"))
    }

    @Test func homebrewRestartUsesBrewServices() async {
        let calls = LockedBox<[(String, [String])]>([])
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(isHomebrew: true, calls: calls, logs: logs)
        #expect(await runServiceCommand(["restart"], deps: deps))
        let recorded = calls.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first! == ("brew", ["services", "restart", "dab"]))
        #expect(logs.withLock { $0.joined() }.contains("재시작했습니다"))
    }

    @Test func homebrewRestartFailsCleanlyWithBrewGuidance() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(isHomebrew: true, logs: logs) { _, _ in ProcessCapture(exitCode: 1) }
        #expect(!(await runServiceCommand(["restart"], deps: deps)))
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(text.contains("실패"))
        #expect(text.contains("brew services restart dab"))
    }

    @Test func homebrewUsageDoesNotPointAtAScriptTheUserDoesNotHave() async {
        let logs = LockedBox<[String]>([])
        let deps = makeDeps(isHomebrew: true, logs: logs)
        #expect(!(await runServiceCommand(["install"], deps: deps)))
        let text = logs.withLock { $0.joined(separator: "\n") }
        #expect(!text.contains("install.sh"))
        #expect(text.contains("brew uninstall dab"))
    }

    @Test func brewServiceStatusParsesTheDabRowOnly() {
        let out = "Name    Status  User        File\ndabble  started someone     x\ndab     none\n"
        #expect(brewServiceStatus(out, formula: "dab") == "none")
        #expect(brewServiceStatus("Name Status\n", formula: "dab") == nil)
    }
}
