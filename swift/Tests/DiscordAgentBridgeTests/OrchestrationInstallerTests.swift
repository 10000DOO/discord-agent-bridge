import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("OrchestrationInstaller")
struct OrchestrationInstallerTests {
    private func tempHomes() throws -> (OrchestrationHomes, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let homes = OrchestrationHomes(
            claude: root.appendingPathComponent("claude", isDirectory: true),
            codex: root.appendingPathComponent("codex", isDirectory: true),
            grok: root.appendingPathComponent("grok", isDirectory: true)
        )
        return (homes, root)
    }

    @Test func replaceMarkedBlock_removesThenAppendsAtEnd() {
        let body1 = "v1-rule"
        let first = OrchestrationInstaller.replaceMarkedBlock(existing: nil, body: body1)
        #expect(first.removedExistingBlock == false)
        #expect(first.text.contains(body1))

        let body2 = "v2-rule"
        // Marker in the middle of file: remove it, keep prefix/suffix, append new block at end.
        let middle = "prefix\n\n" + first.text + "\nsuffix keep\n"
        let second = OrchestrationInstaller.replaceMarkedBlock(existing: middle, body: body2)
        #expect(second.removedExistingBlock == true)
        #expect(second.text.contains("prefix"))
        #expect(second.text.contains("suffix keep"))
        #expect(second.text.contains(body2))
        #expect(!second.text.contains(body1))
        #expect(second.text.components(separatedBy: OrchestrationBundle.markerBegin).count == 2)
        // New block is at the end (after suffix).
        let suffixIdx = second.text.range(of: "suffix keep")!
        let beginIdx = second.text.range(of: OrchestrationBundle.markerBegin)!
        #expect(suffixIdx.lowerBound < beginIdx.lowerBound)
    }

    @Test func ensureLSPPlugins_nilExisting_bootstrapsMinimalSkeleton() {
        let result = OrchestrationInstaller.ensureLSPPlugins(existing: nil)
        #expect(result.changed == true)
        #expect(result.error == nil)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any],
              let plugins = root["enabledPlugins"] as? [String: Bool] else {
            Issue.record("bootstrap text is not valid JSON")
            return
        }
        #expect(plugins["swift-lsp@claude-plugins-official"] == true)
        #expect(plugins["clangd-lsp@claude-plugins-official"] == true)
    }

    @Test func ensureLSPPlugins_bothAlreadyTrue_noChange() {
        let existing = """
        {
          "model": "sonnet",
          "enabledPlugins": {
            "swift-lsp@claude-plugins-official": true,
            "clangd-lsp@claude-plugins-official": true
          }
        }
        """
        let result = OrchestrationInstaller.ensureLSPPlugins(existing: existing)
        #expect(result.changed == false)
        #expect(result.text == existing)
        #expect(result.error == nil)
    }

    @Test func ensureLSPPlugins_oneFalse_replacedInPlace() {
        let existing = """
        {
          "enabledPlugins": {
            "swift-lsp@claude-plugins-official": true,
            "clangd-lsp@claude-plugins-official": false
          }
        }
        """
        let result = OrchestrationInstaller.ensureLSPPlugins(existing: existing)
        #expect(result.changed == true)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any],
              let plugins = root["enabledPlugins"] as? [String: Bool] else {
            Issue.record("patched text is not valid JSON")
            return
        }
        #expect(plugins["swift-lsp@claude-plugins-official"] == true)
        #expect(plugins["clangd-lsp@claude-plugins-official"] == true)
    }

