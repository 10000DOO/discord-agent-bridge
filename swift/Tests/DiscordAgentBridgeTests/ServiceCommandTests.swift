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
            log: { message in logs?.withLock { $0.append(message) } }
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
}
