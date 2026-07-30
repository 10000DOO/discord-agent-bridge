import Foundation

public struct OrchestrationInstallReport: Sendable, Equatable {
    public var removedPaths: [String]
    public var writtenPaths: [String]
    public var errors: [String]
    /// Path of the `.claude/` backup zip created before this install, or nil when no prior
    /// `.claude/` existed (first run — nothing to back up).
    public var backupPath: String?

    public init(
        removedPaths: [String] = [],
        writtenPaths: [String] = [],
        errors: [String] = [],
        backupPath: String? = nil
    ) {
        self.removedPaths = removedPaths
        self.writtenPaths = writtenPaths
        self.errors = errors
        self.backupPath = backupPath
    }
}

/// Installs the project-scoped orchestration bundle (`OrchestrationProjectBundle`) into
/// `<project-root>/.claude/` for the `/orchestration` command (design
/// design_orchestration_project_scoped_command.md §4.2/§4.2a). Claude only — the old global
/// 3-backend (Claude/Codex/Grok) installer was removed (§6 decision ①); this type now owns a
/// single entry point, `installProject`.
public enum OrchestrationInstaller {
    /// `<root>/.claude/{CLAUDE.md, skills/*/SKILL.md, agents/*.md}` only — Codex/Grok and
    /// `settings.json`/LSP patching are not part of this path (§6 decision ①).
    ///
    /// Step 0 backs up any existing `<root>/.claude/` to a zip before touching it; a backup
    /// failure aborts here with no delete/rewrite (§4.2a). CLAUDE.md is fully overwritten;
    /// `skills/{id}/` and `agents/{id}.md` are removed then recreated (same idempotent pattern
    /// the old global installer already used). Safe to call repeatedly — re-running always backs
    /// up again (new timestamped zip) and rewrites the same content (§5: no separate "already
    /// installed" branch needed).
    public static func installProject(
        root: URL,
        fileManager: FileManager = .default
    ) -> OrchestrationInstallReport {
        var report = OrchestrationInstallReport()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            report.errors.append("project root does not exist: \(root.path)")
            return report
        }
        let backup = backupExistingClaudeDir(root: root, fileManager: fileManager)
        if let error = backup.error {
            report.errors.append(error)
            return report
        }
        report.backupPath = backup.path

        let claudeRoot = root.appendingPathComponent(".claude", isDirectory: true)
        ensureDir(claudeRoot, fm: fileManager, report: &report)
        writeFile(
            claudeRoot.appendingPathComponent("CLAUDE.md"),
            content: OrchestrationProjectBundle.claudeMdBody,
            fm: fileManager,
            report: &report
        )

        let skillsRoot = claudeRoot.appendingPathComponent("skills", isDirectory: true)
        ensureDir(skillsRoot, fm: fileManager, report: &report)
        for skill in OrchestrationProjectBundle.skills {
            let dir = skillsRoot.appendingPathComponent(skill.id, isDirectory: true)
            removeIfExists(dir, fm: fileManager, report: &report)
            ensureDir(dir, fm: fileManager, report: &report)
            writeFile(dir.appendingPathComponent("SKILL.md"), content: skill.markdown, fm: fileManager, report: &report)
        }

        let agentsRoot = claudeRoot.appendingPathComponent("agents", isDirectory: true)
        ensureDir(agentsRoot, fm: fileManager, report: &report)
        for agent in OrchestrationProjectBundle.subagents {
            let path = agentsRoot.appendingPathComponent("\(agent.id).md")
            removeIfExists(path, fm: fileManager, report: &report)
            writeFile(path, content: agent.markdown, fm: fileManager, report: &report)
        }

        return report
    }

    /// `<root>/.claude` → `<root>/.claude-backups/orchestration-{stamp}.zip` (§4.2a). No prior
    /// `.claude/` → skip entirely (`path: nil, error: nil`); this is a plain existence check, not
    /// an "already installed" state flag (§5). Shells out to `zip -r -q` synchronously via
    /// `/usr/bin/env` (PATH lookup) rather than adding a new SPM compression dependency — same
    /// non-absolute-path convention as `Update/Installer.swift`'s `runUpdateCommand`, since a
    /// hardcoded `/usr/bin/zip` doesn't exist on Linux/Windows (README: supported platforms).
    private static func backupExistingClaudeDir(
        root: URL,
        fileManager: FileManager
    ) -> (path: String?, error: String?) {
        let claudeDir = root.appendingPathComponent(".claude", isDirectory: true)
        guard fileManager.fileExists(atPath: claudeDir.path) else {
            return (nil, nil)
        }
        let backupsDir = root.appendingPathComponent(".claude-backups", isDirectory: true)
        do {
            try fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            return (nil, "mkdir \(backupsDir.path): \(error.localizedDescription)")
        }
        let stamp = iso8601Now().replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let zipURL = backupsDir.appendingPathComponent("orchestration-\(stamp).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = root
        // Compress ".claude" as a relative path (cwd = project root) so unzip restores it in place.
        process.arguments = ["zip", "-r", "-q", zipURL.path, ".claude"]
        do {
            try process.run()
        } catch {
            return (nil, "zip \(zipURL.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return (nil, "zip exited with status \(process.terminationStatus): \(zipURL.path)")
        }
        return (zipURL.path, nil)
    }

    // MARK: - IO helpers

    private static func removeIfExists(_ url: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
            report.removedPaths.append(url.path)
        } catch {
            report.errors.append("remove \(url.path): \(error.localizedDescription)")
        }
    }

    private static func ensureDir(_ url: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            report.errors.append("mkdir \(url.path): \(error.localizedDescription)")
        }
    }

    private static func writeFile(_ url: URL, content: String, fm: FileManager, report: inout OrchestrationInstallReport) {
        do {
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            report.writtenPaths.append(url.path)
        } catch {
            report.errors.append("write \(url.path): \(error.localizedDescription)")
        }
    }
}
