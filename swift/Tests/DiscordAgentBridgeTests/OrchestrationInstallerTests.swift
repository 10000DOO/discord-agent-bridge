import Foundation
import Testing
@testable import DiscordAgentBridge

/// Fakes "no global settings.json" for the R7 copy step without ever touching the real
/// `~/.claude/settings.json` — overrides only the single-arg `fileExists(atPath:)` (what
/// `copyGlobalSettingsJSON` checks) to lie about that one path, deferring to `super` for every
/// other path `installProject` checks (root dir, backups, stale skill files, ...).
private final class HidingGlobalSettingsFileManager: FileManager {
    private let hiddenPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")

    override func fileExists(atPath path: String) -> Bool {
        if path == hiddenPath { return false }
        return super.fileExists(atPath: path)
    }
}

/// Fakes the *global* `~/.claude/skills/` directory listing for R13 tests, without ever
/// touching the real directory — overrides only `contentsOfDirectory(atPath:)` for that one
/// path (what `OrchestrationInstaller.existingSkillIds` lists), deferring to `super` for every
/// other path. `presentIds: []` (the default) means "nothing installed globally" — this repo's
/// dev machines commonly already have several of the bundle's domain skills installed globally
/// (`cocoa-patterns`, `xcode-build-verify`, ...), which would otherwise make "does a fresh
/// install write every skill" assertions flaky depending on which machine runs the test.
private final class FakingGlobalSkillsFileManager: FileManager {
    private let globalSkillsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/skills")
    private let presentIds: [String]

    init(presentIds: [String] = []) {
        self.presentIds = presentIds
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if path == globalSkillsPath { return presentIds }
        return try super.contentsOfDirectory(atPath: path)
    }
}

