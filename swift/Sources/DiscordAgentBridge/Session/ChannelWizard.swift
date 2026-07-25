import Foundation

// MARK: - W11-b2: `/agent start` select wizard
//
// Pure state machine — no Discord types. Steps (slice2):
//   folder → backend → model → [effort if any] → perm → done | cancelled
//
// Folder: dir:into / dir:up navigate immediately; dir:here commits cwd → backend.
// Choice steps: select onChange writes PENDING only; Next/Start commits and advances
// (Discord does not re-fire a select for the already-selected option).
// Option lists are injected at open from live `providerCatalog(for:)` — never hardcoded
// model/effort/perm vocabularies (Backend.allCases is the only fixed list).
//
// ponytail: preset step · reconfigure entry · dir:manual modal · A4D channel create → later slices.

// MARK: Types

public enum WizardStep: String, Sendable, Equatable {
    case folder
    case backend
    case model
    case effort
    case perm
    case done
    case cancelled
}

public struct WizardInput: Sendable, Equatable {
    public var id: String
    public var value: String?
    public init(id: String, value: String? = nil) {
        self.id = id
        self.value = value
    }
}

public struct WizardDefaults: Sendable, Equatable {
    public var backend: Backend
    public var model: String
    public var effort: String
    public var permMode: String
    public init(backend: Backend, model: String, effort: String, permMode: String) {
        self.backend = backend
        self.model = model
        self.effort = effort
        self.permMode = permMode
    }
}

/// Snapshot of per-backend option lists taken when the wizard opens.
public struct WizardOptionSource: Sendable, Equatable {
    public var backends: [Backend]
    public var modelsFor: [Backend: [ModelChoice]]
    public var permsFor: [Backend: [ModelChoice]]
    /// effortsFor[backend][modelValue] — empty array → skip effort step for that model.
    public var effortsFor: [Backend: [String: [ModelChoice]]]
    public var defaultEffortFor: [Backend: String]
    public var defaults: WizardDefaults

    public init(
        backends: [Backend] = Backend.allCases,
        modelsFor: [Backend: [ModelChoice]],
        permsFor: [Backend: [ModelChoice]],
        effortsFor: [Backend: [String: [ModelChoice]]],
        defaultEffortFor: [Backend: String],
        defaults: WizardDefaults
    ) {
        self.backends = backends
        self.modelsFor = modelsFor
        self.permsFor = permsFor
        self.effortsFor = effortsFor
        self.defaultEffortFor = defaultEffortFor
        self.defaults = defaults
    }

    public func models(for backend: Backend) -> [ModelChoice] {
        modelsFor[backend] ?? []
    }

    public func perms(for backend: Backend) -> [ModelChoice] {
        permsFor[backend] ?? []
    }

    public func efforts(for backend: Backend, model: String) -> [ModelChoice] {
        if let e = effortsFor[backend]?[model] { return e }
        return effortsFor[backend]?[""] ?? []
    }

    public func defaultEffort(for backend: Backend) -> String {
        defaultEffortFor[backend] ?? ""
    }
}

/// Params collected by the wizard for registry bind + store upsert.
public struct WizardStartParams: Sendable, Equatable {
    public var guildId: String
    public var channelId: String
    public var backend: Backend
    public var cwd: String
    public var ownerId: String
    public var model: String
    public var effort: String
    public var permMode: String

    public init(
        guildId: String,
        channelId: String,
        backend: Backend,
        cwd: String,
        ownerId: String,
        model: String,
        effort: String,
        permMode: String
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.backend = backend
        self.cwd = cwd
        self.ownerId = ownerId
        self.model = model
        self.effort = effort
        self.permMode = permMode
    }
}

// MARK: Render specs (Discord-agnostic; dab maps to DiscordBM)

public struct WizardSelectOption: Sendable, Equatable {
    public var label: String
    public var value: String
    public var isDefault: Bool
    public init(label: String, value: String, isDefault: Bool = false) {
        self.label = label
        self.value = value
        self.isDefault = isDefault
    }
}

public enum WizardButtonStyle: String, Sendable, Equatable {
    case primary
    case secondary
    case success
    case danger
}

public enum WizardComponent: Sendable, Equatable {
    case select(customId: String, placeholder: String, options: [WizardSelectOption])
    case button(customId: String, label: String, style: WizardButtonStyle, disabled: Bool)
}