    @Test func ensureLSPPlugins_missingEnabledPluginsKey_insertsNewTopLevelBlock() {
        let existing = """
        {
          "model": "sonnet"
        }
        """
        let result = OrchestrationInstaller.ensureLSPPlugins(existing: existing)
        #expect(result.changed == true)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] else {
            Issue.record("patched text is not valid JSON")
            return
        }
        #expect(root["model"] as? String == "sonnet")
        let plugins = root["enabledPlugins"] as? [String: Bool]
        #expect(plugins?["swift-lsp@claude-plugins-official"] == true)
        #expect(plugins?["clangd-lsp@claude-plugins-official"] == true)
    }

    // 8장 필수 테스트 케이스 ①: swift-lsp/clangd-lsp 이외의 다른 언어 LSP/플러그인 키가 이미
    // 설정된 상태에서도 그 키가 손상 없이 보존되는지.
    @Test func ensureLSPPlugins_preservesUnrelatedExistingPluginKeys() {
        let existing = """
        {
          "enabledPlugins": {
            "rust-analyzer-lsp@claude-plugins-official": true,
            "ponytail@ponytail": false
          }
        }
        """
        let result = OrchestrationInstaller.ensureLSPPlugins(existing: existing)
        #expect(result.changed == true)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any],
              let plugins = root["enabledPlugins"] as? [String: Bool] else {
            Issue.record("patched text is not valid JSON")
            return
        }
        #expect(plugins["rust-analyzer-lsp@claude-plugins-official"] == true)
        #expect(plugins["ponytail@ponytail"] == false) // untouched — not one of our forced keys
        #expect(plugins["swift-lsp@claude-plugins-official"] == true)
        #expect(plugins["clangd-lsp@claude-plugins-official"] == true)
    }

    @Test func ensureLSPPlugins_unparsableJSON_leavesTextUntouchedAndReportsError() {
        let broken = "{ not valid json"
        let result = OrchestrationInstaller.ensureLSPPlugins(existing: broken)
        #expect(result.changed == false)
        #expect(result.text == broken)
        #expect(result.error != nil)
    }

    @Test func ensureGrokLSPFeatureFlag_missingSection_appendsNewSection() {
        let existing = """
        [cli]
        installer = "internal"

        [ui]
        yolo = false
        """
        let result = OrchestrationInstaller.ensureGrokLSPFeatureFlag(existing: existing)
        #expect(result.changed == true)
        #expect(result.text.contains("[features]"))
        #expect(result.text.contains("lsp_tools = true"))
        #expect(result.text.contains("[cli]"))
        #expect(result.text.contains("[ui]"))
    }

    @Test func ensureGrokLSPFeatureFlag_sectionExistsWithoutKey_insertsKey() {
        let existing = """
        [features]
        some_other_flag = true

        [ui]
        yolo = false
        """
        let result = OrchestrationInstaller.ensureGrokLSPFeatureFlag(existing: existing)
        #expect(result.changed == true)
        #expect(result.text.contains("lsp_tools = true"))
        #expect(result.text.contains("some_other_flag = true")) // preserved
        #expect(result.text.contains("[ui]"))
    }

    @Test func ensureGrokLSPFeatureFlag_alreadyTrue_noChange() {
        let existing = """
        [features]
        lsp_tools = true

        [ui]
        yolo = false
        """
        let result = OrchestrationInstaller.ensureGrokLSPFeatureFlag(existing: existing)
        #expect(result.changed == false)
        #expect(result.text == existing)
    }

    // RV 재현 케이스(WO-9 High): `lsp_tools`로 시작하지만 다른 키(`lsp_tools_timeout`)가 prefix
    // 매칭으로 오인되어 통째로 치환되던 버그. 그 키는 보존되고 `lsp_tools = true`가 별도 줄로 추가돼야 함.
    @Test func ensureGrokLSPFeatureFlag_preservesUnrelatedPrefixedKey() {
        let existing = """
        [features]
        lsp_tools_timeout = 30

        [ui]
        yolo = false
        """
        let result = OrchestrationInstaller.ensureGrokLSPFeatureFlag(existing: existing)
        #expect(result.changed == true)
        #expect(result.text.contains("lsp_tools_timeout = 30")) // preserved, not overwritten
        #expect(result.text.contains("lsp_tools = true"))
        #expect(result.text.contains("[ui]"))
    }

    @Test func ensureGrokLSPServers_missingFile_createsBothEntries() {
        let result = OrchestrationInstaller.ensureGrokLSPServers(existing: nil)
        #expect(result.changed == true)
        #expect(result.error == nil)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] else {
            Issue.record("lsp.json bootstrap text is not valid JSON")
            return
        }
        let swiftEntry = root["swift"] as? [String: Any]
        #expect(swiftEntry?["command"] as? String == "sourcekit-lsp")
        let objcEntry = root["objective-c"] as? [String: Any]
        #expect(objcEntry?["command"] as? String == "clangd")
    }

    @Test func ensureGrokLSPServers_swiftPresentObjcMissing_addsOnlyMissing() {
        let existing = """
        {
          "swift": {
            "command": "sourcekit-lsp",
            "args": [],
            "extensionToLanguage": { ".swift": "swift" }
          }
        }
        """
        let result = OrchestrationInstaller.ensureGrokLSPServers(existing: existing)
        #expect(result.changed == true)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] else {
            Issue.record("patched lsp.json is not valid JSON")
            return
        }
        #expect(root["swift"] != nil)
        let objcEntry = root["objective-c"] as? [String: Any]
        #expect(objcEntry?["command"] as? String == "clangd")
    }

    @Test func ensureGrokLSPServers_bothAlreadyPresent_noChange() {
        let existing = """
        {
          "swift": { "command": "sourcekit-lsp", "args": [], "extensionToLanguage": { ".swift": "swift" } },
          "objective-c": { "command": "clangd", "args": [], "extensionToLanguage": { ".m": "objective-c" } }
        }
        """
        let result = OrchestrationInstaller.ensureGrokLSPServers(existing: existing)
        #expect(result.changed == false)
        #expect(result.text == existing)
        #expect(result.error == nil)
    }

    // 8장 필수 테스트 케이스 ②: python 등 swift/objective-c 이외의 언어 항목이 이미 있는 상태에서도
    // 그 항목이 손상 없이 보존되는지.
    @Test func ensureGrokLSPServers_preservesUnrelatedLanguageEntry() {
        let existing = """
        {
          "python": {
            "command": "pyright-langserver",
            "args": ["--stdio"],
            "extensionToLanguage": { ".py": "python" }
          }
        }
        """
        let result = OrchestrationInstaller.ensureGrokLSPServers(existing: existing)
        #expect(result.changed == true)
        guard let root = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any] else {
            Issue.record("patched lsp.json is not valid JSON")
            return
        }
        let pythonEntry = root["python"] as? [String: Any]
        #expect(pythonEntry?["command"] as? String == "pyright-langserver") // preserved untouched
        #expect(root["swift"] != nil)
        #expect(root["objective-c"] != nil)
    }

    @Test func install_writesClaudeCodexGrokLayouts() throws {
        let (homes, root) = try tempHomes()
        defer { try? FileManager.default.removeItem(at: root) }

        // Grok home must be created even when missing.
        #expect(!FileManager.default.fileExists(atPath: homes.grok.path))

        let report = OrchestrationInstaller.install(homes: homes)
        #expect(report.errors.isEmpty, "errors: \(report.errors)")
        #expect(!report.writtenPaths.isEmpty)

        // Claude
        let claudeMd = try String(contentsOf: homes.claude.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claudeMd.contains("영향도 분석"))
        #expect(claudeMd.contains(OrchestrationBundle.markerBegin))
        for id in ["issue-orchestration", "issue-analysis", "issue-artifacts", "issue-implementation"] {
            let skill = homes.claude.appendingPathComponent("skills/\(id)/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: skill.path))
        }
        for id in ["issue-analyzer", "impact-analyzer", "module-implementer", "common-handoff", "design-critic"] {
            let agent = homes.claude.appendingPathComponent("agents/\(id).md")
            #expect(FileManager.default.fileExists(atPath: agent.path))
        }

        // Codex
        let agentsMd = try String(contentsOf: homes.codex.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agentsMd.contains("이슈 오케스트레이션"))
        let codexToml = try String(
            contentsOf: homes.codex.appendingPathComponent("agents/impact-analyzer.toml"),
            encoding: .utf8
        )
        #expect(codexToml.contains("name = \"impact-analyzer\""))
        #expect(codexToml.contains("developer_instructions"))
        #expect(FileManager.default.fileExists(
            atPath: homes.codex.appendingPathComponent("skills/issue-orchestration/SKILL.md").path
        ))

        // Grok (folder created)
        #expect(FileManager.default.fileExists(atPath: homes.grok.path))
        let grokAgents = try String(contentsOf: homes.grok.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(grokAgents.contains("dab-orchestration BEGIN"))
        let grokAgent = try String(
            contentsOf: homes.grok.appendingPathComponent("agents/module-implementer.md"),
            encoding: .utf8
        )
        #expect(grokAgent.contains("name: module-implementer"))
        #expect(grokAgent.contains("permission_mode: default"))
        #expect(grokAgent.contains("prompt_mode: full"))
        #expect(grokAgent.contains("agents_md: true"))
        let grokReadOnly = try String(
            contentsOf: homes.grok.appendingPathComponent("agents/impact-analyzer.md"),
            encoding: .utf8
        )
        #expect(grokReadOnly.contains("permission_mode: plan"))
        #expect(FileManager.default.fileExists(
            atPath: homes.grok.appendingPathComponent("skills/issue-analysis/SKILL.md").path
        ))

        // Format samples vs existing tooling conventions
        let claudeAgent = try String(
            contentsOf: homes.claude.appendingPathComponent("agents/issue-analyzer.md"),
            encoding: .utf8
        )
        #expect(claudeAgent.hasPrefix("---\n"))
        #expect(claudeAgent.contains("description: \""))
        #expect(!claudeAgent.contains("permission_mode:")) // Claude agents do not use Grok fields
    }

    // 8장 필수 테스트 케이스 ①: 실제 install() 경로에서도 무관 키(rust-analyzer-lsp)가 보존되고
    // swift-lsp·clangd-lsp가 추가되는지.
    @Test func install_claudeSettingsJson_enablesLSPPluginsAndPreservesExistingKeys() throws {
        let (homes, root) = try tempHomes()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: homes.claude, withIntermediateDirectories: true)
        let settingsURL = homes.claude.appendingPathComponent("settings.json")
        let preSeeded = """
        {
          "model": "sonnet",
          "enabledPlugins": {
            "rust-analyzer-lsp@claude-plugins-official": true
          }
        }
        """
        try preSeeded.write(to: settingsURL, atomically: true, encoding: .utf8)

        let report = OrchestrationInstaller.install(homes: homes)
        #expect(report.errors.isEmpty, "errors: \(report.errors)")

        let text = try String(contentsOf: settingsURL, encoding: .utf8)
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let plugins = parsed["enabledPlugins"] as? [String: Bool] else {
            Issue.record("settings.json is not valid JSON after install")
            return
        }
        #expect(parsed["model"] as? String == "sonnet") // untouched existing unrelated top-level key
        #expect(plugins["rust-analyzer-lsp@claude-plugins-official"] == true) // preserved
        #expect(plugins["swift-lsp@claude-plugins-official"] == true)
        #expect(plugins["clangd-lsp@claude-plugins-official"] == true)
    }

    // 8장 필수 테스트 케이스 ②: 실제 install() 경로에서도 python 등 무관 언어 항목이 보존되고
    // config.toml [features] lsp_tools=true + lsp.json swift/objective-c 항목이 추가되는지.
    @Test func install_grokConfig_enablesLSPAndPreservesExistingLanguageEntry() throws {
        let (homes, root) = try tempHomes()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: homes.grok, withIntermediateDirectories: true)
        let configURL = homes.grok.appendingPathComponent("config.toml")
        try """
        [cli]
        installer = "internal"
        """.write(to: configURL, atomically: true, encoding: .utf8)
        let lspURL = homes.grok.appendingPathComponent("lsp.json")
        try """
        {
          "python": {
            "command": "pyright-langserver",
            "args": ["--stdio"],
            "extensionToLanguage": { ".py": "python" }
          }
        }
        """.write(to: lspURL, atomically: true, encoding: .utf8)

        let report = OrchestrationInstaller.install(homes: homes)
        #expect(report.errors.isEmpty, "errors: \(report.errors)")

        let configText = try String(contentsOf: configURL, encoding: .utf8)
        #expect(configText.contains("[features]"))
        #expect(configText.contains("lsp_tools = true"))
        #expect(configText.contains("[cli]")) // preserved
        #expect(configText.contains("installer = \"internal\"")) // preserved

        let lspText = try String(contentsOf: lspURL, encoding: .utf8)
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(lspText.utf8)) as? [String: Any] else {
            Issue.record("lsp.json is not valid JSON after install")
            return
        }
        let pythonEntry = parsed["python"] as? [String: Any]
        #expect(pythonEntry?["command"] as? String == "pyright-langserver") // preserved untouched
        let swiftEntry = parsed["swift"] as? [String: Any]
        #expect(swiftEntry?["command"] as? String == "sourcekit-lsp")
        let objcEntry = parsed["objective-c"] as? [String: Any]
        #expect(objcEntry?["command"] as? String == "clangd")
    }

    @Test func codexAndGrokFormatHelpers_matchExistingShapes() {
        let toml = OrchestrationInstaller.codexAgentTOML(
            id: "sample",
            description: "desc",
            instructions: "# body\n- rule"
        )
        #expect(toml.contains("name = \"sample\""))
        #expect(toml.contains("description = \"desc\""))
        #expect(toml.contains("developer_instructions = '''"))
        #expect(toml.contains("# body"))

        let grok = OrchestrationInstaller.grokAgentMarkdown(
            id: "sample",
            description: "desc",
            permissionMode: "plan",
            body: "# body"
        )
        #expect(grok.contains("permission_mode: plan"))
        #expect(grok.contains("model: inherit"))
    }

    @Test func install_removesThenRecreatesSkillsAndAgents() throws {
        let (homes, root) = try tempHomes()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = OrchestrationInstaller.install(homes: homes)
        #expect(first.removedPaths.isEmpty)

        // Stale file inside skill dir should disappear after reinstall (dir deleted then recreated).
        let skillDir = homes.claude.appendingPathComponent("skills/issue-orchestration", isDirectory: true)
        let stale = skillDir.appendingPathComponent("STALE.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: stale.path))

        let second = OrchestrationInstaller.install(homes: homes)
        #expect(second.removedPaths.contains { $0.contains("issue-orchestration") })
        #expect(second.removedPaths.contains { $0.contains("CLAUDE.md") && $0.contains("block") })
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(
            atPath: skillDir.appendingPathComponent("SKILL.md").path
        ))

        let text = try String(contentsOf: homes.claude.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(text.components(separatedBy: OrchestrationBundle.markerBegin).count == 2)
    }

    @Test func orchestrationSlashCommand_isRegistered() {
        #expect(allSlashCommandSpecs().contains { $0.name == "orchestration" })
    }
}