@Suite("OrchestrationInstaller")
struct OrchestrationInstallerTests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func installProject_firstRun_writesClaudeMdRolesSkillsWithNoBackup() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Hides this machine's real global skills so every bundle skill is expected to install
        // (R13 completion condition ⑤ — "가짜 홈이 비어 있으면 전부 설치된다").
        let report = OrchestrationInstaller.installProject(root: root, fileManager: FakingGlobalSkillsFileManager())
        #expect(report.errors.isEmpty, "errors: \(report.errors)")
        // First run: no prior .claude/ to back up (§4.2a existence check, not a state flag).
        #expect(report.backupPath == nil)
        #expect(report.removedPaths.isEmpty)
        #expect(report.skippedSkills.isEmpty)

        let claudeMd = try String(
            contentsOf: root.appendingPathComponent(".claude/CLAUDE.md"), encoding: .utf8
        )
        #expect(claudeMd.contains("역할 색인"))
        #expect(claudeMd.contains("docs/issues/"))

        for role in OrchestrationProjectBundle.roles {
            let path = root.appendingPathComponent(".claude/roles/\(role.id).md")
            #expect(FileManager.default.fileExists(atPath: path.path), "missing role \(role.id)")
        }
        for skill in OrchestrationProjectBundle.skills {
            let path = root.appendingPathComponent(".claude/skills/\(skill.id)/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: path.path), "missing skill \(skill.id)")
        }
        // All 6 former subagents were disposed of by WO-8 §3-7④ — none remain to install.
        #expect(OrchestrationProjectBundle.subagents.isEmpty)
        let agentsDir = root.appendingPathComponent(".claude/agents")
        if FileManager.default.fileExists(atPath: agentsDir.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: agentsDir.path).isEmpty)
        }
    }

    @Test func installProject_rerun_backsUpPriorClaudeDirAndReinstallsRoles() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = OrchestrationInstaller.installProject(root: root, fileManager: FakingGlobalSkillsFileManager())
        #expect(first.errors.isEmpty)
        #expect(first.backupPath == nil)

        // `roles/` isn't R13-gated (only skills are) — corrupt a role file and confirm reinstall
        // always overwrites it, same idempotent delete-then-recreate pattern as skills/agents.
        let roleFile = root.appendingPathComponent(".claude/roles/ORCHESTRATOR.md")
        try "corrupted".write(to: roleFile, atomically: true, encoding: .utf8)

        let second = OrchestrationInstaller.installProject(root: root, fileManager: FakingGlobalSkillsFileManager())
        #expect(second.errors.isEmpty, "errors: \(second.errors)")
        #expect(second.removedPaths.contains { $0.contains("ORCHESTRATOR.md") })
        let content = try String(contentsOf: roleFile, encoding: .utf8)
        #expect(content != "corrupted")
        #expect(content == OrchestrationProjectBundle.roles.first { $0.id == "ORCHESTRATOR" }?.markdown)

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

    // MARK: - R7: global ~/.claude/settings.json -> project-local .claude/settings.json

    // ponytail: `copyGlobalSettingsJSON` hardcodes NSHomeDirectory() with no injectable path
    // (D14/P13), and NSHomeDirectory() ignores $HOME overrides on Darwin, so these tests read
    // whatever the real global settings.json contains rather than faking "home". Upgrade path if
    // this ever flakes in CI: give `installProject` an injectable global-settings path.

    @Test func installProject_copiesGlobalSettingsJSON_whenGlobalExists() throws {
        let globalPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        guard let globalContent = try? String(contentsOfFile: globalPath, encoding: .utf8) else {
            return // no global settings.json on this machine - nothing to verify
        }

        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = OrchestrationInstaller.installProject(root: root)
        #expect(report.errors.isEmpty, "errors: \(report.errors)")

        let localSettings = try String(
            contentsOf: root.appendingPathComponent(".claude/settings.json"), encoding: .utf8
        )
        #expect(localSettings == globalContent)
    }

    @Test func installProject_skipsSettingsJSON_whenGlobalMissing() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = OrchestrationInstaller.installProject(root: root, fileManager: HidingGlobalSettingsFileManager())
        #expect(report.errors.isEmpty, "errors: \(report.errors)")
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".claude/settings.json").path
        ))
    }

    @Test func installProject_rerun_overwritesLocalSettingsJSONRegardlessOfPriorContent() throws {
        let globalPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        guard let globalContent = try? String(contentsOfFile: globalPath, encoding: .utf8) else {
            return // no global settings.json on this machine - nothing to verify
        }

        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = OrchestrationInstaller.installProject(root: root)
        #expect(first.errors.isEmpty)

        let settingsURL = root.appendingPathComponent(".claude/settings.json")
        try "stale local content".write(to: settingsURL, atomically: true, encoding: .utf8)

        let second = OrchestrationInstaller.installProject(root: root)
        #expect(second.errors.isEmpty, "errors: \(second.errors)")

        let localSettings = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(localSettings == globalContent)
        #expect(localSettings != "stale local content")
    }

    // MARK: - R13/D19: conditional skill install (design_orchestration_module_agents.md WO-8 step 8)

    @Test func installProject_skipsSkillFakedAsGloballyPresent() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = OrchestrationInstaller.installProject(
            root: root,
            fileManager: FakingGlobalSkillsFileManager(presentIds: ["cocoa-patterns"])
        )
        #expect(report.errors.isEmpty, "errors: \(report.errors)")
        #expect(report.skippedSkills == ["cocoa-patterns"])
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".claude/skills/cocoa-patterns/SKILL.md").path
        ))
        // Everything else still installs normally.
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".claude/skills/issue-artifacts/SKILL.md").path
        ))
    }

    @Test func installProject_rerun_skipsSkillsAlreadyInstalledByPriorRun() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // First run with globals hidden: nothing skipped, every bundle skill lands under the
        // project's own `.claude/skills/`.
        let first = OrchestrationInstaller.installProject(root: root, fileManager: FakingGlobalSkillsFileManager())
        #expect(first.skippedSkills.isEmpty)

        // Second run: the project's own copies from run 1 are still on disk when
        // `existingSkillIds` is collected (before the skills loop deletes/recreates anything —
        // WO-8 step 8's "삭제 전 수집한 목록" requirement), so every skill is now "already there"
        // and gets skipped rather than rewritten.
        let second = OrchestrationInstaller.installProject(root: root, fileManager: FakingGlobalSkillsFileManager())
        #expect(Set(second.skippedSkills) == Set(OrchestrationProjectBundle.skills.map(\.id)))
    }

    @Test func existingSkillIds_emptyFakeHome_reportsNothingExisting() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let ids = OrchestrationInstaller.existingSkillIds(root: root, homeDir: fakeHome.path, fm: .default)
        #expect(ids.isEmpty)
    }

    @Test func existingSkillIds_skillPresentInFakeGlobalHome_isReported() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".claude/skills/cocoa-patterns", isDirectory: true),
            withIntermediateDirectories: true
        )

        let ids = OrchestrationInstaller.existingSkillIds(root: root, homeDir: fakeHome.path, fm: .default)
        #expect(ids == ["cocoa-patterns"])
    }

    @Test func existingSkillIds_skillAlreadyInProject_isReported() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/skills/issue-manager", isDirectory: true),
            withIntermediateDirectories: true
        )

        let ids = OrchestrationInstaller.existingSkillIds(root: root, homeDir: fakeHome.path, fm: .default)
        #expect(ids == ["issue-manager"])
    }

    @Test func existingSkillIds_orchestrationAlwaysExcluded() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeHome = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".claude/skills/orchestration", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/skills/orchestration", isDirectory: true),
            withIntermediateDirectories: true
        )

        let ids = OrchestrationInstaller.existingSkillIds(root: root, homeDir: fakeHome.path, fm: .default)
        #expect(!ids.contains("orchestration"))
    }
}
