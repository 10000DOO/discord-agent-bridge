import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("OrchestrationInstaller")
struct OrchestrationInstallerTests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func installProject_firstRun_writesClaudeMdAgentsSkillsWithNoBackup() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = OrchestrationInstaller.installProject(root: root)
        #expect(report.errors.isEmpty, "errors: \(report.errors)")
        // First run: no prior .claude/ to back up (§4.2a existence check, not a state flag).
        #expect(report.backupPath == nil)
        #expect(report.removedPaths.isEmpty)

        let claudeMd = try String(
            contentsOf: root.appendingPathComponent(".claude/CLAUDE.md"), encoding: .utf8
        )
        #expect(claudeMd.contains("이슈 오케스트레이션"))

        for skill in OrchestrationProjectBundle.skills {
            let path = root.appendingPathComponent(".claude/skills/\(skill.id)/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: path.path), "missing skill \(skill.id)")
        }
        for agent in OrchestrationProjectBundle.subagents {
            let path = root.appendingPathComponent(".claude/agents/\(agent.id).md")
            #expect(FileManager.default.fileExists(atPath: path.path), "missing agent \(agent.id)")
        }
    }

    @Test func installProject_rerun_backsUpPriorClaudeDirAndReinstalls() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = OrchestrationInstaller.installProject(root: root)
        #expect(first.errors.isEmpty)
        #expect(first.backupPath == nil)

        // Stale file inside a skill dir should disappear after reinstall (dir deleted then recreated).
        let skillDir = root.appendingPathComponent(".claude/skills/issue-orchestration", isDirectory: true)
        let stale = skillDir.appendingPathComponent("STALE.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: stale.path))

        let second = OrchestrationInstaller.installProject(root: root)
        #expect(second.errors.isEmpty, "errors: \(second.errors)")
        #expect(second.removedPaths.contains { $0.contains("issue-orchestration") })
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(
            atPath: skillDir.appendingPathComponent("SKILL.md").path
        ))

        // Backup zip actually created on re-run, containing the pre-reinstall .claude/ tree.
        guard let backupPath = second.backupPath else {
            Issue.record("expected a backup path on re-run")
            return
        }
        #expect(backupPath.hasSuffix(".zip"))
        #expect(backupPath.contains(".claude-backups"))
        #expect(FileManager.default.fileExists(atPath: backupPath))
        let size = try FileManager.default.attributesOfItem(atPath: backupPath)[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    @Test func installProject_backupFailure_abortsWithoutTouchingClaudeDir() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = OrchestrationInstaller.installProject(root: root)
        #expect(first.errors.isEmpty)
        let claudeMdURL = root.appendingPathComponent(".claude/CLAUDE.md")
        let before = try String(contentsOf: claudeMdURL, encoding: .utf8)

        // Force the backup's mkdir to fail: occupy `.claude-backups` with a plain file instead
        // of letting it be created as a directory.
        let backupsPath = root.appendingPathComponent(".claude-backups", isDirectory: false)
        try Data().write(to: backupsPath)

        let second = OrchestrationInstaller.installProject(root: root)
        #expect(!second.errors.isEmpty)
        #expect(second.backupPath == nil)
        // Aborted before any delete/rewrite — CLAUDE.md is byte-for-byte the same as before.
        let after = try String(contentsOf: claudeMdURL, encoding: .utf8)
        #expect(after == before)
        #expect(second.removedPaths.isEmpty)
        #expect(second.writtenPaths.isEmpty)
    }

    @Test func orchestrationSlashCommand_isRegistered() {
        #expect(allSlashCommandSpecs().contains { $0.name == "orchestration" })
    }
}
