import Testing
import Foundation
@testable import DiscordAgentBridge

// Pure SM tests — no Discord. Option lists injected (fake catalogs), not live probes.

private let CLAUDE_MODELS = [
    ModelChoice(value: "opus", label: "opus", supportedEffortLevels: ["low", "medium", "high", "max"]),
    ModelChoice(value: "sonnet", label: "sonnet"),
]
private let CODEX_MODELS = [
    ModelChoice(value: "gpt-5.5", label: "gpt-5.5"),
    ModelChoice(value: "gpt-5.4", label: "gpt-5.4"),
]
private let CLAUDE_PERMS = [
    ModelChoice(value: "default", label: "default"),
    ModelChoice(value: "plan", label: "plan"),
    ModelChoice(value: "acceptEdits", label: "acceptEdits"),
]
private let CODEX_PERMS = [
    ModelChoice(value: "read-only", label: "read-only"),
    ModelChoice(value: "workspace-write", label: "workspace-write"),
    ModelChoice(value: "danger-full-access", label: "danger-full-access"),
]
private let CLAUDE_EFFORTS = choices(["low", "medium", "high", "max"])
private let CODEX_EFFORTS = choices(["minimal", "low", "medium", "high"])

private func fakeOptions(backends: [Backend] = [.claude, .codex]) -> WizardOptionSource {
    WizardOptionSource(
        backends: backends,
        modelsFor: [
            .claude: CLAUDE_MODELS,
            .codex: CODEX_MODELS,
            .grok: [ModelChoice(value: "grok-4", label: "grok-4")],
        ],
        permsFor: [
            .claude: CLAUDE_PERMS,
            .codex: CODEX_PERMS,
            .grok: [ModelChoice(value: "default", label: "default")],
        ],
        effortsFor: [
            .claude: [
                "": CLAUDE_EFFORTS,
                "opus": choices(["low", "medium", "high", "max"]),
                "sonnet": CLAUDE_EFFORTS,
            ],
            .codex: [
                "": CODEX_EFFORTS,
                "gpt-5.5": CODEX_EFFORTS,
                "gpt-5.4": CODEX_EFFORTS,
            ],
            .grok: ["": [], "grok-4": []],
        ],
        defaultEffortFor: [
            .claude: "high",
            .codex: "medium",
            .grok: "",
        ],
        defaults: WizardDefaults(backend: .claude, model: "opus", effort: "high", permMode: "default")
    )
}

/// Temp dir with a `project` child for folder-step tests.
private func makeFolderRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-wizard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
    return root
}

private func makeWizard(
    options: WizardOptionSource = fakeOptions(),
    root: URL? = nil
) throws -> (ChannelWizard, URL) {
    let folderRoot: URL
    if let root {
        folderRoot = root
    } else {
        folderRoot = try makeFolderRoot()
    }
    let browser = DirectoryBrowser(allowedRoots: [folderRoot.path], startPath: folderRoot.path)
    let w = ChannelWizard(
        guildId: "g1",
        channelId: "c1",
        ownerId: "u1",
        browser: browser,
        options: options
    )
    return (w, folderRoot)
}

/// Confirm folder (root) and land on backend — shared setup for select-step tests.
@discardableResult
private func pastFolder(_ w: ChannelWizard) -> WizardStep {
    w.handle(WizardInput(id: "dir:here"))
}

private func selectOptions(_ wizard: ChannelWizard, customId: String) -> [WizardSelectOption] {
    for row in wizard.render().rows {
        for c in row.components {
            if case .select(let id, _, let opts) = c, id == customId { return opts }
        }
    }
    return []
}

private func componentIds(_ wizard: ChannelWizard) -> [String] {
    wizard.render().rows.flatMap { row in
        row.components.map { c in
            switch c {
            case .select(let id, _, _): return id
            case .button(let id, _, _, _): return id
            }
        }
    }
}

@Suite("ChannelWizard state machine (slice2 folder + button-advance)")
struct ChannelWizardTests {

