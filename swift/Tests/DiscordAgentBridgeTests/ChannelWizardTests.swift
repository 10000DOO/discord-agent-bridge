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

/// Confirm folder (root) and land on backend — no presets (R6).
@discardableResult
private func pastFolder(_ w: ChannelWizard) async -> WizardStep {
    await w.handle(WizardInput(id: "dir:here"))
}

private let SAMPLE_PRESETS: [Preset] = [
    Preset(
        name: "codex-fast",
        backend: "codex",
        model: "gpt-5.4",
        effort: "minimal",
        permMode: "workspace-write"
    ),
    Preset(name: "claude-min", backend: "claude"),
]

private func makeWizardWithPresets(
    presets: [Preset] = SAMPLE_PRESETS,
    onDelete: ((String) async -> [Preset])? = nil,
    backendAvailable: ((String) -> Bool)? = nil
) throws -> (ChannelWizard, URL) {
    let folderRoot = try makeFolderRoot()
    let browser = DirectoryBrowser(allowedRoots: [folderRoot.path], startPath: folderRoot.path)
    let w = ChannelWizard(
        guildId: "g1",
        channelId: "c1",
        ownerId: "u1",
        browser: browser,
        options: fakeOptions(),
        presets: presets,
        onDeletePreset: onDelete,
        backendAvailable: backendAvailable
    )
    return (w, folderRoot)
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

    @Test func startsOnFolderThenAdvancesToDone() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.currentStep() == .folder)

        #expect(await w.handle(WizardInput(id: "dir:into", value: "project")) == .folder)
        #expect(w.browserCwd() == root.appendingPathComponent("project").path)
        #expect(await w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().cwd == root.appendingPathComponent("project").path)

        // Select change does NOT advance; Next commits.
        #expect(await w.handle(WizardInput(id: "backend", value: "codex")) == .backend)
        #expect(w.current().backend == .claude)
        #expect(await w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(w.current().backend == .codex)
        #expect(w.current().model == "gpt-5.5")
        #expect(w.current().effort == "medium")
        #expect(w.current().permMode == "read-only")

        #expect(await w.handle(WizardInput(id: "model", value: "gpt-5.4")) == .model)
        #expect(await w.handle(WizardInput(id: "model.next")) == .effort)
        #expect(w.current().model == "gpt-5.4")

        #expect(await w.handle(WizardInput(id: "effort", value: "high")) == .effort)
        #expect(await w.handle(WizardInput(id: "effort.next")) == .perm)
        #expect(w.current().effort == "high")

        #expect(await w.handle(WizardInput(id: "perm.mode", value: "workspace-write")) == .perm)
        #expect(await w.handle(WizardInput(id: "perm.start")) == .done)
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

    @Test func dirUpOnFolderStep() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:into", value: "project"))
        #expect(await w.handle(WizardInput(id: "dir:up")) == .folder)
        #expect(w.browserCwd() == root.path)
    }

    @Test func keepingDefaultsAndPressingButtonsAdvancesToStart() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        #expect(await w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(await w.handle(WizardInput(id: "model.next")) == .effort)
        #expect(await w.handle(WizardInput(id: "effort.next")) == .perm)
        #expect(await w.handle(WizardInput(id: "perm.start")) == .done)
        #expect(w.startParams?.backend == .claude)
        #expect(w.startParams?.model == "opus")
        #expect(w.startParams?.effort == "high")
        #expect(w.startParams?.permMode == "default")
        #expect(w.startParams?.cwd == root.path)
    }

    @Test func skipsEffortWhenBackendOffersNone() async throws {
        var opts = fakeOptions(backends: [.grok])
        opts.defaults = WizardDefaults(backend: .grok, model: "grok-4", effort: "", permMode: "default")
        let (w, root) = try makeWizard(options: opts)
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        #expect(await w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(await w.handle(WizardInput(id: "model.next")) == .perm)
        #expect(await w.handle(WizardInput(id: "perm.start")) == .done)
        #expect(w.startParams?.effort == "")
    }

    @Test func selectChangeUpdatesPendingWithoutAdvancing() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        await w.handle(WizardInput(id: "backend", value: "codex"))
        #expect(w.currentStep() == .backend)
        #expect(w.current().backend == .claude)
        let codex = selectOptions(w, customId: "backend").first { $0.value == "codex" }
        #expect(codex?.isDefault == true)
    }

    @Test func afterCodexBackendModelAndPermShowCodexCatalog() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        await w.handle(WizardInput(id: "backend", value: "codex"))
        await w.handle(WizardInput(id: "backend.next"))
        #expect(selectOptions(w, customId: "model").map(\.value) == ["gpt-5.5", "gpt-5.4"])
        await w.handle(WizardInput(id: "model.next"))
        let effortValues = selectOptions(w, customId: "effort").map(\.value)
        #expect(effortValues.contains("minimal"))
        #expect(!effortValues.contains("max"))
        await w.handle(WizardInput(id: "effort.next"))
        #expect(selectOptions(w, customId: "perm.mode").map(\.value) == [
            "read-only", "workspace-write", "danger-full-access",
        ])
    }

    @Test func afterClaudeBackendShowsClaudeCatalog() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        await w.handle(WizardInput(id: "backend.next"))
        #expect(selectOptions(w, customId: "model").map(\.value) == ["opus", "sonnet"])
        await w.handle(WizardInput(id: "model.next"))
        let effortValues = selectOptions(w, customId: "effort").map(\.value)
        #expect(effortValues.contains("max"))
        #expect(!effortValues.contains("minimal"))
        await w.handle(WizardInput(id: "effort.next"))
        let perms = selectOptions(w, customId: "perm.mode").map(\.value)
        #expect(perms.contains("acceptEdits"))
        #expect(!perms.contains("workspace-write"))
    }

    @Test func backFromBackendReturnsToFolder() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        await w.handle(WizardInput(id: "backend", value: "codex"))
        await w.handle(WizardInput(id: "backend.next"))
        #expect(w.current().backend == .codex)
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .backend)
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .folder)
        #expect(w.browserCwd() == root.path)
        // re-confirm folder → backend; committed codex kept from before
        #expect(await w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().backend == .codex)
    }

    @Test func backKeepsCommittedSelections() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        await w.handle(WizardInput(id: "backend", value: "codex"))
        await w.handle(WizardInput(id: "backend.next"))
        #expect(w.current().backend == .codex)
        await w.handle(WizardInput(id: "model", value: "gpt-5.4"))
        // pending model discarded on back; committed backend kept
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .backend)
        #expect(w.current().backend == .codex)
        #expect(w.current().model == "gpt-5.5") // applyBackend default, not pending gpt-5.4
        #expect(await w.handle(WizardInput(id: "backend.next")) == .model)
        #expect(w.current().backend == .codex)
    }

    @Test func backOnFirstStepIsNoop() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .folder)
    }

    @Test func cancelEndsWizard() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await w.handle(WizardInput(id: "cancel")) == .cancelled)
        #expect(w.startParams == nil)
        #expect(w.render().rows.isEmpty)
    }

    @Test func permBackSkipsEffortWhenEmpty() async throws {
        var opts = fakeOptions(backends: [.grok])
        opts.defaults = WizardDefaults(backend: .grok, model: "grok-4", effort: "", permMode: "default")
        let (w, root) = try makeWizard(options: opts)
        defer { try? FileManager.default.removeItem(at: root) }
        await pastFolder(w)
        await w.handle(WizardInput(id: "backend.next"))
        await w.handle(WizardInput(id: "model.next"))
        #expect(w.currentStep() == .perm)
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .model)
    }

    @Test func folderRenderIncludesDirIds() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = componentIds(w)
        #expect(ids.contains("dir:into"))
        #expect(ids.contains("dir:here"))
        #expect(ids.contains("dir:create"))
        #expect(ids.contains("dir:manual"))
        #expect(ids.contains("cancel"))
        await pastFolder(w)
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
        #expect(isWizardCustomId("dir:create"))
        #expect(isWizardCustomId("dir:manual"))
        #expect(isWizardCustomId("dir:panel"))
        #expect(!isWizardCustomId("perm:abc:allow"))
    }

    // MARK: - Reconfigure (backend-switch popup)

    private func makeReconfigureWizard(
        entry: WizardEntry,
        options: WizardOptionSource = fakeOptions()
    ) throws -> (ChannelWizard, URL) {
        let root = try makeFolderRoot()
        let browser = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        let w = ChannelWizard(
            guildId: "g1",
            channelId: "c1",
            ownerId: "u1",
            browser: browser,
            options: options,
            entry: entry
        )
        return (w, root)
    }

    @Test func reconfigureOpensAtModelSkipsFolderBackend() throws {
        let entry = WizardEntry(
            backend: .codex, cwd: "/tmp/proj", permMode: "workspace-write"
        )
        let (w, root) = try makeReconfigureWizard(entry: entry)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.currentStep() == .model)
        #expect(w.isReconfigure())
        let ids = componentIds(w)
        #expect(ids.contains("model"))
        #expect(ids.contains("model.next"))
        #expect(ids.contains("wizard.back"))
        #expect(!ids.contains("backend"))
        #expect(!ids.contains("dir:into"))
        #expect(w.render().title.contains("codex"))
        #expect(w.render().description.contains("1/3"))
    }

    @Test func reconfigureBackOnFirstStepCancels() async throws {
        let entry = WizardEntry(backend: .codex, cwd: "/tmp/proj", permMode: "workspace-write")
        let (w, root) = try makeReconfigureWizard(entry: entry)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .cancelled)
        #expect(w.startParams == nil)
        #expect(w.render().description.contains("취소"))
    }

    @Test func reconfigureWalksModelEffortPermThenDone() async throws {
        let entry = WizardEntry(backend: .codex, cwd: "/tmp/proj", permMode: "workspace-write")
        let (w, root) = try makeReconfigureWizard(entry: entry)
        defer { try? FileManager.default.removeItem(at: root) }
        // Seeds: new-backend model/effort defaults; perm carried from entry.
        #expect(w.current().model == "gpt-5.5")
        #expect(w.current().effort == "medium")
        #expect(w.current().permMode == "workspace-write")
        #expect(w.current().cwd == "/tmp/proj")
        #expect(w.current().backend == .codex)

        #expect(await w.handle(WizardInput(id: "model.next")) == .effort)
        #expect(componentIds(w).contains("wizard.back"))
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .model)
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .cancelled)
    }

    @Test func reconfigureConfirmSetsStartParams() async throws {
        let entry = WizardEntry(backend: .codex, cwd: "/tmp/proj", permMode: "workspace-write")
        let (w, root) = try makeReconfigureWizard(entry: entry)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await w.handle(WizardInput(id: "model", value: "gpt-5.4")) == .model)
        #expect(await w.handle(WizardInput(id: "model.next")) == .effort)
        #expect(await w.handle(WizardInput(id: "effort", value: "high")) == .effort)
        #expect(await w.handle(WizardInput(id: "effort.next")) == .perm)
        // Start button label is reconfigure "전환"
        let permView = w.render()
        let startLabels = permView.rows.flatMap(\.components).compactMap { c -> String? in
            if case .button(let id, let label, _, _) = c, id == "perm.start" { return label }
            return nil
        }
        #expect(startLabels.contains("✅ 전환"))
        #expect(await w.handle(WizardInput(id: "perm.start")) == .done)
        let p = w.startParams
        #expect(p?.backend == .codex)
        #expect(p?.model == "gpt-5.4")
        #expect(p?.effort == "high")
        #expect(p?.permMode == "workspace-write")
        #expect(p?.cwd == "/tmp/proj")
        #expect(p?.channelId == "c1")
    }

    @Test func reconfigureHonorsEntryModelEffortOverride() throws {
        let entry = WizardEntry(
            backend: .codex, cwd: "/tmp/proj", permMode: "read-only",
            model: "gpt-5.4", effort: "high"
        )
        let (w, root) = try makeReconfigureWizard(entry: entry)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.current().model == "gpt-5.4")
        #expect(w.current().effort == "high")
        #expect(w.current().permMode == "read-only")
    }

    @Test func startWizardIsNotReconfigure() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!w.isReconfigure())
        #expect(w.currentStep() == .folder)
    }

    @Test func browserGoToUpdatesFolderView() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project").path
        #expect(w.browserGoTo(project))
        #expect(w.browserCwd() == project)
        #expect(await w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().cwd == project)
    }

    @Test func browserCreateMkdirAndEnter() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        switch w.browserCreate("spawned", enter: true) {
        case .ok(let path):
            #expect(w.browserCwd() == path)
            #expect(path == root.appendingPathComponent("spawned").path)
        default:
            Issue.record("expected create ok")
        }
        // Create/manual do not advance the SM.
        #expect(w.currentStep() == .folder)
        #expect(await w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(w.current().cwd == root.appendingPathComponent("spawned").path)
    }

    @Test func browserCreateRejectsUnsafeNames() throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(w.browserCreate("..") == .invalidName)
        #expect(w.browserCreate("a/b") == .invalidName)
        #expect(w.browserCwd() == root.path)
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
            case .claude, .custom:
                // custom reuses Claude catalog vocabulary.
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
        #expect(src.backends.contains(.custom))
        #expect(src.models(for: .custom).map(\.value) == ["opus"])
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