public struct WizardRow: Sendable, Equatable {
    public var components: [WizardComponent]
    public init(components: [WizardComponent]) { self.components = components }
}

public struct WizardView: Sendable, Equatable {
    public var title: String
    public var description: String
    public var rows: [WizardRow]
    public init(title: String, description: String, rows: [WizardRow]) {
        self.title = title
        self.description = description
        self.rows = rows
    }
}

// MARK: Component id recognition (for DabMain routing)

/// Custom ids owned by the agent-start wizard (folder + select steps). Distinct from `perm:<req>:<action>`.
public func isWizardCustomId(_ customId: String) -> Bool {
    if isDirectoryBrowserCustomId(customId) { return true }
    switch customId {
    case "backend", "backend.next",
         "model", "model.next",
         "effort", "effort.next",
         "perm.mode", "perm.start",
         "wizard.back", "cancel":
        return true
    default:
        return false
    }
}

// MARK: Load options from live catalogs

/// Probe every backend's live catalog once (wizard open). Backends = `Backend.allCases` only fixed.
public func loadWizardOptionSource(
    catalogFor: (Backend) -> any ProviderCatalog = { providerCatalog(for: $0) }
) async -> WizardOptionSource {
    var modelsFor: [Backend: [ModelChoice]] = [:]
    var permsFor: [Backend: [ModelChoice]] = [:]
    var effortsFor: [Backend: [String: [ModelChoice]]] = [:]
    var defaultEffortFor: [Backend: String] = [:]

    for backend in Backend.allCases {
        let cat = catalogFor(backend)
        // Warm async catalog (Claude caches the snapshot for subsequent effortChoices).
        let models = await cat.models(configured: nil)
        modelsFor[backend] = models
        permsFor[backend] = await cat.permissionChoices()
        let defE = await cat.defaultEffort() ?? ""
        defaultEffortFor[backend] = defE

        var byModel: [String: [ModelChoice]] = [:]
        byModel[""] = cat.effortChoices(modelLevels: nil)
        for m in models {
            byModel[m.value] = cat.effortChoices(modelLevels: m.supportedEffortLevels)
        }
        effortsFor[backend] = byModel
    }

    let defaultBackend = Backend.claude
    let models = modelsFor[defaultBackend] ?? []
    let perms = permsFor[defaultBackend] ?? []
    let defaults = WizardDefaults(
        backend: defaultBackend,
        model: models.first?.value ?? "",
        effort: defaultEffortFor[defaultBackend] ?? "",
        permMode: perms.first?.value ?? "default"
    )
    return WizardOptionSource(
        backends: Backend.allCases,
        modelsFor: modelsFor,
        permsFor: permsFor,
        effortsFor: effortsFor,
        defaultEffortFor: defaultEffortFor,
        defaults: defaults
    )
}

/// Working directory for slice1: `DAB_CWD` if set/non-empty, else home.
public func wizardDefaultCwd(
    env: [String: String] = ProcessInfo.processInfo.environment,
    home: String = NSHomeDirectory()
) -> String {
    if let v = env["DAB_CWD"], !v.isEmpty { return v }
    return home
}

// MARK: State machine

public struct WizardSelection: Sendable, Equatable {
    public var cwd: String
    public var backend: Backend
    public var model: String
    public var effort: String
    public var permMode: String
}

/// Pure `/agent start` wizard (slice2: folder → backend → model → effort → perm).
public final class ChannelWizard: @unchecked Sendable {
    public let guildId: String
    public let channelId: String
    public let ownerId: String
    private let options: WizardOptionSource
    private let browser: DirectoryBrowser
    private let firstStep: WizardStep = .folder
    private var step: WizardStep = .folder
    private var selection: WizardSelection
    private var pending: Pending = Pending()
    /// Set when step becomes `.done` (perm.start committed).
    public private(set) var startParams: WizardStartParams?

    private struct Pending {
        var backend: Backend?
        var model: String?
        var effort: String?
        var permMode: String?
    }

    public init(
        guildId: String,
        channelId: String,
        ownerId: String,
        browser: DirectoryBrowser,
        options: WizardOptionSource
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.ownerId = ownerId
        self.browser = browser
        self.options = options
        let d = options.defaults
        self.selection = WizardSelection(
            cwd: browser.cwd(),
            backend: d.backend,
            model: d.model,
            effort: d.effort,
            permMode: d.permMode
        )
    }