    @Test func startsOnFolderThenAdvancesToDone() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.currentStep() == .folder)

        #expect(w.handle(WizardInput(id: "dir:into", value: "project")) == .folder)
        #expect(w.browserCwd() == root.appendingPathComponent("project").path)
        #expect(w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().cwd == root.appendingPathComponent("project").path)

        // Select change does NOT advance; Next commits.
        #expect(w.handle(WizardInput(id: "backend", value: "codex")) == .backend)
        #expect(w.current().backend == .claude)
        #expect(w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(w.current().backend == .codex)
        #expect(w.current().model == "gpt-5.5")
        #expect(w.current().effort == "medium")
        #expect(w.current().permMode == "read-only")

        #expect(w.handle(WizardInput(id: "model", value: "gpt-5.4")) == .model)
        #expect(w.handle(WizardInput(id: "model.next")) == .effort)
        #expect(w.current().model == "gpt-5.4")

        #expect(w.handle(WizardInput(id: "effort", value: "high")) == .effort)
        #expect(w.handle(WizardInput(id: "effort.next")) == .perm)
        #expect(w.current().effort == "high")

        #expect(w.handle(WizardInput(id: "perm.mode", value: "workspace-write")) == .perm)
        #expect(w.handle(WizardInput(id: "perm.start")) == .done)
        #expect(w.current().permMode == "workspace-write")

        let p = w.startParams
        #expect(p != nil)
        #expect(p?.backend == .codex)
        #expect(p?.model == "gpt-5.4")
        #expect(p?.effort == "high")
        #expect(p?.permMode == "workspace-write")
        #expect(p?.cwd == root.appendingPathComponent("project").path)
        #expect(p?.ownerId == "u1")
        #expect(p?.channelId == "c1")
    }

    @Test func dirUpOnFolderStep() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        w.handle(WizardInput(id: "dir:into", value: "project"))
        #expect(w.handle(WizardInput(id: "dir:up")) == .folder)
        #expect(w.browserCwd() == root.path)
    }

    @Test func keepingDefaultsAndPressingButtonsAdvancesToStart() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        #expect(w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(w.handle(WizardInput(id: "model.next")) == .effort)
        #expect(w.handle(WizardInput(id: "effort.next")) == .perm)
        #expect(w.handle(WizardInput(id: "perm.start")) == .done)
        #expect(w.startParams?.backend == .claude)
        #expect(w.startParams?.model == "opus")
        #expect(w.startParams?.effort == "high")
        #expect(w.startParams?.permMode == "default")
        #expect(w.startParams?.cwd == root.path)
    }

    @Test func skipsEffortWhenBackendOffersNone() throws {
        var opts = fakeOptions(backends: [.grok])
        opts.defaults = WizardDefaults(backend: .grok, model: "grok-4", effort: "", permMode: "default")
        let (w, root) = try makeWizard(options: opts)
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        #expect(w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(w.handle(WizardInput(id: "model.next")) == .perm)
        #expect(w.handle(WizardInput(id: "perm.start")) == .done)
        #expect(w.startParams?.effort == "")
    }

    @Test func selectChangeUpdatesPendingWithoutAdvancing() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        w.handle(WizardInput(id: "backend", value: "codex"))
        #expect(w.currentStep() == .backend)
        #expect(w.current().backend == .claude)
        let codex = selectOptions(w, customId: "backend").first { $0.value == "codex" }
        #expect(codex?.isDefault == true)
    }

    @Test func afterCodexBackendModelAndPermShowCodexCatalog() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        w.handle(WizardInput(id: "backend", value: "codex"))
        w.handle(WizardInput(id: "backend.next"))
        #expect(selectOptions(w, customId: "model").map(\.value) == ["gpt-5.5", "gpt-5.4"])
        w.handle(WizardInput(id: "model.next"))
        let effortValues = selectOptions(w, customId: "effort").map(\.value)
        #expect(effortValues.contains("minimal"))
        #expect(!effortValues.contains("max"))
        w.handle(WizardInput(id: "effort.next"))
        #expect(selectOptions(w, customId: "perm.mode").map(\.value) == [
            "read-only", "workspace-write", "danger-full-access",
        ])
    }

    @Test func afterClaudeBackendShowsClaudeCatalog() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        w.handle(WizardInput(id: "backend.next"))
        #expect(selectOptions(w, customId: "model").map(\.value) == ["opus", "sonnet"])
        w.handle(WizardInput(id: "model.next"))
        let effortValues = selectOptions(w, customId: "effort").map(\.value)
        #expect(effortValues.contains("max"))
        #expect(!effortValues.contains("minimal"))
        w.handle(WizardInput(id: "effort.next"))
        let perms = selectOptions(w, customId: "perm.mode").map(\.value)
        #expect(perms.contains("acceptEdits"))
        #expect(!perms.contains("workspace-write"))
    }

    @Test func backFromBackendReturnsToFolder() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        w.handle(WizardInput(id: "backend", value: "codex"))
        w.handle(WizardInput(id: "backend.next"))
        #expect(w.current().backend == .codex)
        #expect(w.handle(WizardInput(id: "wizard.back")) == .backend)
        #expect(w.handle(WizardInput(id: "wizard.back")) == .folder)
        #expect(w.browserCwd() == root.path)
        // re-confirm folder → backend; committed codex kept from before
        #expect(w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().backend == .codex)
    }

    @Test func backKeepsCommittedSelections() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        w.handle(WizardInput(id: "backend", value: "codex"))
        w.handle(WizardInput(id: "backend.next"))
        #expect(w.current().backend == .codex)
        w.handle(WizardInput(id: "model", value: "gpt-5.4"))
        // pending model discarded on back; committed backend kept
        #expect(w.handle(WizardInput(id: "wizard.back")) == .backend)
        #expect(w.current().backend == .codex)
        #expect(w.current().model == "gpt-5.5") // applyBackend default, not pending gpt-5.4
        #expect(w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(w.current().backend == .codex)
    }

    @Test func backOnFirstStepIsNoop() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.handle(WizardInput(id: "wizard.back")) == .folder)
    }

    @Test func cancelEndsWizard() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.handle(WizardInput(id: "cancel")) == .cancelled)
        #expect(w.startParams == nil)
        #expect(w.render().rows.isEmpty)
    }

    @Test func permBackSkipsEffortWhenEmpty() throws {
        var opts = fakeOptions(backends: [.grok])
        opts.defaults = WizardDefaults(backend: .grok, model: "grok-4", effort: "", permMode: "default")
        let (w, root) = try makeWizard(options: opts)
        defer { try? FileManager.default.removeItem(at: root) }
        pastFolder(w)
        w.handle(WizardInput(id: "backend.next"))
        w.handle(WizardInput(id: "model.next"))
        #expect(w.currentStep() == .perm)
        #expect(w.handle(WizardInput(id: "wizard.back")) == .model)
    }

    @Test func folderRenderIncludesDirIds() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = componentIds(w)
        #expect(ids.contains("dir:into"))
        #expect(ids.contains("dir:here"))
        #expect(ids.contains("cancel"))
        pastFolder(w)
        let ids2 = componentIds(w)
        #expect(ids2.contains("backend"))
        #expect(ids2.contains("backend.next"))
        #expect(ids2.contains("wizard.back"))
    }

    @Test func isWizardCustomIdRecognizesFolderAndSelectIds() {
        #expect(isWizardCustomId("backend"))
        #expect(isWizardCustomId("perm.start"))
        #expect(isWizardCustomId("wizard.back"))
        #expect(isWizardCustomId("dir:here"))
        #expect(isWizardCustomId("dir:into"))
        #expect(isWizardCustomId("dir:up"))
        #expect(!isWizardCustomId("perm:abc:allow"))
    }

    @Test func browserGoToUpdatesFolderView() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project").path
        #expect(w.browserGoTo(project))
        #expect(w.browserCwd() == project)
        #expect(w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().cwd == project)
    }

    @Test func wizardDefaultCwdUsesDabCwdThenHome() {
        #expect(wizardDefaultCwd(env: ["DAB_CWD": "/work"], home: "/Users/x") == "/work")
        #expect(wizardDefaultCwd(env: ["DAB_CWD": ""], home: "/Users/x") == "/Users/x")
        #expect(wizardDefaultCwd(env: [:], home: "/Users/x") == "/Users/x")
    }

    @Test func loadWizardOptionSourceFromInjectedCatalogs() async {
        struct FixedCatalog: ProviderCatalog {
            let m: [ModelChoice]
            let p: [ModelChoice]
            let e: [ModelChoice]
            let d: String?
            func models(configured: String?) async -> [ModelChoice] { m }
            func permissionChoices() async -> [ModelChoice] { p }
            func effortChoices(modelLevels: [String]?) -> [ModelChoice] {
                if let levels = modelLevels, !levels.isEmpty { return choices(levels) }
                return e
            }
            func runtimeEffortChoices(modelLevels: [String]?) -> [ModelChoice] {
                effortChoices(modelLevels: modelLevels)
            }
            func defaultEffort() async -> String? { d }
        }
        let src = await loadWizardOptionSource { b in
            switch b {
            case .claude:
                return FixedCatalog(
                    m: [ModelChoice(value: "opus", label: "opus", supportedEffortLevels: ["high"])],
                    p: [ModelChoice(value: "default", label: "default")],
                    e: choices(["low", "high"]),
                    d: "high"
                )
            case .codex:
                return FixedCatalog(
                    m: [ModelChoice(value: "gpt-5.5", label: "gpt-5.5")],
                    p: [ModelChoice(value: "read-only", label: "read-only")],
                    e: choices(["minimal"]),
                    d: "minimal"
                )
            case .grok:
                return FixedCatalog(
                    m: [ModelChoice(value: "g", label: "g")],
                    p: [ModelChoice(value: "default", label: "default")],
                    e: [],
                    d: ""
                )
            }
        }
        #expect(src.backends == Backend.allCases)
        #expect(src.models(for: .claude).map(\.value) == ["opus"])
        #expect(src.efforts(for: .claude, model: "opus").map(\.value) == ["high"])
        #expect(src.perms(for: .codex).map(\.value) == ["read-only"])
        #expect(src.defaults.backend == .claude)
        #expect(src.defaults.model == "opus")
    }

    @Test func capSelectOptionsKeepsSelectedPast25() {
        var opts: [WizardSelectOption] = (0..<30).map {
            WizardSelectOption(label: "m\($0)", value: "m\($0)", isDefault: false)
        }
        opts[27].isDefault = true
        let capped = capSelectOptions(opts)
        #expect(capped.count == 25)
        #expect(capped.contains(where: { $0.value == "m27" && $0.isDefault }))
    }
}

@Suite("WizardRegistry")
struct WizardRegistryTests {
    @Test func putGetRemove() async throws {
        let reg = WizardRegistry()
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await reg.put(w, channelId: "c1")
        #expect(await reg.get(channelId: "c1") != nil)
        await reg.remove(channelId: "c1")
        #expect(await reg.get(channelId: "c1") == nil)
    }
}