// MARK: - Preset step (W11-b2)

@Suite("ChannelWizard presets")
struct ChannelWizardPresetTests {

    @Test func dirHereGoesToPresetWhenPresetsNonEmpty() async throws {
        let (w, root) = try makeWizardWithPresets()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await w.handle(WizardInput(id: "dir:here")) == .preset)
        let ids = componentIds(w)
        #expect(ids.contains("preset.pick"))
        #expect(ids.contains("preset.direct"))
        #expect(ids.contains("preset.delete"))
        #expect(selectOptions(w, customId: "preset.pick").map(\.value) == ["codex-fast", "claude-min"])
    }

    @Test func dirHereGoesToBackendWhenNoPresets() async throws {
        let (w, root) = try makeWizard()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await w.handle(WizardInput(id: "dir:here")) == .backend)
        #expect(!componentIds(w).contains("preset.pick"))
    }

    @Test func pickingPresetSeedsAndStartsImmediately() async throws {
        let (w, root) = try makeWizardWithPresets()
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:into", value: "project"))
        await w.handle(WizardInput(id: "dir:here"))
        #expect(await w.handle(WizardInput(id: "preset.pick", value: "codex-fast")) == .done)
        #expect(w.launchedFromPreset() == true)
        #expect(w.startParams?.backend == .codex)
        #expect(w.startParams?.model == "gpt-5.4")
        #expect(w.startParams?.effort == "minimal")
        #expect(w.startParams?.permMode == "workspace-write")
        #expect(w.startParams?.cwd == root.appendingPathComponent("project").path)
    }

    @Test func minimalPresetSeedsCatalogDefaults() async throws {
        let (w, root) = try makeWizardWithPresets()
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        #expect(await w.handle(WizardInput(id: "preset.pick", value: "claude-min")) == .done)
        #expect(w.startParams?.backend == .claude)
        #expect(w.startParams?.model == "opus")
        #expect(w.startParams?.effort == "high")
        #expect(w.startParams?.permMode == "default")
    }

    @Test func presetDirectAdvancesToBackendWithoutStart() async throws {
        let (w, root) = try makeWizardWithPresets()
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        #expect(await w.handle(WizardInput(id: "preset.direct")) == .backend)
        #expect(w.launchedFromPreset() == false)
        #expect(w.startParams == nil)
    }

    @Test func deleteModeRemovesPresetAndStaysOnStep() async throws {
        var deleted: [String] = []
        let (w, root) = try makeWizardWithPresets(onDelete: { name in
            deleted.append(name)
            return SAMPLE_PRESETS.filter { $0.name != name }
        })
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        #expect(await w.handle(WizardInput(id: "preset.delete")) == .preset)
        #expect(await w.handle(WizardInput(id: "preset.pick", value: "codex-fast")) == .preset)
        #expect(deleted == ["codex-fast"])
        #expect(selectOptions(w, customId: "preset.pick").map(\.value) == ["claude-min"])
        #expect(w.startParams == nil)
    }

    @Test func unavailableBackendBlocksStartAndShowsNotice() async throws {
        let (w, root) = try makeWizardWithPresets(backendAvailable: { $0 != "codex" })
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        #expect(await w.handle(WizardInput(id: "preset.pick", value: "codex-fast")) == .preset)
        #expect(w.launchedFromPreset() == false)
        #expect(w.startParams == nil)
        #expect(w.render().description.contains("codex"))
        #expect(await w.handle(WizardInput(id: "preset.pick", value: "claude-min")) == .done)
        #expect(w.startParams != nil)
    }

    @Test func reenterPresetViaFolderClearsStaleUnavailableNotice() async throws {
        let (w, root) = try makeWizardWithPresets(backendAvailable: { $0 != "codex" })
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        await w.handle(WizardInput(id: "preset.pick", value: "codex-fast"))
        #expect(w.render().description.contains("codex"))
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .folder)
        #expect(await w.handle(WizardInput(id: "dir:here")) == .preset)
        #expect(!w.render().description.contains("codex"))
    }

    @Test func deletingLastPresetLeavesButtonsWithoutDropdown() async throws {
        let single = [Preset(name: "only", backend: "claude")]
        let (w, root) = try makeWizardWithPresets(presets: single)
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        await w.handle(WizardInput(id: "preset.delete"))
        #expect(await w.handle(WizardInput(id: "preset.pick", value: "only")) == .preset)
        let ids = componentIds(w)
        #expect(!ids.contains("preset.pick"))
        #expect(ids.contains("preset.direct"))
        #expect(ids.contains("preset.delete"))
    }

    @Test func wizardBackWalksBackendPresetFolder() async throws {
        let (w, root) = try makeWizardWithPresets()
        defer { try? FileManager.default.removeItem(at: root) }
        await w.handle(WizardInput(id: "dir:here"))
        await w.handle(WizardInput(id: "preset.direct"))
        #expect(w.currentStep() == .backend)
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .preset)
        #expect(await w.handle(WizardInput(id: "wizard.back")) == .folder)
    }

    @Test func isWizardCustomIdRecognizesPresetIds() {
        #expect(isWizardCustomId("preset.pick"))
        #expect(isWizardCustomId("preset.direct"))
        #expect(isWizardCustomId("preset.delete"))
        #expect(!isWizardCustomId("preset.save")) // save is post-done modal opener
    }

    @Test func summarizePresetClampsTo100() {
        let long = Preset(
            name: "n",
            backend: String(repeating: "b", count: 40),
            model: String(repeating: "m", count: 40),
            effort: String(repeating: "e", count: 40),
            permMode: String(repeating: "p", count: 40)
        )
        let s = summarizePreset(long)
        #expect(s.count <= 100)
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

@Suite("PresetDraftRegistry")
struct PresetDraftRegistryTests {
    @Test func setGetRemove() async {
        let reg = PresetDraftRegistry()
        let key = PresetDraftRegistry.key(guildId: "g1", channelId: "c1")
        await reg.set(PresetDraft(backend: "claude", model: "opus"), key: key)
        #expect(await reg.get(key: key)?.backend == "claude")
        await reg.remove(key: key)
        #expect(await reg.get(key: key) == nil)
    }
}