    /// Convenience: start browser at `cwd` (unbounded unless roots provided).
    public convenience init(
        guildId: String,
        channelId: String,
        ownerId: String,
        cwd: String,
        options: WizardOptionSource,
        allowedRoots: [String] = []
    ) {
        self.init(
            guildId: guildId,
            channelId: channelId,
            ownerId: ownerId,
            browser: DirectoryBrowser(allowedRoots: allowedRoots, startPath: cwd),
            options: options
        )
    }

    public func currentStep() -> WizardStep { step }

    public func current() -> WizardSelection { selection }

    /// Folder currently in the browser (read-only; for future create/resume flows).
    public func browserCwd() -> String { browser.cwd() }

    /// Jump browser to absolute path (manual-path / tests). false → no view change.
    @discardableResult
    public func browserGoTo(_ absPath: String) -> Bool { browser.goTo(absPath) }

    /// Advance by one select/button input. Unknown ids for the current step are ignored.
    @discardableResult
    public func handle(_ input: WizardInput) -> WizardStep {
        if input.id == "cancel" {
            step = .cancelled
            return step
        }
        if input.id == "wizard.back" {
            stepBack()
            return step
        }
        switch step {
        case .folder: handleFolder(input)
        case .backend: handleBackend(input)
        case .model: handleModel(input)
        case .effort: handleEffort(input)
        case .perm: handlePerm(input)
        case .done, .cancelled: break
        }
        return step
    }

    private func stepBack() {
        if step == firstStep { return }
        pending = Pending()
        switch step {
        case .backend:
            step = .folder
        case .model:
            step = .backend
        case .effort:
            step = .model
        case .perm:
            step = hasEffortStep() ? .effort : .model
        default:
            break
        }
    }

    /// Folder nav: into/up re-render only; dir:here commits cwd → backend.
    private func handleFolder(_ input: WizardInput) {
        if input.id == "dir:into", let v = input.value, v != "__none__", !v.isEmpty {
            _ = browser.into(v)
        } else if input.id == "dir:up" {
            _ = browser.up()
        } else if input.id == "dir:here" {
            selection.cwd = browser.select()
            step = .backend
        }
    }

    private func handleBackend(_ input: WizardInput) {
        if input.id == "backend", let raw = input.value, let b = Backend(rawValue: raw) {
            pending.backend = b
        } else if input.id == "backend.next" {
            let chosen = pending.backend ?? selection.backend
            if chosen != selection.backend { applyBackend(chosen) }
            pending.backend = nil
            step = .model
        }
    }

    private func handleModel(_ input: WizardInput) {
        if input.id == "model", let v = input.value {
            pending.model = v
        } else if input.id == "model.next" {
            selection.model = pending.model ?? selection.model
            pending.model = nil
            step = hasEffortStep() ? .effort : .perm
        }
    }

    private func handleEffort(_ input: WizardInput) {
        if input.id == "effort", let v = input.value {
            pending.effort = v
        } else if input.id == "effort.next" {
            selection.effort = pending.effort ?? selection.effort
            pending.effort = nil
            step = .perm
        }
    }

    private func handlePerm(_ input: WizardInput) {
        if input.id == "perm.mode", let v = input.value {
            pending.permMode = v
        } else if input.id == "perm.start" {
            if let p = pending.permMode {
                selection.permMode = p
                pending.permMode = nil
            }
            startParams = WizardStartParams(
                guildId: guildId,
                channelId: channelId,
                backend: selection.backend,
                cwd: selection.cwd,
                ownerId: ownerId,
                model: selection.model,
                effort: selection.effort,
                permMode: selection.permMode
            )
            step = .done
        }
    }

    private func applyBackend(_ backend: Backend) {
        selection.backend = backend
        let models = options.models(for: backend)
        selection.model = models.first?.value ?? selection.model
        selection.effort = options.defaultEffort(for: backend)
        let perms = options.perms(for: backend)
        selection.permMode = perms.first?.value ?? selection.permMode
        pending = Pending()
    }

    private func hasEffortStep() -> Bool {
        !options.efforts(for: selection.backend, model: selection.model).isEmpty
    }

    // MARK: Render

    public func render() -> WizardView {
        let title = "에이전트 세션 시작"
        switch step {
        case .folder:
            return browser.render()
        case .backend:
            return choiceStep(
                title: title,
                description: "백엔드를 선택하세요",
                selectId: "backend",
                options: options.backends.map { b in
                    WizardSelectOption(
                        label: b.rawValue,
                        value: b.rawValue,
                        isDefault: b == (pending.backend ?? selection.backend)
                    )
                },
                confirmId: "backend.next",
                confirmLabel: "다음",
                showBack: true
            )
        case .model:
            let selected = pending.model ?? selection.model
            return choiceStep(
                title: title,
                description: "모델을 선택하세요 (\(selection.backend.rawValue))",
                selectId: "model",
                options: options.models(for: selection.backend).map { m in
                    WizardSelectOption(label: m.label, value: m.value, isDefault: m.value == selected)
                },
                confirmId: "model.next",
                confirmLabel: "다음",
                showBack: true
            )
        case .effort:
            let selected = pending.effort ?? selection.effort
            return choiceStep(
                title: title,
                description: "추론 강도를 선택하세요",
                selectId: "effort",
                options: options.efforts(for: selection.backend, model: selection.model).map { e in
                    WizardSelectOption(label: e.label, value: e.value, isDefault: e.value == selected)
                },
                confirmId: "effort.next",
                confirmLabel: "다음",
                showBack: true
            )
        case .perm:
            let selected = pending.permMode ?? selection.permMode
            let modeOpts = capSelectOptions(
                options.perms(for: selection.backend).map { p in
                    WizardSelectOption(label: p.label, value: p.value, isDefault: p.value == selected)
                }
            )
            var rows: [WizardRow] = []
            if !modeOpts.isEmpty {
                rows.append(WizardRow(components: [
                    .select(customId: "perm.mode", placeholder: "권한 모드", options: modeOpts),
                ]))
            }
            let buttons: [WizardComponent] = [
                .button(customId: "perm.start", label: "시작", style: .success, disabled: false),
                .button(customId: "wizard.back", label: "이전", style: .secondary, disabled: false),
                .button(customId: "cancel", label: "취소", style: .secondary, disabled: false),
            ]
            rows.append(WizardRow(components: buttons))
            return WizardView(title: title, description: "권한 모드를 선택하고 시작하세요", rows: rows)
        case .done:
            return WizardView(
                title: title,
                description: "시작됨: \(selection.backend.rawValue) · \(selection.cwd)",
                rows: []
            )
        case .cancelled:
            return WizardView(title: title, description: "취소되었습니다.", rows: [])
        }
    }

    private func choiceStep(
        title: String,
        description: String,
        selectId: String,
        options: [WizardSelectOption],
        confirmId: String,
        confirmLabel: String,
        showBack: Bool
    ) -> WizardView {
        let capped = capSelectOptions(options)
        var rows: [WizardRow] = []
        if !capped.isEmpty {
            rows.append(WizardRow(components: [
                .select(customId: selectId, placeholder: description, options: capped),
            ]))
        }
        var buttons: [WizardComponent] = [
            .button(customId: confirmId, label: confirmLabel, style: .primary, disabled: false),
        ]
        if showBack {
            buttons.append(.button(customId: "wizard.back", label: "이전", style: .secondary, disabled: false))
        }
        buttons.append(.button(customId: "cancel", label: "취소", style: .secondary, disabled: false))
        rows.append(WizardRow(components: buttons))
        return WizardView(title: title, description: description, rows: rows)
    }
}

// MARK: Select option cap (Discord ≤25)

func capSelectOptions(_ options: [WizardSelectOption]) -> [WizardSelectOption] {
    func clamp(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n))
    }
    let trimmed = options.map {
        WizardSelectOption(label: clamp($0.label, 100), value: clamp($0.value, 100), isDefault: $0.isDefault)
    }
    if trimmed.count <= 25 { return trimmed }
    let selected = trimmed.first(where: \.isDefault)
    var capped = Array(trimmed.prefix(25))
    if let selected, !capped.contains(where: { $0.value == selected.value }) {
        capped = [selected] + Array(capped.prefix(24))
    }
    return capped
}

// MARK: In-memory wizard store (DabMain)

/// channelId → active agent-start wizard. One process-wide (EventHandler is recreated per event).
public actor WizardRegistry {
    public static let shared = WizardRegistry()
    private var wizards: [String: ChannelWizard] = [:]

    public init() {}

    public func put(_ wizard: ChannelWizard, channelId: String) {
        wizards[channelId] = wizard
    }

    public func get(channelId: String) -> ChannelWizard? {
        wizards[channelId]
    }

    public func remove(channelId: String) {
        wizards[channelId] = nil
    }
}
